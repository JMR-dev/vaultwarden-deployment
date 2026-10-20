// The vaultwarden platform stack: everything long-lived or privileged that the
// CI-run app stack (../pulumi) must NOT be able to change.
//
// Why a separate project: CI authenticates with a long-lived SA key (Gitea
// 1.27 can't mint Actions OIDC tokens), so that key's blast radius is whatever
// the deployer SA can do. Every IAM grant, every service account, DNS, the
// network, the registry, the R2 buckets and the Resend mail domain therefore
// live here, applied by the
// owner with their own ADC. The deployer can create and replace the VM and
// its disk, read the secrets Ansible renders, and push images -- nothing that
// lets it widen its own access.
//
// Pre-existing and deliberately NOT managed (so `pulumi destroy` can't take
// them): the Cloud DNS zone, both state buckets, the KMS key and every Secret
// Manager secret (scripts/bootstrap-gcp.sh), and the Caddy DNS SA plus its key
// (gcloud-made; only its grants are declared below).
//
// Run with both provider credentials from their owner-only secrets:
//
//	CLOUDFLARE_API_TOKEN=$(gcloud secrets versions access latest --secret=vaultwarden-cloudflare-api-token) \
//	RESEND_API_KEY=$(gcloud secrets versions access latest --secret=vaultwarden-resend-api-key) \
//	pulumi up
package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"regexp"
	"strings"
	"time"

	"gitea.jasonmross.dev/JMR-dev/pulumi-resend/sdk/go/resend"
	"github.com/pulumi/pulumi-cloudflare/sdk/v6/go/cloudflare"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/artifactregistry"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/compute"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/dns"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/kms"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/projects"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/secretmanager"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/serviceaccount"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/storage"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
	"google.golang.org/api/parametermanager/v1"
)

const (
	// NetworkTag is applied to every vault instance (../pulumi) and targeted by
	// every firewall rule here.
	NetworkTag = "vaultwarden"

	// IAPRange is the fixed source range of Google's IAP TCP forwarding. It is
	// the only path to port 22 and, through a tunnel to :443, the only source
	// Caddy lets reach /admin. The same range is in the host nftables ruleset
	// and in fail2ban's ignoreip -- IAP is the only way back into the box.
	IAPRange = "35.235.240.0/20"

	// SubnetCIDR must not overlap the rootless podman bridge (10.89.0.0/16).
	SubnetCIDR = "10.30.0.0/24"

	NetworkName = "vaultwarden"
	SubnetName  = "vaultwarden-us-east1"
	ARRepoID    = "vaultwarden"
	DeployerID  = "vaultwarden-deployer"
)

// DeployerProjectRoles are the only project-level roles the CI deployer gets.
// compute.instanceAdmin.v1 covers instances, disks, snapshot policies, using
// the platform's addresses and subnet, and reading guest attributes (the SSH
// host keys scripts/ansible-iap.sh pins). The other two are SSH over IAP.
// None of them can grant IAM; main_test.go enforces that.
var DeployerProjectRoles = []string{
	"roles/compute.instanceAdmin.v1",
	"roles/compute.osAdminLogin",
	"roles/iap.tunnelResourceAccessor",
}

// SharedSecrets are read by Ansible for every stack.
var SharedSecrets = []string{"vaultwarden-vaultwarden", "vaultwarden-msmtp"}

// StackSecrets are per stack, so a disposable host can neither ping
// production's Healthchecks nor touch production's backups.
func StackSecrets(stack string) []string {
	return []string{
		"vaultwarden-" + stack + "-restic",
		"vaultwarden-" + stack + "-healthchecks",
	}
}

func R2BucketName(stack string) string        { return "vaultwarden-backups-" + stack }
func AddressName(stack, family string) string { return "vault-" + stack + "-" + family }

// ActiveParameterName is the Parameter Manager parameter (location global)
// that switches a stack on and off at runtime. scripts/bootstrap-gcp.sh
// creates it, scripts/stack-active.sh writes it, and a stack configured with
// activeParameter reads it.
func ActiveParameterName(stack string) string { return "vaultwarden-" + stack + "-active" }

type StackConfig struct {
	Name string `json:"name"`
	FQDN string `json:"fqdn"`
	// Exactly one of Active and ActiveParameter is set.
	// - Active is fixed here, in code. Production uses it: turning production
	//   off releases its static IPs and DNS, so that stays a reviewed change.
	// - ActiveParameter names the parameter (ActiveParameterName) whose newest
	//   enabled version holds the JSON boolean, so the stack goes on and off
	//   without a code change. Disposable uses it (runbook §2.9).
	Active          *bool  `json:"active,omitempty"`
	ActiveParameter string `json:"activeParameter,omitempty"`
	// IsActive is the resolved state: Active, or the parameter's value.
	IsActive bool `json:"-"`
}

type Config struct {
	Project                string
	Region                 string
	DNSZone                string
	AppStateBucket         string
	KMSKey                 string
	CloudflareAccountID    pulumi.StringOutput
	R2Location             string
	CaddyDNSServiceAccount string
	ZoneListerRole         string
	MailDomain             string
	Stacks                 []StackConfig
}

var stackNamePattern = regexp.MustCompile(`^[a-z][a-z0-9]{1,15}$`)

func loadConfig(ctx *pulumi.Context) (*Config, error) {
	gcpCfg := config.New(ctx, "gcp")
	c := config.New(ctx, "vaultwarden-platform")
	cfg := &Config{
		Project:                gcpCfg.Require("project"),
		Region:                 gcpCfg.Require("region"),
		DNSZone:                c.Require("dnsZone"),
		AppStateBucket:         c.Require("appStateBucket"),
		KMSKey:                 c.Require("kmsKey"),
		CloudflareAccountID:    c.RequireSecret("cloudflareAccountId"),
		R2Location:             c.Get("r2Location"),
		CaddyDNSServiceAccount: c.Require("caddyDnsServiceAccount"),
		ZoneListerRole:         c.Require("zoneListerRole"),
		MailDomain:             c.Require("mailDomain"),
	}
	if cfg.R2Location == "" {
		cfg.R2Location = "enam"
	}
	c.RequireObject("stacks", &cfg.Stacks)
	return cfg, cfg.validate()
}

// validate fails the preview, not the apply.
func (c *Config) validate() error {
	if strings.HasPrefix(c.AppStateBucket, "gs://") {
		return fmt.Errorf("appStateBucket is a bucket name, not a URL: drop the gs:// prefix")
	}
	if !strings.HasPrefix(c.KMSKey, "projects/") {
		return fmt.Errorf("kmsKey must be a full resource id (projects/.../cryptoKeys/...)")
	}
	if strings.HasSuffix(c.MailDomain, ".") {
		return fmt.Errorf("mailDomain %q is a Resend domain name: drop the trailing dot", c.MailDomain)
	}
	if len(c.Stacks) == 0 {
		return fmt.Errorf("stacks is empty")
	}
	seen := map[string]bool{}
	for _, s := range c.Stacks {
		if !stackNamePattern.MatchString(s.Name) {
			return fmt.Errorf("stack name %q: want [a-z][a-z0-9]{1,15}", s.Name)
		}
		if seen[s.Name] {
			return fmt.Errorf("stack %q listed twice", s.Name)
		}
		seen[s.Name] = true
		if !strings.HasSuffix(s.FQDN, ".") {
			return fmt.Errorf("stack %q: fqdn %q needs a trailing dot", s.Name, s.FQDN)
		}
		switch {
		case s.Active != nil && s.ActiveParameter != "":
			return fmt.Errorf("stack %q: set active or activeParameter, not both", s.Name)
		case s.Active == nil && s.ActiveParameter == "":
			return fmt.Errorf("stack %q: set active (true/false) or activeParameter", s.Name)
		case s.ActiveParameter != "" && s.ActiveParameter != ActiveParameterName(s.Name):
			return fmt.Errorf("stack %q: activeParameter must be %q, the name scripts/stack-active.sh writes",
				s.Name, ActiveParameterName(s.Name))
		}
	}
	return nil
}

// stackActive reads a runtime-switched stack's state. It's a variable so the
// mock-runtime tests can replace it; the real one calls Parameter Manager.
var stackActive = parameterManagerActive

// resolveActive fills in every stack's IsActive. An unreadable parameter is an
// error, never "inactive": a typo or an API hiccup must fail the preview, not
// release a stack's static IPs and DNS on the next up.
func resolveActive(ctx context.Context, cfg *Config) error {
	for i := range cfg.Stacks {
		s := &cfg.Stacks[i]
		if s.Active != nil {
			s.IsActive = *s.Active
			continue
		}
		active, err := stackActive(ctx, cfg.Project, s.ActiveParameter)
		if err != nil {
			return fmt.Errorf("stack %q: %w", s.Name, err)
		}
		s.IsActive = active
	}
	return nil
}

// parameterManagerActive returns the boolean held by the newest enabled
// version of a global Parameter Manager parameter. The service has no
// "latest" alias, so this lists the versions and takes the newest by
// createTime that isn't disabled. Disabling a version rolls back to the one
// before it.
func parameterManagerActive(ctx context.Context, project, parameter string) (bool, error) {
	svc, err := parametermanager.NewService(ctx)
	if err != nil {
		return false, fmt.Errorf("parameter %s: %w", parameter, err)
	}
	parent := fmt.Sprintf("projects/%s/locations/global/parameters/%s", project, parameter)
	var newest *parametermanager.ParameterVersion
	var newestAt time.Time
	err = svc.Projects.Locations.Parameters.Versions.List(parent).Pages(ctx, func(page *parametermanager.ListParameterVersionsResponse) error {
		for _, v := range page.ParameterVersions {
			if v.Disabled {
				continue
			}
			at, err := time.Parse(time.RFC3339Nano, v.CreateTime)
			if err != nil {
				return fmt.Errorf("version %s: createTime %q: %w", v.Name, v.CreateTime, err)
			}
			if newest == nil || at.After(newestAt) {
				newest, newestAt = v, at
			}
		}
		return nil
	})
	if err != nil {
		return false, fmt.Errorf("parameter %s: list versions: %w", parameter, err)
	}
	if newest == nil {
		return false, fmt.Errorf("parameter %s has no enabled version; set one with scripts/stack-active.sh", parameter)
	}
	v, err := svc.Projects.Locations.Parameters.Versions.Get(newest.Name).View("FULL").Do()
	if err != nil {
		return false, fmt.Errorf("parameter %s: get %s: %w", parameter, newest.Name, err)
	}
	if v.Payload == nil {
		return false, fmt.Errorf("parameter %s: version %s has no payload", parameter, newest.Name)
	}
	raw, err := base64.StdEncoding.DecodeString(v.Payload.Data)
	if err != nil {
		return false, fmt.Errorf("parameter %s: version %s: payload isn't base64: %w", parameter, newest.Name, err)
	}
	active, err := ParseActive(string(raw))
	if err != nil {
		return false, fmt.Errorf("parameter %s, version %s: %w", parameter, newest.Name, err)
	}
	return active, nil
}

// ParseActive accepts exactly the JSON booleans `true` and `false`, allowing
// only trailing whitespace (a file payload ends in a newline). Parameter
// Manager's JSON format would also accept "true" (a string) or 1, which mean
// nothing here; this is where "only ever a bool" is enforced on read, and
// scripts/stack-active.sh enforces it on write.
func ParseActive(payload string) (bool, error) {
	switch strings.TrimRight(payload, " \t\r\n") {
	case "true":
		return true, nil
	case "false":
		return false, nil
	}
	shown := payload
	if len(shown) > 40 {
		shown = shown[:40] + "…"
	}
	return false, fmt.Errorf("payload %q is not the JSON boolean true or false", shown)
}

func main() { pulumi.Run(program) }

func program(ctx *pulumi.Context) error {
	cfg, err := loadConfig(ctx)
	if err != nil {
		return err
	}
	if err := resolveActive(ctx.Context(), cfg); err != nil {
		return err
	}

	zone, err := dns.LookupManagedZone(ctx, &dns.LookupManagedZoneArgs{
		Name:    cfg.DNSZone,
		Project: &cfg.Project,
	})
	if err != nil {
		return fmt.Errorf("look up DNS zone %q: %w", cfg.DNSZone, err)
	}
	inZone := func(fqdn string) bool { return fqdn == zone.DnsName || strings.HasSuffix(fqdn, "."+zone.DnsName) }
	for _, s := range cfg.Stacks {
		if !inZone(s.FQDN) {
			return fmt.Errorf("stack %q: fqdn %q is not inside zone %s", s.Name, s.FQDN, zone.DnsName)
		}
	}
	if !inZone(cfg.MailDomain + ".") {
		return fmt.Errorf("mailDomain %q is not inside zone %s, which must hold its records", cfg.MailDomain, zone.DnsName)
	}

	subnet, err := newNetwork(ctx, cfg)
	if err != nil {
		return err
	}

	deployer, err := serviceaccount.NewAccount(ctx, "deployer", &serviceaccount.AccountArgs{
		Project:     pulumi.String(cfg.Project),
		AccountId:   pulumi.String(DeployerID),
		DisplayName: pulumi.String("vaultwarden CI deployer"),
		Description: pulumi.String("Gitea Actions deploys (JSON key in the repo secret GCP_DEPLOYER_KEY). Grants live in platform/; it must never hold IAM-admin roles."),
	})
	if err != nil {
		return err
	}
	deployerMember := pulumi.Sprintf("serviceAccount:%s", deployer.Email)

	repo, err := newRegistry(ctx, cfg, deployerMember)
	if err != nil {
		return err
	}

	if err := grantDeployer(ctx, cfg, deployerMember); err != nil {
		return err
	}
	if err := grantCaddyDNS(ctx, cfg, zone.Name); err != nil {
		return err
	}

	mail, err := newMailDomain(ctx, cfg, zone.Name)
	if err != nil {
		return err
	}

	stackOutputs := pulumi.Map{}
	for _, s := range cfg.Stacks {
		out, err := newStack(ctx, cfg, s, zone.Name, subnet, deployerMember)
		if err != nil {
			return err
		}
		stackOutputs[s.Name] = out
	}

	ctx.Export("subnetwork", subnet.SelfLink)
	ctx.Export("networkTag", pulumi.String(NetworkTag))
	ctx.Export("caddyImage", pulumi.Sprintf("%s-docker.pkg.dev/%s/%s/caddy", repo.Location, cfg.Project, repo.RepositoryId))
	ctx.Export("deployerEmail", deployer.Email)
	ctx.Export("mailDomain", mail.Name)
	ctx.Export("mailDomainId", mail.ID())
	ctx.Export("stacks", stackOutputs)
	return nil
}

// newMailDomain is the Resend sending domain for the hosts' alert mail
// (msmtp): the domain, the three records Resend checks, and a verification
// that waits until Resend sees them. The provider reads RESEND_API_KEY at
// configure time and never stores it in state. The hosts get a separate
// sending-only key scoped to this domain (mailDomainId), in vaultwarden-msmtp.
func newMailDomain(ctx *pulumi.Context, cfg *Config, zoneName string) (*resend.Domain, error) {
	domain, err := resend.NewDomain(ctx, "mail", &resend.DomainArgs{
		Name: pulumi.String(cfg.MailDomain),
	}, pulumi.Protect(true)) // a replacement issues a new DKIM key
	if err != nil {
		return nil, err
	}

	dkim := domain.DkimRecord.Elem()
	mx := domain.SpfMxRecord.Elem()
	spf := domain.SpfTxtRecord.Elem()
	// Resend added a fourth record in 2026: a return-path CNAME (`rsend.<domain>`)
	// that pulumi-resend v0.1.0 has no convenience output for, so take it from
	// the full record list. Verification stays partial without it.
	cname := domain.Records.ApplyT(func(rs []resend.DnsRecord) resend.DnsRecord {
		for _, r := range rs {
			if r.Type == "CNAME" && r.Record == "SPF" {
				return r
			}
		}
		return resend.DnsRecord{}
	}).(resend.DnsRecordOutput)
	// Cloud DNS wants absolute names, quoted TXT values and dotted MX/CNAME targets.
	var records []pulumi.Resource
	for _, r := range []struct {
		name, typ string
		fqdn      pulumi.StringOutput
		rrdata    pulumi.StringOutput
	}{
		{"mail-dkim", "TXT", dkim.Fqdn(), pulumi.Sprintf(`"%s"`, dkim.Value())},
		{"mail-return-path-mx", "MX", mx.Fqdn(), pulumi.Sprintf("%d %s.", mx.Priority().Elem(), mx.Value())},
		{"mail-return-path-spf", "TXT", spf.Fqdn(), pulumi.Sprintf(`"%s"`, spf.Value())},
		{"mail-return-path-cname", "CNAME", cname.Fqdn(), pulumi.Sprintf("%s.", cname.Value())},
	} {
		rs, err := dns.NewRecordSet(ctx, r.name, &dns.RecordSetArgs{
			Project:     pulumi.String(cfg.Project),
			ManagedZone: pulumi.String(zoneName),
			Name:        pulumi.Sprintf("%s.", r.fqdn),
			Type:        pulumi.String(r.typ),
			Ttl:         pulumi.Int(300),
			Rrdatas:     pulumi.StringArray{r.rrdata},
		})
		if err != nil {
			return nil, err
		}
		records = append(records, rs)
	}

	_, err = resend.NewDomainVerification(ctx, "mail", &resend.DomainVerificationArgs{
		DomainId: domain.ID().ToStringOutput(),
		// Re-verify whenever a record value changes.
		Triggers: pulumi.StringMap{
			"dkim":     dkim.Value(),
			"spfMx":    mx.Value(),
			"spfTxt":   spf.Value(),
			"spfCname": cname.Value(),
		},
	}, pulumi.DependsOn(records))
	return domain, err
}

// newNetwork builds a dual-stack VPC with the only three ways in: HTTPS from
// anywhere, ICMP for diagnostics and PMTUD (IPv6 breaks without packet-too-big),
// and SSH from IAP alone.
func newNetwork(ctx *pulumi.Context, cfg *Config) (*compute.Subnetwork, error) {
	net, err := compute.NewNetwork(ctx, "vpc", &compute.NetworkArgs{
		Project:               pulumi.String(cfg.Project),
		Name:                  pulumi.String(NetworkName),
		AutoCreateSubnetworks: pulumi.Bool(false),
		Description:           pulumi.String("vaultwarden deployment network"),
	})
	if err != nil {
		return nil, err
	}

	subnet, err := compute.NewSubnetwork(ctx, "subnet", &compute.SubnetworkArgs{
		Project:               pulumi.String(cfg.Project),
		Name:                  pulumi.String(SubnetName),
		Network:               net.ID(),
		Region:                pulumi.String(cfg.Region),
		IpCidrRange:           pulumi.String(SubnetCIDR),
		StackType:             pulumi.String("IPV4_IPV6"),
		Ipv6AccessType:        pulumi.String("EXTERNAL"),
		PrivateIpGoogleAccess: pulumi.Bool(true),
	})
	if err != nil {
		return nil, err
	}

	// GCP firewall rules can't mix IPv4 and IPv6 source ranges, hence pairs.
	rules := []struct {
		name, protocol, desc string
		ports, sources       []string
	}{
		{"vaultwarden-allow-https", "tcp", "Public HTTPS (v4)", []string{"443"}, []string{"0.0.0.0/0"}},
		{"vaultwarden-allow-https-v6", "tcp", "Public HTTPS (v6)", []string{"443"}, []string{"::/0"}},
		{"vaultwarden-allow-icmp", "icmp", "ICMP diagnostics (v4)", nil, []string{"0.0.0.0/0"}},
		// Protocol 58 = ICMPv6. Packet-too-big has to get through or IPv6
		// path-MTU discovery silently black-holes large responses.
		{"vaultwarden-allow-icmp-v6", "58", "ICMPv6 incl. PMTUD", nil, []string{"::/0"}},
		{"vaultwarden-allow-iap-ssh", "tcp", "Admin SSH via IAP TCP forwarding only", []string{"22"}, []string{IAPRange}},
	}
	for _, r := range rules {
		allow := &compute.FirewallAllowArgs{Protocol: pulumi.String(r.protocol)}
		if len(r.ports) > 0 {
			allow.Ports = pulumi.ToStringArray(r.ports)
		}
		if _, err := compute.NewFirewall(ctx, r.name, &compute.FirewallArgs{
			Project:      pulumi.String(cfg.Project),
			Name:         pulumi.String(r.name),
			Network:      net.ID(),
			Allows:       compute.FirewallAllowArray{allow},
			SourceRanges: pulumi.ToStringArray(r.sources),
			TargetTags:   pulumi.ToStringArray([]string{NetworkTag}),
			Description:  pulumi.String(r.desc),
		}); err != nil {
			return nil, err
		}
	}
	return subnet, nil
}

// newRegistry is the one Docker repo for the custom Caddy image. allUsers can
// read it so the rootless host pulls (and podman auto-update polls) without
// any credential on the box; the image is built from public sources and holds
// no secrets. Only the deployer writes.
func newRegistry(ctx *pulumi.Context, cfg *Config, deployerMember pulumi.StringInput) (*artifactregistry.Repository, error) {
	repo, err := artifactregistry.NewRepository(ctx, "registry", &artifactregistry.RepositoryArgs{
		Project:      pulumi.String(cfg.Project),
		Location:     pulumi.String(cfg.Region),
		RepositoryId: pulumi.String(ARRepoID),
		Format:       pulumi.String("DOCKER"),
		Description:  pulumi.String("Custom Caddy (googleclouddns + Coraza) images for vaultwarden"),
		CleanupPolicies: artifactregistry.RepositoryCleanupPolicyArray{
			&artifactregistry.RepositoryCleanupPolicyArgs{
				Id:     pulumi.String("delete-untagged"),
				Action: pulumi.String("DELETE"),
				Condition: &artifactregistry.RepositoryCleanupPolicyConditionArgs{
					TagState:  pulumi.String("UNTAGGED"),
					OlderThan: pulumi.String("1209600s"), // 14 days
				},
			},
			// <sha> tags are the rollback targets (runbook §8); keep plenty.
			&artifactregistry.RepositoryCleanupPolicyArgs{
				Id:     pulumi.String("keep-recent"),
				Action: pulumi.String("KEEP"),
				MostRecentVersions: &artifactregistry.RepositoryCleanupPolicyMostRecentVersionsArgs{
					KeepCount: pulumi.Int(20),
				},
			},
		},
	})
	if err != nil {
		return nil, err
	}

	if _, err := artifactregistry.NewRepositoryIamMember(ctx, "registry-public-reader", &artifactregistry.RepositoryIamMemberArgs{
		Project:    pulumi.String(cfg.Project),
		Location:   repo.Location,
		Repository: repo.RepositoryId,
		Role:       pulumi.String("roles/artifactregistry.reader"),
		Member:     pulumi.String("allUsers"),
	}); err != nil {
		return nil, err
	}
	if _, err := artifactregistry.NewRepositoryIamMember(ctx, "registry-deployer-writer", &artifactregistry.RepositoryIamMemberArgs{
		Project:    pulumi.String(cfg.Project),
		Location:   repo.Location,
		Repository: repo.RepositoryId,
		Role:       pulumi.String("roles/artifactregistry.writer"),
		Member:     deployerMember,
	}); err != nil {
		return nil, err
	}
	return repo, nil
}

// grantDeployer gives the CI deployer its project roles plus per-resource
// access to the app state bucket, the Pulumi KMS key and the shared secrets.
// Per-stack secrets are granted in newStack.
func grantDeployer(ctx *pulumi.Context, cfg *Config, member pulumi.StringInput) error {
	for _, role := range DeployerProjectRoles {
		name := "deployer-" + strings.TrimPrefix(role, "roles/")
		if _, err := projects.NewIAMMember(ctx, name, &projects.IAMMemberArgs{
			Project: pulumi.String(cfg.Project),
			Role:    pulumi.String(role),
			Member:  member,
		}); err != nil {
			return err
		}
	}

	if _, err := storage.NewBucketIAMMember(ctx, "deployer-app-state", &storage.BucketIAMMemberArgs{
		Bucket: pulumi.String(cfg.AppStateBucket),
		Role:   pulumi.String("roles/storage.objectAdmin"),
		Member: member,
	}); err != nil {
		return err
	}

	if _, err := kms.NewCryptoKeyIAMMember(ctx, "deployer-pulumi-kms", &kms.CryptoKeyIAMMemberArgs{
		CryptoKeyId: pulumi.String(cfg.KMSKey),
		Role:        pulumi.String("roles/cloudkms.cryptoKeyEncrypterDecrypter"),
		Member:      member,
	}); err != nil {
		return err
	}

	return grantSecrets(ctx, cfg, SharedSecrets, member)
}

func grantSecrets(ctx *pulumi.Context, cfg *Config, names []string, member pulumi.StringInput) error {
	for _, name := range names {
		if _, err := secretmanager.NewSecretIamMember(ctx, "deployer-"+name, &secretmanager.SecretIamMemberArgs{
			Project:  pulumi.String(cfg.Project),
			SecretId: pulumi.String(name),
			Role:     pulumi.String("roles/secretmanager.secretAccessor"),
			Member:   member,
		}); err != nil {
			return err
		}
	}
	return nil
}

// grantCaddyDNS records, in code, the grants the gcloud-made Caddy DNS SA
// already holds (memory: gcp-dns-layout). Both are additive *Member resources,
// so declaring them over the existing bindings is a no-op on first apply.
// Zone-scoped dns.admin writes the ACME TXT records; the custom lister role is
// project-level because googleclouddns finds its zone by listing them all,
// which no zone-scoped binding can allow.
func grantCaddyDNS(ctx *pulumi.Context, cfg *Config, zoneName string) error {
	member := pulumi.String("serviceAccount:" + cfg.CaddyDNSServiceAccount)
	if _, err := dns.NewDnsManagedZoneIamMember(ctx, "caddy-dns-zone-admin", &dns.DnsManagedZoneIamMemberArgs{
		Project:     pulumi.String(cfg.Project),
		ManagedZone: pulumi.String(zoneName),
		Role:        pulumi.String("roles/dns.admin"),
		Member:      member,
	}); err != nil {
		return err
	}
	_, err := projects.NewIAMMember(ctx, "caddy-dns-zone-lister", &projects.IAMMemberArgs{
		Project: pulumi.String(cfg.Project),
		Role:    pulumi.String(cfg.ZoneListerRole),
		Member:  member,
	})
	return err
}

// newStack builds one app stack's long-lived pieces. The R2 bucket exists for
// every listed stack, active or not, and is protected: it holds the backups.
// Addresses, DNS and secret grants exist only while the stack is active, so a
// retired stack stops billing for idle static IPs.
func newStack(ctx *pulumi.Context, cfg *Config, s StackConfig, zoneName string, subnet *compute.Subnetwork, deployerMember pulumi.StringInput) (pulumi.Map, error) {
	bucket, err := cloudflare.NewR2Bucket(ctx, "r2-"+s.Name, &cloudflare.R2BucketArgs{
		AccountId: cfg.CloudflareAccountID,
		Name:      pulumi.String(R2BucketName(s.Name)),
		Location:  pulumi.String(cfg.R2Location),
	}, pulumi.Protect(true))
	if err != nil {
		return nil, err
	}
	out := pulumi.Map{
		"active":   pulumi.Bool(s.IsActive),
		"fqdn":     pulumi.String(s.FQDN),
		"r2Bucket": bucket.Name,
	}
	if !s.IsActive {
		return out, nil
	}

	v4, err := compute.NewAddress(ctx, AddressName(s.Name, "ipv4"), &compute.AddressArgs{
		Project:     pulumi.String(cfg.Project),
		Name:        pulumi.String(AddressName(s.Name, "ipv4")),
		Region:      pulumi.String(cfg.Region),
		AddressType: pulumi.String("EXTERNAL"),
		Description: pulumi.Sprintf("vault-%s; DNS A for %s points here", s.Name, s.FQDN),
	})
	if err != nil {
		return nil, err
	}
	// A static external IPv6 is a /96 carved from the subnet's external range.
	v6, err := compute.NewAddress(ctx, AddressName(s.Name, "ipv6"), &compute.AddressArgs{
		Project:          pulumi.String(cfg.Project),
		Name:             pulumi.String(AddressName(s.Name, "ipv6")),
		Region:           pulumi.String(cfg.Region),
		AddressType:      pulumi.String("EXTERNAL"),
		IpVersion:        pulumi.String("IPV6"),
		Ipv6EndpointType: pulumi.String("VM"),
		Subnetwork:       subnet.ID(),
		Description:      pulumi.Sprintf("vault-%s; DNS AAAA for %s points here", s.Name, s.FQDN),
	})
	if err != nil {
		return nil, err
	}

	for _, rr := range []struct {
		typ  string
		addr pulumi.StringOutput
	}{{"A", v4.Address}, {"AAAA", v6.Address}} {
		if _, err := dns.NewRecordSet(ctx, fmt.Sprintf("%s-%s", s.Name, strings.ToLower(rr.typ)), &dns.RecordSetArgs{
			Project:     pulumi.String(cfg.Project),
			ManagedZone: pulumi.String(zoneName),
			Name:        pulumi.String(s.FQDN),
			Type:        pulumi.String(rr.typ),
			Ttl:         pulumi.Int(300),
			Rrdatas:     pulumi.StringArray{rr.addr},
		}); err != nil {
			return nil, err
		}
	}

	if err := grantSecrets(ctx, cfg, StackSecrets(s.Name), deployerMember); err != nil {
		return nil, err
	}

	out["ipv4"] = v4.Address
	out["ipv6"] = v6.Address
	return out, nil
}
