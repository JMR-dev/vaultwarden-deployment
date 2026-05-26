# Vaultwarden self-host deployment

Reproducible, single-user, zero-knowledge Vaultwarden on Hetzner Cloud + AlmaLinux 10
with rootless Podman quadlets, custom Caddy (DNS-01 + Coraza DetectionOnly), restic
backups to Cloudflare R2, and WireGuard-gated admin access.

Plan: `~/.claude/plans/vaultwarden-self-host-sharded-creek.md`.

## Layout

| Path | Purpose |
|---|---|
| `cloudbuild.yaml` | Cloud Build pipeline — drives Pulumi + image build + Ansible |
| `pulumi/` | Phase 1: Hetzner server, Cloud Firewall, volume, GCP Cloud DNS records (Pulumi Go) |
| `caddy/` | Phase 2: custom Caddy build (Containerfile + pinned versions) and the Caddyfile |
| `ansible/` | Phase 3: OS hardening, WireGuard server, nftables, fail2ban, msmtp, dnf-automatic, Secret Manager → Podman secrets |
| `quadlets/` | Phase 4: rootless Vaultwarden + Caddy quadlet units |
| `backup/` | Phase 5: SQLite-snapshot + restic + systemd timer + Healthchecks pings |
| `runbook/` | Deployment runbook, cutover checklist, restore drill |
| `secrets/` | Docs only — secret material lives in Google Cloud Secret Manager, fetched at deploy time |

## Stack

| Layer | Choice |
|---|---|
| Compute | Hetzner Cloud, CX22, AlmaLinux 10 (`alma-10` image) |
| IaC | Pulumi (Go) |
| OS config | Ansible |
| Build / deploy pipeline | Google Cloud Build (image build, Trivy scan, Pulumi, Ansible) |
| Secrets | Google Cloud Secret Manager (OIDC via Cloud Build SA; ADC for local operator) |
| Reverse proxy / TLS / WAF | Caddy (custom: googleclouddns DNS-01 + Coraza DetectionOnly) |
| Network filtering | Hetzner Cloud Firewall + host nftables + Fail2Ban |
| Containers | Rootless Podman quadlets, SELinux enforcing |
| DB | SQLite (single-user; no replication required) |
| Updates | `dnf-automatic` (OS) + `podman auto-update` (containers) |
| Backups | restic → Cloudflare R2 |
| DNS | GCP Cloud DNS |
| Admin/SSH gating | WireGuard server on the Vaultwarden host |
| Alerting | Healthchecks.io (timer pings) + msmtp email (`systemd OnFailure=`) |

## Build-it-disposably-first

Two Pulumi stacks: `disposable` (throwaway hostname, no real vault data) and `production`.
Iterate `pulumi destroy && pulumi up` on `disposable` until the stack stands up cleanly
with zero hand-intervention, then promote to `production` for migration.

## Pinned versions

See `memory/coraza_caddy_version.md` for the Coraza/Caddy version pinning rationale.
