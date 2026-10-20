// Invariant tests under Pulumi's mock runtime: no cloud calls, no credentials.
// They pin down what this stack exists to guarantee -- mainly that the CI
// deployer can never be handed a role that lets it widen its own access.

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/pulumi/pulumi/sdk/v3/go/common/resource"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
)

type rec struct {
	typ, name string
	inputs    resource.PropertyMap
}

type mocks struct {
	mu   sync.Mutex
	recs []rec
}

func (m *mocks) NewResource(a pulumi.MockResourceArgs) (string, resource.PropertyMap, error) {
	m.mu.Lock()
	m.recs = append(m.recs, rec{a.TypeToken, a.Name, a.Inputs})
	m.mu.Unlock()
	out := a.Inputs.Copy()
	switch a.TypeToken {
	case "gcp:compute/address:Address":
		out["address"] = resource.NewStringProperty("203.0.113.9")
	case "gcp:serviceaccount/account:Account":
		out["email"] = resource.NewStringProperty(DeployerID + "@demo.iam.gserviceaccount.com")
	case "resend:index:Domain":
		name := a.Inputs["name"].StringValue()
		rr := func(fqdn, typ, value string, prio float64) resource.PropertyValue {
			m := resource.PropertyMap{
				"fqdn":   resource.NewStringProperty(fqdn),
				"type":   resource.NewStringProperty(typ),
				"value":  resource.NewStringProperty(value),
				"record": resource.NewStringProperty(map[bool]string{true: "DKIM", false: "SPF"}[strings.HasPrefix(fqdn, "resend.")]),
			}
			if prio > 0 {
				m["priority"] = resource.NewNumberProperty(prio)
			}
			return resource.NewObjectProperty(m)
		}
		out["dkimRecord"] = rr("resend._domainkey."+name, "TXT", "p=MIGfMA0GCSqGSIb3DQEB", 0)
		out["spfMxRecord"] = rr("send."+name, "MX", "feedback-smtp.us-east-1.amazonses.com", 10)
		out["spfTxtRecord"] = rr("send."+name, "TXT", "v=spf1 include:amazonses.com ~all", 0)
		out["records"] = resource.NewArrayProperty([]resource.PropertyValue{
			out["dkimRecord"], out["spfMxRecord"], out["spfTxtRecord"],
			rr("rsend."+name, "CNAME", "send.forge.rmta.net", 0),
		})
	}
	return a.Name + "_id", out, nil
}

func (m *mocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) {
	if a.Token == "gcp:dns/getManagedZone:getManagedZone" {
		return resource.PropertyMap{
			"name":    resource.NewStringProperty("vault"),
			"dnsName": resource.NewStringProperty("vault.example.org."),
		}, nil
	}
	return resource.PropertyMap{}, nil
}

func (m *mocks) byType(typ string) []rec {
	var out []rec
	for _, r := range m.recs {
		if r.typ == typ {
			out = append(out, r)
		}
	}
	return out
}

func str(r rec, key string) string {
	v, ok := r.inputs[resource.PropertyKey(key)]
	if !ok || !v.IsString() {
		return ""
	}
	return v.StringValue()
}

func strs(r rec, key string) []string {
	v, ok := r.inputs[resource.PropertyKey(key)]
	if !ok || !v.IsArray() {
		return nil
	}
	var out []string
	for _, e := range v.ArrayValue() {
		if e.IsString() {
			out = append(out, e.StringValue())
		}
	}
	return out
}

const stacksJSON = `[
  {"name":"disposable","fqdn":"disposable.vault.example.org.","active":true},
  {"name":"production","fqdn":"vault.example.org.","active":true}
]`

func baseConfig() map[string]string {
	return map[string]string{
		"gcp:project":                                 "demo",
		"gcp:region":                                  "us-east1",
		"vaultwarden-platform:dnsZone":                "vault",
		"vaultwarden-platform:appStateBucket":         "demo-pulumi-state",
		"vaultwarden-platform:kmsKey":                 "projects/demo/locations/global/keyRings/pulumi/cryptoKeys/stacks",
		"vaultwarden-platform:cloudflareAccountId":    "0123456789abcdef",
		"vaultwarden-platform:caddyDnsServiceAccount": "caddy@demo.iam.gserviceaccount.com",
		"vaultwarden-platform:zoneListerRole":         "projects/demo/roles/dnsZoneLister",
		"vaultwarden-platform:mailDomain":             "vault.example.org",
		"vaultwarden-platform:stacks":                 stacksJSON,
	}
}

func run(t *testing.T, cfg map[string]string) (*mocks, error) {
	t.Helper()
	b, _ := json.Marshal(cfg)
	t.Setenv("PULUMI_CONFIG", string(b))
	t.Setenv("PULUMI_CONFIG_SECRET_KEYS", `["vaultwarden-platform:cloudflareAccountId"]`)
	m := &mocks{}
	err := pulumi.RunErr(program, pulumi.WithMocks("vaultwarden-platform", "prod", m))
	return m, err
}

func mustRun(t *testing.T, cfg map[string]string) *mocks {
	t.Helper()
	m, err := run(t, cfg)
	if err != nil {
		t.Fatalf("program failed: %v", err)
	}
	return m
}

const deployerMember = "serviceAccount:" + DeployerID + "@demo.iam.gserviceaccount.com"

// The deployer's key sits in a Gitea secret. If it could grant IAM, mint
// tokens for other SAs, or administer secrets/KMS/DNS, a leaked key would be
// project takeover. Every role it holds, anywhere, must be on this list.
func TestDeployerHoldsOnlyAllowedRoles(t *testing.T) {
	m := mustRun(t, baseConfig())
	allowed := map[string]bool{
		"roles/compute.instanceAdmin.v1":             true,
		"roles/compute.osAdminLogin":                 true,
		"roles/iap.tunnelResourceAccessor":           true,
		"roles/storage.objectAdmin":                  true,
		"roles/cloudkms.cryptoKeyEncrypterDecrypter": true,
		"roles/secretmanager.secretAccessor":         true,
		"roles/artifactregistry.writer":              true,
	}
	found := 0
	for _, r := range m.recs {
		if str(r, "member") != deployerMember {
			continue
		}
		found++
		if role := str(r, "role"); !allowed[role] {
			t.Errorf("%s (%s) grants the deployer %q, which is not on the allow-list", r.name, r.typ, role)
		}
	}
	if found == 0 {
		t.Fatal("no grants to the deployer found; the member string format changed?")
	}
	for _, r := range m.byType("gcp:projects/iAMMember:IAMMember") {
		if str(r, "member") == deployerMember && str(r, "role") == "roles/storage.objectAdmin" {
			t.Error("storage.objectAdmin must be bucket-scoped, not project-wide")
		}
	}
}

// ownerOnlySecrets hold this stack's own provider credentials (Cloudflare R2
// admin, Resend full access). A deployer that could read them could delete the
// backup buckets or the mail domain.
var ownerOnlySecrets = []string{"vaultwarden-cloudflare-api-token", "vaultwarden-resend-api-key"}

// Every secret granted must exist as a container (bootstrap creates them from
// secret-names.txt, and a grant on a missing secret fails the apply), and the
// owner-only provider credentials must never be granted to the deployer.
func TestSecretGrantsMatchSecretNames(t *testing.T) {
	m := mustRun(t, baseConfig())
	listed := readSecretNames(t, "../secrets/secret-names.txt")
	for _, id := range ownerOnlySecrets {
		if !listed[id] {
			t.Errorf("owner-only secret %q is missing from secrets/secret-names.txt", id)
		}
	}
	for _, r := range m.byType("gcp:secretmanager/secretIamMember:SecretIamMember") {
		id := str(r, "secretId")
		if !listed[id] {
			t.Errorf("secret %q is granted but missing from secrets/secret-names.txt", id)
		}
		for _, owner := range ownerOnlySecrets {
			if id == owner {
				t.Errorf("secret %q is owner-only and must not be granted", id)
			}
		}
	}
}

func TestSSHOnlyFromIAP(t *testing.T) {
	m := mustRun(t, baseConfig())
	for _, r := range m.byType("gcp:compute/firewall:Firewall") {
		v := r.inputs["allows"]
		if !v.IsArray() {
			continue
		}
		for _, a := range v.ArrayValue() {
			for _, p := range strs(rec{inputs: a.ObjectValue()}, "ports") {
				if p == "22" {
					if src := strs(r, "sourceRanges"); len(src) != 1 || src[0] != IAPRange {
						t.Errorf("%s opens 22 to %v; only %s is allowed", r.name, src, IAPRange)
					}
				}
			}
		}
	}
}

func TestInactiveStackKeepsOnlyItsBucket(t *testing.T) {
	cfg := baseConfig()
	cfg["vaultwarden-platform:stacks"] = `[
	  {"name":"disposable","fqdn":"disposable.vault.example.org.","active":false},
	  {"name":"production","fqdn":"vault.example.org.","active":true}
	]`
	m := mustRun(t, cfg)

	if n := len(m.byType("cloudflare:index/r2Bucket:R2Bucket")); n != 2 {
		t.Errorf("want 2 R2 buckets (inactive stacks keep theirs), got %d", n)
	}
	for _, r := range m.byType("gcp:compute/address:Address") {
		if strings.Contains(r.name, "disposable") {
			t.Errorf("inactive stack still has address %s", r.name)
		}
	}
	for _, r := range m.byType("gcp:secretmanager/secretIamMember:SecretIamMember") {
		if strings.Contains(str(r, "secretId"), "disposable") {
			t.Errorf("inactive stack still grants %s", str(r, "secretId"))
		}
	}
	addrRecords := 0
	for _, r := range m.byType("gcp:dns/recordSet:RecordSet") {
		if typ := str(r, "type"); typ == "A" || typ == "AAAA" {
			addrRecords++
		}
	}
	if addrRecords != 2 {
		t.Errorf("want A+AAAA for production only, got %d address records", addrRecords)
	}
}

// Resend checks exactly these records; Cloud DNS rejects relative names and
// unquoted TXT data, and the verification must wait for the records.
func TestMailDomainRecords(t *testing.T) {
	m := mustRun(t, baseConfig())
	if n := len(m.byType("resend:index:Domain")); n != 1 {
		t.Fatalf("want 1 Resend domain, got %d", n)
	}
	want := map[string]string{
		"mail-dkim":            `TXT resend._domainkey.vault.example.org. "p=MIGfMA0GCSqGSIb3DQEB"`,
		"mail-return-path-mx":  `MX send.vault.example.org. 10 feedback-smtp.us-east-1.amazonses.com.`,
		"mail-return-path-spf": `TXT send.vault.example.org. "v=spf1 include:amazonses.com ~all"`,
		// Only in the full record list, not in a convenience output.
		"mail-return-path-cname": `CNAME rsend.vault.example.org. send.forge.rmta.net.`,
	}
	for _, r := range m.byType("gcp:dns/recordSet:RecordSet") {
		w, ok := want[r.name]
		if !ok {
			continue
		}
		delete(want, r.name)
		if got := strings.Join(append([]string{str(r, "type"), str(r, "name")}, strs(r, "rrdatas")...), " "); got != w {
			t.Errorf("%s:\n got %s\nwant %s", r.name, got, w)
		}
	}
	for name := range want {
		t.Errorf("missing record %s", name)
	}
	if n := len(m.byType("resend:index:DomainVerification")); n != 1 {
		t.Errorf("want 1 domain verification, got %d", n)
	}
}

// fakeActive stands in for the Parameter Manager lookup for one test: values
// maps a parameter name to its boolean, and a missing name is a lookup error.
func fakeActive(t *testing.T, values map[string]bool) {
	t.Helper()
	orig := stackActive
	stackActive = func(_ context.Context, project, parameter string) (bool, error) {
		if project != "demo" {
			return false, fmt.Errorf("unexpected project %q", project)
		}
		v, ok := values[parameter]
		if !ok {
			return false, errors.New("parameter " + parameter + " not found")
		}
		return v, nil
	}
	t.Cleanup(func() { stackActive = orig })
}

const paramStacksJSON = `[
  {"name":"disposable","fqdn":"disposable.vault.example.org.","activeParameter":"vaultwarden-disposable-active"},
  {"name":"production","fqdn":"vault.example.org.","active":true}
]`

func TestActiveParameterSwitchesTheStack(t *testing.T) {
	for _, active := range []bool{true, false} {
		t.Run(fmt.Sprint(active), func(t *testing.T) {
			fakeActive(t, map[string]bool{"vaultwarden-disposable-active": active})
			cfg := baseConfig()
			cfg["vaultwarden-platform:stacks"] = paramStacksJSON
			m := mustRun(t, cfg)

			addrs, grants := 0, 0
			for _, r := range m.byType("gcp:compute/address:Address") {
				if strings.Contains(r.name, "disposable") {
					addrs++
				}
			}
			for _, r := range m.byType("gcp:secretmanager/secretIamMember:SecretIamMember") {
				if strings.Contains(str(r, "secretId"), "disposable") {
					grants++
				}
			}
			want := map[bool]int{true: 2, false: 0}[active]
			if addrs != want || grants != want {
				t.Errorf("active=%v: want %d disposable addresses and grants, got %d and %d", active, want, addrs, grants)
			}
			if n := len(m.byType("cloudflare:index/r2Bucket:R2Bucket")); n != 2 {
				t.Errorf("want both R2 buckets whatever the parameter says, got %d", n)
			}
		})
	}
}

// An unreadable parameter fails the run. Treating it as "inactive" would let a
// typo or an API error release the stack's static IPs and DNS.
func TestUnreadableActiveParameterFailsTheRun(t *testing.T) {
	fakeActive(t, map[string]bool{}) // every lookup errors
	cfg := baseConfig()
	cfg["vaultwarden-platform:stacks"] = paramStacksJSON
	m, err := run(t, cfg)
	if err == nil || !strings.Contains(err.Error(), "vaultwarden-disposable-active") {
		t.Fatalf("want an error naming the parameter, got %v", err)
	}
	if n := len(m.byType("gcp:compute/address:Address")); n != 0 {
		t.Errorf("the failed run still declared %d addresses", n)
	}
}

func TestParseActiveAcceptsOnlyJSONBooleans(t *testing.T) {
	for payload, want := range map[string]bool{"true": true, "false": false, "true\n": true, "false \r\n": false} {
		if got, err := ParseActive(payload); err != nil || got != want {
			t.Errorf("ParseActive(%q) = %v, %v; want %v", payload, got, err, want)
		}
	}
	for _, payload := range []string{"", "1", "0", `"true"`, "True", "TRUE", "yes", " true", "true false", "null", "{}"} {
		if _, err := ParseActive(payload); err == nil {
			t.Errorf("ParseActive(%q) accepted a non-boolean", payload)
		}
	}
}

func TestValidationRejectsBadConfig(t *testing.T) {
	cases := map[string]map[string]string{
		"active and activeParameter": {"vaultwarden-platform:stacks": `[{"name":"disposable","fqdn":"d.vault.example.org.","active":true,"activeParameter":"vaultwarden-disposable-active"}]`},
		"neither active setting":     {"vaultwarden-platform:stacks": `[{"name":"disposable","fqdn":"d.vault.example.org."}]`},
		"foreign activeParameter":    {"vaultwarden-platform:stacks": `[{"name":"disposable","fqdn":"d.vault.example.org.","activeParameter":"vaultwarden-production-active"}]`},
		"gs:// prefix":               {"vaultwarden-platform:appStateBucket": "gs://demo-pulumi-state"},
		"no trailing dot":            {"vaultwarden-platform:stacks": `[{"name":"prod","fqdn":"vault.example.org","active":true}]`},
		"fqdn outside zone":          {"vaultwarden-platform:stacks": `[{"name":"prod","fqdn":"vault.example.com.","active":true}]`},
		"mail outside zone":          {"vaultwarden-platform:mailDomain": "example.org"},
		"mail with dot":              {"vaultwarden-platform:mailDomain": "vault.example.org."},
		"bad stack name":             {"vaultwarden-platform:stacks": `[{"name":"Prod-1","fqdn":"vault.example.org.","active":true}]`},
		"duplicate stack":            {"vaultwarden-platform:stacks": `[{"name":"prod","fqdn":"vault.example.org.","active":true},{"name":"prod","fqdn":"x.vault.example.org.","active":true}]`},
	}
	for name, override := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := baseConfig()
			for k, v := range override {
				cfg[k] = v
			}
			if _, err := run(t, cfg); err == nil {
				t.Error("expected a validation error")
			}
		})
	}
}

func readSecretNames(t *testing.T, path string) map[string]bool {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	defer f.Close()
	names := map[string]bool{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(strings.SplitN(sc.Text(), "#", 2)[0])
		if line != "" {
			names[line] = true
		}
	}
	return names
}
