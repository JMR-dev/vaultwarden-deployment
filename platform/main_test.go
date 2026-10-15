// Invariant tests under Pulumi's mock runtime: no cloud calls, no credentials.
// They pin down what this stack exists to guarantee -- mainly that the CI
// deployer can never be handed a role that lets it widen its own access.

package main

import (
	"bufio"
	"encoding/json"
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

// Every secret granted must exist as a container (bootstrap creates them from
// secret-names.txt, and a grant on a missing secret fails the apply), and the
// owner-only Cloudflare token must never be granted to the deployer.
func TestSecretGrantsMatchSecretNames(t *testing.T) {
	m := mustRun(t, baseConfig())
	listed := readSecretNames(t, "../secrets/secret-names.txt")
	for _, r := range m.byType("gcp:secretmanager/secretIamMember:SecretIamMember") {
		id := str(r, "secretId")
		if !listed[id] {
			t.Errorf("secret %q is granted but missing from secrets/secret-names.txt", id)
		}
		if strings.Contains(id, "cloudflare") {
			t.Errorf("secret %q is owner-only and must not be granted", id)
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
	if n := len(m.byType("gcp:dns/recordSet:RecordSet")); n != 2 {
		t.Errorf("want A+AAAA for production only, got %d records", n)
	}
}

func TestValidationRejectsBadConfig(t *testing.T) {
	cases := map[string]map[string]string{
		"gs:// prefix":      {"vaultwarden-platform:appStateBucket": "gs://demo-pulumi-state"},
		"no trailing dot":   {"vaultwarden-platform:stacks": `[{"name":"prod","fqdn":"vault.example.org","active":true}]`},
		"fqdn outside zone": {"vaultwarden-platform:stacks": `[{"name":"prod","fqdn":"vault.example.com.","active":true}]`},
		"bad stack name":    {"vaultwarden-platform:stacks": `[{"name":"Prod-1","fqdn":"vault.example.org.","active":true}]`},
		"duplicate stack":   {"vaultwarden-platform:stacks": `[{"name":"prod","fqdn":"vault.example.org.","active":true},{"name":"prod","fqdn":"x.vault.example.org.","active":true}]`},
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
