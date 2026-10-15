# Vaultwarden self-host deployment

Reproducible, single-user, zero-knowledge Vaultwarden on one Google Compute
Engine VM (AlmaLinux 10), with rootless Podman quadlets, a custom Caddy
(DNS-01 + Coraza DetectionOnly), restic backups to Cloudflare R2, and
IAP + OS Login as the only way in. Deployed by Gitea Actions.

Operator guide: [`runbook/README.md`](runbook/README.md).

## Layout

| Path | Purpose |
|---|---|
| `platform/` | Pulumi (Go), **owner-run**: VPC + firewall, static IPs, DNS records, R2 buckets, Artifact Registry, the CI deployer SA and every IAM grant |
| `pulumi/` | Pulumi (Go), **CI-run**: the VM, its data disk and daily snapshots, per stack (`disposable`, `production`) |
| `ansible/` | Host config: data disk + swap, Podman, msmtp, nftables, fail2ban, dnf-automatic, Secret Manager → Podman secrets, quadlets, backups |
| `quadlets/` | Rootless Vaultwarden + Caddy quadlet units |
| `caddy/` | Custom Caddy build (Containerfile + pinned versions) and the Caddyfile |
| `backup/` | SQLite snapshot + restic + systemd timers + Healthchecks pings |
| `scripts/` | `bootstrap-gcp.sh` (one-time), `ansible-iap.sh` (run Ansible over IAP), `build-caddy.sh` (build + Trivy), `rotate-deployer-key.sh` |
| `.gitea/` | `ci.yml` (checks, no secrets), `deploy.yml` (image → Pulumi → Ansible), shared setup action |
| `secrets/` | `secret-names.txt` + schemas. Values live in Google Cloud Secret Manager only |
| `runbook/` | Deployment runbook, verification, cutover, restore drill |

## Stack

| Layer | Choice |
|---|---|
| Compute | GCE `e2-small`, us-east1-b, AlmaLinux 10, Shielded VM, separate protected data disk, no attached service account |
| IaC | Pulumi (Go), GCS state, KMS (`gcpkms://`) secrets provider; split into an owner-run platform stack and a CI-run app stack |
| OS config | Ansible, run over IAP by `scripts/ansible-iap.sh` |
| CI/CD | Gitea Actions. CI authenticates with a deployer SA key (Gitea 1.27 has no Actions OIDC); the SA can't grant IAM |
| Secrets | Google Cloud Secret Manager, read on the Ansible controller; nothing secret in the repo or on Pulumi state |
| Reverse proxy / TLS / WAF | Caddy (custom: googleclouddns DNS-01 + Coraza DetectionOnly) |
| Network filtering | VPC firewall + host nftables (own table, never flushed) + fail2ban |
| Admin access | IAP TCP forwarding + OS Login (SSH and `/admin`); no public SSH, no SSH keys at rest |
| Containers | Rootless Podman quadlets, SELinux enforcing, health-gated `podman auto-update` |
| DB | SQLite (single user) |
| Updates | `dnf-automatic` (OS) + `podman auto-update` on floating `:<stack>` tags (containers) |
| Backups | restic → Cloudflare R2 (per-stack bucket), plus daily GCE disk snapshots |
| DNS | GCP Cloud DNS (zone `vault`, delegated from jasonmross.dev) |
| Alerting | Healthchecks.io (timer pings) + msmtp email (`systemd OnFailure=`) |

## Build-it-disposably-first

Two app stacks: `disposable` (`disposable.vault.jasonmross.dev`, no real
data) and `production` (`vault.jasonmross.dev`). Iterate destroy/redeploy on
`disposable` until it stands up with zero hand-intervention, then promote to
`production` (runbook §2–§4).
