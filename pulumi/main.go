// The vaultwarden app stack: one GCE VM plus its data disk, per Pulumi stack
// (`disposable`, `production`). Run by Gitea Actions with the deployer SA key.
//
// Everything this stack consumes but must not own -- network, firewall, the
// static addresses and their DNS records, the registry, IAM -- comes from the
// owner-run platform stack (../platform). The deployer can't change those, so
// a leaked CI key can rebuild the VM but can't widen anyone's access.
//
// The instance has NO attached service account: nothing on the box can mint
// a Google token. Secrets are pushed by Ansible from the controller; Caddy's
// DNS-01 uses its own SA key (a Podman secret).
package main

import (
	"fmt"

	gcpcompute "github.com/pulumi/pulumi-gcp/sdk/v9/go/gcp/compute"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi"
	"github.com/pulumi/pulumi/sdk/v3/go/pulumi/config"
)

const (
	// NetworkTag must match platform's NetworkTag: every firewall rule targets it.
	NetworkTag = "vaultwarden"

	// DataDiskDeviceName is how the guest sees the data disk:
	// /dev/disk/by-id/google-vault-data. Ansible's base role mounts it at /data.
	DataDiskDeviceName = "vault-data"

	// BootImage is a family, not a pinned image: new VMs get the current build,
	// and the family is never re-resolved for an existing VM, so it causes no
	// diff. Changing this string DOES replace the VM.
	BootImage = "almalinux-cloud/almalinux-10"
)

type Config struct {
	Project           string
	Region            string
	Zone              string
	MachineType       string
	BootDiskGB        int
	DataDiskGB        int
	SnapshotRetention int
	DeleteProtection  bool
}

func loadConfig(ctx *pulumi.Context) (*Config, error) {
	gcpCfg := config.New(ctx, "gcp")
	c := config.New(ctx, "vaultwarden")
	cfg := &Config{
		Project:           gcpCfg.Require("project"),
		Region:            gcpCfg.Require("region"),
		Zone:              c.Require("zone"),
		MachineType:       c.Get("machineType"),
		BootDiskGB:        c.GetInt("bootDiskGb"),
		DataDiskGB:        c.GetInt("dataDiskGb"),
		SnapshotRetention: c.GetInt("snapshotRetentionDays"),
		// Off by default so disposable can destroy/up freely. Production sets
		// it: the data disk becomes Pulumi-protected and both the disk and the
		// instance refuse deletion at the API.
		DeleteProtection: c.GetBool("deleteProtection"),
	}
	if cfg.MachineType == "" {
		cfg.MachineType = "e2-small"
	}
	if cfg.BootDiskGB == 0 {
		cfg.BootDiskGB = 20
	}
	if cfg.DataDiskGB == 0 {
		cfg.DataDiskGB = 10
	}
	if cfg.SnapshotRetention == 0 {
		cfg.SnapshotRetention = 7
	}
	return cfg, cfg.validate()
}

// validate fails the preview, not the apply.
func (c *Config) validate() error {
	if len(c.Zone) <= len(c.Region) || c.Zone[:len(c.Region)] != c.Region {
		return fmt.Errorf("zone %q is not in region %q", c.Zone, c.Region)
	}
	if c.BootDiskGB < 20 {
		return fmt.Errorf("bootDiskGb %d: the AlmaLinux image needs at least 20", c.BootDiskGB)
	}
	if c.DataDiskGB < 10 {
		return fmt.Errorf("dataDiskGb %d: pd-balanced minimum is 10", c.DataDiskGB)
	}
	return nil
}

func main() { pulumi.Run(program) }

func program(ctx *pulumi.Context) error {
	cfg, err := loadConfig(ctx)
	if err != nil {
		return err
	}
	stack := ctx.Stack()
	name := "vault-" + stack

	// Owned by platform/ (and named by its AddressName convention). Looked up,
	// so the A/AAAA records never move when this stack is destroyed and rebuilt.
	v4, err := gcpcompute.LookupAddress(ctx, &gcpcompute.LookupAddressArgs{
		Name: name + "-ipv4", Region: &cfg.Region, Project: &cfg.Project,
	})
	if err != nil {
		return fmt.Errorf("look up %s-ipv4 (is the stack active in platform/?): %w", name, err)
	}
	v6, err := gcpcompute.LookupAddress(ctx, &gcpcompute.LookupAddressArgs{
		Name: name + "-ipv6", Region: &cfg.Region, Project: &cfg.Project,
	})
	if err != nil {
		return fmt.Errorf("look up %s-ipv6: %w", name, err)
	}
	if v6.Subnetwork == "" {
		return fmt.Errorf("%s-ipv6 has no subnetwork; it must be an external IPv6 VM address", name)
	}

	protect := pulumi.Protect(cfg.DeleteProtection)

	// Separate from the boot disk so replacing the instance never touches the
	// vault. A pd-balanced disk can grow in place later, never shrink.
	disk, err := gcpcompute.NewDisk(ctx, name+"-data", &gcpcompute.DiskArgs{
		Project:     pulumi.String(cfg.Project),
		Name:        pulumi.String(name + "-data"),
		Zone:        pulumi.String(cfg.Zone),
		Size:        pulumi.Int(cfg.DataDiskGB),
		Type:        pulumi.String("pd-balanced"),
		Description: pulumi.String("Vaultwarden /data: db.sqlite3, attachments, sends"),
		Labels:      labels(stack),
	}, protect)
	if err != nil {
		return err
	}

	// Crash-consistent safety net under the restic backups (which are the
	// portable, off-provider copy). Kept even if the disk is deleted.
	policy, err := gcpcompute.NewResourcePolicy(ctx, name+"-snapshots", &gcpcompute.ResourcePolicyArgs{
		Project: pulumi.String(cfg.Project),
		Name:    pulumi.String(name + "-daily-snapshots"),
		Region:  pulumi.String(cfg.Region),
		SnapshotSchedulePolicy: &gcpcompute.ResourcePolicySnapshotSchedulePolicyArgs{
			Schedule: &gcpcompute.ResourcePolicySnapshotSchedulePolicyScheduleArgs{
				DailySchedule: &gcpcompute.ResourcePolicySnapshotSchedulePolicyScheduleDailyScheduleArgs{
					DaysInCycle: pulumi.Int(1),
					// After the 02:30 UTC restic run, so the snapshot also holds
					// that night's consistent db-backup.sqlite3.
					StartTime: pulumi.String("03:00"),
				},
			},
			RetentionPolicy: &gcpcompute.ResourcePolicySnapshotSchedulePolicyRetentionPolicyArgs{
				MaxRetentionDays:   pulumi.Int(cfg.SnapshotRetention),
				OnSourceDiskDelete: pulumi.String("KEEP_AUTO_SNAPSHOTS"),
			},
			SnapshotProperties: &gcpcompute.ResourcePolicySnapshotSchedulePolicySnapshotPropertiesArgs{
				StorageLocations: pulumi.String(cfg.Region),
				Labels:           labels(stack),
			},
		},
	})
	if err != nil {
		return err
	}
	if _, err := gcpcompute.NewDiskResourcePolicyAttachment(ctx, name+"-data-snapshots", &gcpcompute.DiskResourcePolicyAttachmentArgs{
		Project: pulumi.String(cfg.Project),
		Name:    policy.Name,
		Disk:    disk.Name,
		Zone:    pulumi.String(cfg.Zone),
	}); err != nil {
		return err
	}

	vm, err := gcpcompute.NewInstance(ctx, name, &gcpcompute.InstanceArgs{
		Project:     pulumi.String(cfg.Project),
		Name:        pulumi.String(name),
		Zone:        pulumi.String(cfg.Zone),
		MachineType: pulumi.String(cfg.MachineType),
		Tags:        pulumi.ToStringArray([]string{NetworkTag}),
		Description: pulumi.String("Vaultwarden + Caddy as rootless podman quadlets on AlmaLinux 10; configured by Ansible"),
		Labels:      labels(stack),

		BootDisk: &gcpcompute.InstanceBootDiskArgs{
			InitializeParams: &gcpcompute.InstanceBootDiskInitializeParamsArgs{
				Image: pulumi.String(BootImage),
				Size:  pulumi.Int(cfg.BootDiskGB),
				Type:  pulumi.String("pd-balanced"),
			},
		},
		AttachedDisks: gcpcompute.InstanceAttachedDiskArray{
			&gcpcompute.InstanceAttachedDiskArgs{
				Source:     disk.ID(),
				DeviceName: pulumi.String(DataDiskDeviceName),
				Mode:       pulumi.String("READ_WRITE"),
			},
		},

		NetworkInterfaces: gcpcompute.InstanceNetworkInterfaceArray{
			&gcpcompute.InstanceNetworkInterfaceArgs{
				Subnetwork: pulumi.String(v6.Subnetwork),
				StackType:  pulumi.String("IPV4_IPV6"),
				AccessConfigs: gcpcompute.InstanceNetworkInterfaceAccessConfigArray{
					&gcpcompute.InstanceNetworkInterfaceAccessConfigArgs{
						NatIp: pulumi.String(v4.Address),
					},
				},
				Ipv6AccessConfigs: gcpcompute.InstanceNetworkInterfaceIpv6AccessConfigArray{
					&gcpcompute.InstanceNetworkInterfaceIpv6AccessConfigArgs{
						NetworkTier:              pulumi.String("PREMIUM"),
						ExternalIpv6:             pulumi.String(v6.Address),
						ExternalIpv6PrefixLength: pulumi.String(fmt.Sprint(v6.PrefixLength)),
					},
				},
			},
		},

		// Deliberately no ServiceAccount: see the package comment.

		Metadata: pulumi.StringMap{
			// SSH access follows IAM (OS Login) instead of metadata keys...
			"enable-oslogin":         pulumi.String("TRUE"),
			"block-project-ssh-keys": pulumi.String("TRUE"),
			// ...and the guest agent publishes its SSH host keys here, which
			// scripts/ansible-iap.sh turns into a pinned known_hosts.
			"enable-guest-attributes": pulumi.String("TRUE"),
		},

		ShieldedInstanceConfig: &gcpcompute.InstanceShieldedInstanceConfigArgs{
			EnableSecureBoot:          pulumi.Bool(true),
			EnableVtpm:                pulumi.Bool(true),
			EnableIntegrityMonitoring: pulumi.Bool(true),
		},

		// Machine-type changes stop/resize/start in place instead of failing.
		AllowStoppingForUpdate: pulumi.Bool(true),
		DeletionProtection:     pulumi.Bool(cfg.DeleteProtection),
	})
	if err != nil {
		return err
	}

	// Consumed by scripts/ansible-iap.sh and the runbook.
	ctx.Export("instanceName", vm.Name)
	ctx.Export("zone", pulumi.String(cfg.Zone))
	ctx.Export("project", pulumi.String(cfg.Project))
	ctx.Export("ipv4", pulumi.String(v4.Address))
	ctx.Export("ipv6", pulumi.String(v6.Address))
	ctx.Export("dataDisk", disk.Name)
	return nil
}

func labels(stack string) pulumi.StringMap {
	return pulumi.StringMap{
		"app":        pulumi.String("vaultwarden"),
		"stack":      pulumi.String(stack),
		"managed-by": pulumi.String("pulumi"),
	}
}
