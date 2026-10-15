// Invariant tests under Pulumi's mock runtime: no cloud calls, no credentials.

package main

import (
	"encoding/json"
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
	return a.Name + "_id", a.Inputs.Copy(), nil
}

func (m *mocks) Call(a pulumi.MockCallArgs) (resource.PropertyMap, error) {
	if a.Token == "gcp:compute/getAddress:getAddress" {
		name := a.Args["name"].StringValue()
		if len(name) > 5 && name[len(name)-5:] == "-ipv6" {
			return resource.PropertyMap{
				"address":      resource.NewStringProperty("2600:1900:4000::"),
				"prefixLength": resource.NewNumberProperty(96),
				"subnetwork":   resource.NewStringProperty("https://www.googleapis.com/compute/v1/projects/demo/regions/us-east1/subnetworks/vaultwarden-us-east1"),
			}, nil
		}
		return resource.PropertyMap{"address": resource.NewStringProperty("203.0.113.9")}, nil
	}
	return resource.PropertyMap{}, nil
}

func (m *mocks) one(t *testing.T, typ string) rec {
	t.Helper()
	var found []rec
	for _, r := range m.recs {
		if r.typ == typ {
			found = append(found, r)
		}
	}
	if len(found) != 1 {
		t.Fatalf("want exactly one %s, got %d", typ, len(found))
	}
	return found[0]
}

func run(t *testing.T, stack string, extra map[string]string) (*mocks, error) {
	t.Helper()
	cfg := map[string]string{
		"gcp:project":      "demo",
		"gcp:region":       "us-east1",
		"vaultwarden:zone": "us-east1-b",
	}
	for k, v := range extra {
		cfg[k] = v
	}
	b, _ := json.Marshal(cfg)
	t.Setenv("PULUMI_CONFIG", string(b))
	m := &mocks{}
	err := pulumi.RunErr(program, pulumi.WithMocks("vaultwarden", stack, m))
	return m, err
}

const instanceType = "gcp:compute/instance:Instance"

// The VM must not be able to mint Google tokens: nothing on it needs one, and
// the default compute SA would arrive with project Editor.
func TestInstanceHasNoServiceAccount(t *testing.T) {
	m, err := run(t, "disposable", nil)
	if err != nil {
		t.Fatal(err)
	}
	vm := m.one(t, instanceType)
	if v, ok := vm.inputs["serviceAccount"]; ok && !v.IsNull() {
		t.Errorf("instance has a serviceAccount: %v", v)
	}
}

func TestInstanceAccessIsOSLoginOnly(t *testing.T) {
	m, err := run(t, "disposable", nil)
	if err != nil {
		t.Fatal(err)
	}
	md := m.one(t, instanceType).inputs["metadata"].ObjectValue()
	for k, want := range map[string]string{
		"enable-oslogin":          "TRUE",
		"block-project-ssh-keys":  "TRUE",
		"enable-guest-attributes": "TRUE",
	} {
		if got := md[resource.PropertyKey(k)]; !got.IsString() || got.StringValue() != want {
			t.Errorf("metadata %s = %v, want %s", k, got, want)
		}
	}
	if _, ok := md["startup-script"]; ok {
		t.Error("startup-script in metadata: host config belongs to Ansible")
	}
	if _, ok := m.one(t, instanceType).inputs["metadataStartupScript"]; ok {
		t.Error("metadataStartupScript is force-new; keep it unset")
	}
}

func TestDeleteProtectionFollowsConfig(t *testing.T) {
	for _, tc := range []struct {
		val  string
		want bool
	}{{"true", true}, {"false", false}} {
		m, err := run(t, "production", map[string]string{"vaultwarden:deleteProtection": tc.val})
		if err != nil {
			t.Fatal(err)
		}
		vm := m.one(t, instanceType)
		if got := vm.inputs["deletionProtection"]; !got.IsBool() || got.BoolValue() != tc.want {
			t.Errorf("deleteProtection=%s: instance deletionProtection = %v", tc.val, got)
		}
	}
}

func TestNamesFollowStack(t *testing.T) {
	m, err := run(t, "production", nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.one(t, instanceType).inputs["name"].StringValue(); got != "vault-production" {
		t.Errorf("instance name %q", got)
	}
	if got := m.one(t, "gcp:compute/disk:Disk").inputs["name"].StringValue(); got != "vault-production-data" {
		t.Errorf("disk name %q", got)
	}
}

func TestValidationRejectsBadConfig(t *testing.T) {
	for name, extra := range map[string]map[string]string{
		"zone outside region": {"vaultwarden:zone": "europe-west3-a"},
		"tiny boot disk":      {"vaultwarden:bootDiskGb": "10"},
		"tiny data disk":      {"vaultwarden:dataDiskGb": "5"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := run(t, "disposable", extra); err == nil {
				t.Error("expected a validation error")
			}
		})
	}
}
