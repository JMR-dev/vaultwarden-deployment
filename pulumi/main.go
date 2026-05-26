// Phase 1: Hetzner Cloud server + Cloud Firewall + attached volume + GCP Cloud DNS A/AAAA.
//
// Two-stage bootstrap is intentional:
//
//   1. First `pulumi up` with `bootstrapSshCidr` set to the operator's public IP
//      provisions the server with public SSH (22) open to that one IP so Ansible
//      can reach it. WG is not yet up.
//   2. After Ansible brings up wg-quick@wg0, set `bootstrapSshCidr` to "" and
//      re-run `pulumi up`. The public 22 rule is removed; SSH is then reachable
//      only through the WG subnet (which is host-internal, so effectively
//      WG-only from the operator's laptop).
//
// Cloud Firewall + host nftables (configured by Ansible) are deliberately
// redundant layers.

package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/artifactregistry"
	"github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/dns"
	"github.com/pulumi/pulumi-hcloud/sdk/go/hcloud"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

// sshPubkeyPattern accepts the standard OpenSSH single-line public-key
// formats: ssh-ed25519 / ssh-rsa / ssh-dss / ecdsa-sha2-* / sk-* (FIDO),
// followed by a base64 blob and an optional comment. Rejects multiline
// input — a stray newline would break cloud-init YAML rendering.
var sshPubkeyPattern = regexp.MustCompile(
	`^(ssh-(?:ed25519|rsa|dss)|ecdsa-sha2-\S+|sk-(?:ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+( [^\r\n]*)?$`,
)

func main() {
	pulumi.Run(func(ctx *pulumi.Context) error {
		cfg := config.New(ctx, "vaultwarden")

		location := cfg.Require("location")
		serverType := cfg.Get("serverType")
		if serverType == "" {
			serverType = "cx22"
		}
		image := cfg.Get("image")
		if image == "" {
			image = "alma-10"
		}
		hostname := cfg.Require("hostname")
		volumeSize := cfg.GetInt("volumeSize")
		if volumeSize == 0 {
			volumeSize = 20
		}
		sshPubkey := cfg.Require("sshPubkey")
		if !sshPubkeyPattern.MatchString(sshPubkey) {
			return fmt.Errorf("sshPubkey doesn't look like a single-line OpenSSH public key (got %q)", sshPubkey)
		}
		wgPort := cfg.Get("wgPort")
		if wgPort == "" {
			wgPort = "51820"
		}
		bootstrapSshCidr := cfg.Get("bootstrapSshCidr")
		if err := validateBootstrapSshCidr(bootstrapSshCidr); err != nil {
			return err
		}

		gcpProject := cfg.Require("gcpProject")
		dnsManagedZone := cfg.Require("dnsManagedZone")
		dnsRecordName := cfg.Require("dnsRecordName")
		dnsTtl := cfg.GetInt("dnsTtl")
		if dnsTtl == 0 {
			dnsTtl = 300
		}
		arRegion := cfg.Require("gcpArRegion")
		arImageName := cfg.Get("arImageName")
		if arImageName == "" {
			arImageName = "vaultwarden-caddy"
		}
		// DeleteProtection on the data volume defaults to off (so disposable
		// stacks can `pulumi destroy` cleanly) but should be enabled in
		// production via `pulumi config set vaultwarden:deleteProtection true`.
		// With it on, `pulumi destroy` will fail at the volume rather than
		// silently dropping the live vault DB.
		deleteProtection := cfg.GetBool("deleteProtection")

		// SSH key uploaded to Hetzner for first-boot user.
		sshKey, err := hcloud.NewSshKey(ctx, hostname+"-bootstrap", &hcloud.SshKeyArgs{
			Name:      pulumi.String(hostname + "-bootstrap"),
			PublicKey: pulumi.String(sshPubkey),
			Labels: pulumi.StringMap{
				"managed-by": pulumi.String("pulumi"),
				"stack":      pulumi.String(ctx.Stack()),
			},
		})
		if err != nil {
			return fmt.Errorf("upload ssh key: %w", err)
		}

		// Firewall rules. Public 443 + WG always; ICMP for diagnostics; public 22
		// only during bootstrap.
		fwRules := hcloud.FirewallRuleArray{
			&hcloud.FirewallRuleArgs{
				Description: pulumi.String("HTTPS"),
				Direction:   pulumi.String("in"),
				Protocol:    pulumi.String("tcp"),
				Port:        pulumi.String("443"),
				SourceIps:   pulumi.StringArray{pulumi.String("0.0.0.0/0"), pulumi.String("::/0")},
			},
			&hcloud.FirewallRuleArgs{
				Description: pulumi.String("WireGuard"),
				Direction:   pulumi.String("in"),
				Protocol:    pulumi.String("udp"),
				Port:        pulumi.String(wgPort),
				SourceIps:   pulumi.StringArray{pulumi.String("0.0.0.0/0"), pulumi.String("::/0")},
			},
			&hcloud.FirewallRuleArgs{
				Description: pulumi.String("ICMP"),
				Direction:   pulumi.String("in"),
				Protocol:    pulumi.String("icmp"),
				SourceIps:   pulumi.StringArray{pulumi.String("0.0.0.0/0"), pulumi.String("::/0")},
			},
		}
		if bootstrapSshCidr != "" {
			fwRules = append(fwRules, &hcloud.FirewallRuleArgs{
				Description: pulumi.String("Bootstrap SSH (remove after WG is up)"),
				Direction:   pulumi.String("in"),
				Protocol:    pulumi.String("tcp"),
				Port:        pulumi.String("22"),
				SourceIps:   pulumi.StringArray{pulumi.String(bootstrapSshCidr)},
			})
		}

		fw, err := hcloud.NewFirewall(ctx, hostname+"-fw", &hcloud.FirewallArgs{
			Name:  pulumi.String(hostname + "-fw"),
			Rules: fwRules,
			Labels: pulumi.StringMap{
				"managed-by": pulumi.String("pulumi"),
				"stack":      pulumi.String(ctx.Stack()),
			},
		})
		if err != nil {
			return fmt.Errorf("create firewall: %w", err)
		}

		// Server. Cloud-init handles the bare minimum needed for Ansible to take
		// over: install python3, drop the SSH key in for the bootstrap user.
		// Everything else (rootless podman user, WG, nftables, ...) is Ansible.
		userData := pulumi.Sprintf(`#cloud-config
package_update: true
package_upgrade: false
packages:
  - python3
  - python3-libdnf5
users:
  - name: ansible
    groups: wheel
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - %s
ssh_pwauth: false
disable_root: true
`, sshPubkey)

		server, err := hcloud.NewServer(ctx, hostname, &hcloud.ServerArgs{
			Name:       pulumi.String(hostname),
			ServerType: pulumi.String(serverType),
			Image:      pulumi.String(image),
			Location:   pulumi.String(location),
			SshKeys:    pulumi.StringArray{sshKey.Name},
			UserData:   userData,
			FirewallIds: pulumi.IntArray{
				fw.ID().ApplyT(func(id pulumi.ID) (int, error) {
					return parsePulumiID(id)
				}).(pulumi.IntOutput),
			},
			Labels: pulumi.StringMap{
				"managed-by": pulumi.String("pulumi"),
				"stack":      pulumi.String(ctx.Stack()),
				"role":       pulumi.String("vaultwarden"),
			},
		})
		if err != nil {
			return fmt.Errorf("create server: %w", err)
		}

		// Data volume — decoupled from instance lifecycle so the box can be
		// rebuilt without losing /data.
		_, err = hcloud.NewVolume(ctx, hostname+"-data", &hcloud.VolumeArgs{
			Name:             pulumi.String(hostname + "-data"),
			Size:             pulumi.Int(volumeSize),
			ServerId:         server.ID().ApplyT(parsePulumiID).(pulumi.IntOutput),
			Format:           pulumi.String("ext4"),
			Automount:        pulumi.Bool(true),
			DeleteProtection: pulumi.Bool(deleteProtection),
			Labels: pulumi.StringMap{
				"managed-by": pulumi.String("pulumi"),
				"stack":      pulumi.String(ctx.Stack()),
			},
		}, pulumi.Protect(deleteProtection))
		if err != nil {
			return fmt.Errorf("create volume: %w", err)
		}

		// DNS records. AAAA pulls from the server's IPv6 (Hetzner gives a /64;
		// Vaultwarden binds the first address).
		_, err = dns.NewRecordSet(ctx, hostname+"-a", &dns.RecordSetArgs{
			Project:     pulumi.String(gcpProject),
			ManagedZone: pulumi.String(dnsManagedZone),
			Name:        pulumi.String(dnsRecordName),
			Type:        pulumi.String("A"),
			Ttl:         pulumi.Int(dnsTtl),
			Rrdatas: pulumi.StringArray{
				server.Ipv4Address,
			},
		})
		if err != nil {
			return fmt.Errorf("create A record: %w", err)
		}

		_, err = dns.NewRecordSet(ctx, hostname+"-aaaa", &dns.RecordSetArgs{
			Project:     pulumi.String(gcpProject),
			ManagedZone: pulumi.String(dnsManagedZone),
			Name:        pulumi.String(dnsRecordName),
			Type:        pulumi.String("AAAA"),
			Ttl:         pulumi.Int(dnsTtl),
			Rrdatas: pulumi.StringArray{
				server.Ipv6Address,
			},
		})
		if err != nil {
			return fmt.Errorf("create AAAA record: %w", err)
		}

		// Artifact Registry — per-stack Docker repo for the custom Caddy image.
		// `allUsers` gets reader so the rootless Hetzner host pulls without
		// auth; the Caddy image contains no secrets (the image is built from
		// public sources, see caddy/versions.env). Cloud Build pushes via the
		// build SA's ADC, no token needed.
		arRepoId := "vault-images-" + ctx.Stack()
		arRepo, err := artifactregistry.NewRepository(ctx, arRepoId, &artifactregistry.RepositoryArgs{
			Location:     pulumi.String(arRegion),
			Project:      pulumi.String(gcpProject),
			RepositoryId: pulumi.String(arRepoId),
			Format:       pulumi.String("DOCKER"),
			Description:  pulumi.Sprintf("Custom Caddy images for the %s vaultwarden stack", ctx.Stack()),
			Labels: pulumi.StringMap{
				"managed-by": pulumi.String("pulumi"),
				"stack":      pulumi.String(ctx.Stack()),
			},
		})
		if err != nil {
			return fmt.Errorf("create artifact registry repo: %w", err)
		}

		_, err = artifactregistry.NewRepositoryIamMember(ctx, arRepoId+"-public-reader", &artifactregistry.RepositoryIamMemberArgs{
			Project:    pulumi.String(gcpProject),
			Location:   arRepo.Location,
			Repository: arRepo.RepositoryId,
			Role:       pulumi.String("roles/artifactregistry.reader"),
			Member:     pulumi.String("allUsers"),
		})
		if err != nil {
			return fmt.Errorf("grant allUsers reader on AR repo: %w", err)
		}

		imageRepo := pulumi.Sprintf("%s-docker.pkg.dev/%s/%s/%s", arRegion, gcpProject, arRepoId, arImageName)

		// Exports — consumed by Cloud Build and Ansible.
		ctx.Export("serverID", server.ID())
		ctx.Export("ipv4", server.Ipv4Address)
		ctx.Export("ipv6", server.Ipv6Address)
		ctx.Export("hostname", pulumi.String(hostname))
		ctx.Export("fqdn", pulumi.String(dnsRecordName))
		ctx.Export("firewallID", fw.ID())
		ctx.Export("imageRepo", imageRepo)
		ctx.Export("arRepoId", pulumi.String(arRepoId))
		ctx.Export("arRegion", pulumi.String(arRegion))

		return nil
	})
}

// parsePulumiID converts a Pulumi resource ID (string) to the int IDs that
// hcloud resources use. Hetzner IDs are numeric; the SDK still types them as
// pulumi.IDOutput (string) at the API boundary.
func parsePulumiID(id pulumi.ID) (int, error) {
	var n int
	if _, err := fmt.Sscanf(string(id), "%d", &n); err != nil {
		return 0, fmt.Errorf("parse hcloud id %q: %w", string(id), err)
	}
	return n, nil
}

// validateBootstrapSshCidr rejects values that would obviously open public
// SSH wider than intended. Empty is fine (rule is omitted). Otherwise must
// be a single IPv4 /N where N >= 8 — a typo'd /0 or /4 isn't a real CIDR
// for a single operator endpoint.
func validateBootstrapSshCidr(v string) error {
	if v == "" {
		return nil
	}
	parts := strings.SplitN(v, "/", 2)
	if len(parts) != 2 {
		return fmt.Errorf("bootstrapSshCidr %q: must be IPv4/N", v)
	}
	octets := strings.Split(parts[0], ".")
	if len(octets) != 4 {
		return fmt.Errorf("bootstrapSshCidr %q: not IPv4", v)
	}
	for _, o := range octets {
		n, err := strconv.Atoi(o)
		if err != nil || n < 0 || n > 255 {
			return fmt.Errorf("bootstrapSshCidr %q: bad octet %q", v, o)
		}
	}
	mask, err := strconv.Atoi(parts[1])
	if err != nil || mask < 8 || mask > 32 {
		return fmt.Errorf("bootstrapSshCidr %q: mask /%s rejected (require /8..32)", v, parts[1])
	}
	return nil
}
