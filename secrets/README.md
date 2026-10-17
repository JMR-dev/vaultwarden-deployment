# Secrets

Secrets live in **Google Cloud Secret Manager** (project `vaultwarden-497422`),
never in this repo, never in Pulumi state, never in instance metadata. The
full list is [`secret-names.txt`](secret-names.txt):

- `scripts/bootstrap-gcp.sh` creates each one as an **empty container**.
- `platform/` grants access to each by id.
- You add the values by hand (below).
- Ansible reads them on the controller at deploy time, via
  `gcloud secrets versions access`. That's the Gitea Actions runner
  (deployer SA key) or your laptop (ADC).

The VM has no Google identity; it only ever sees rendered files and Podman
secrets.

## Adding a value

Pipe YAML on stdin so nothing lands on disk:

```sh
gcloud secrets versions add <name> --project vaultwarden-497422 --data-file=- <<'EOF'
key: value
EOF
```

Then redeploy the stack(s) that read it. Old versions stay in the audit
history; destroy them with `gcloud secrets versions destroy <n> --secret=<name>`.

## Shared by both stacks

### `vaultwarden-vaultwarden`: admin token + Caddy DNS-01 key

```yaml
# Argon2id hash of the admin password. Generate with:
#   podman run --rm -it docker.io/vaultwarden/server /vaultwarden hash
# Leave empty/absent to disable /admin entirely (the default).
admin_token_argon2: |
  $argon2id$v=19$...

# JSON key of vaultwarden-caddy-dns@ (zone-scoped dns.admin on `vault`, plus
# the dnsZoneLister custom role). Caddy uses it for DNS-01. Paste the whole
# JSON as a YAML literal. Rotate it like the deployer key (runbook §6).
gcp_sa_dns_json: |
  {
    "type": "service_account",
    ...
  }
```

### `vaultwarden-msmtp`: outbound mail (system msmtp)

GCE blocks outbound port 25; use 587 (STARTTLS). `msmtp_alert_to` is where
root's mail goes: unit-failure alerts, the daily fail2ban ban digest and the
restore-drill reminder. It lives here rather than in the inventory so no personal address
is committed.

```yaml
msmtp_smtp_host: smtp.example.com
msmtp_smtp_port: 587
msmtp_smtp_user: vault@example.com
msmtp_smtp_password: <smtp password>
msmtp_from: vault@example.com
msmtp_alert_to: you@example.com
```

With Gmail: host `smtp.gmail.com`, user and from are your Gmail address, and
the password is an [app password](https://myaccount.google.com/apppasswords)
(needs 2-Step Verification), not your account password.

## Per stack (`<stack>` = `disposable` or `production`)

Separate per stack so a disposable host can neither ping production's
Healthchecks nor read or delete production's backups.

### `vaultwarden-<stack>-restic`: backup destination

`platform/` creates the R2 bucket `vaultwarden-backups-<stack>`. In the
Cloudflare dashboard, create an R2 API token with **Object Read & Write**
scoped to **that one bucket**. Its S3 credentials go here:

```yaml
restic_repository: s3:https://<cloudflare-account-id>.r2.cloudflarestorage.com/vaultwarden-backups-<stack>
restic_password: <strong, random -- e.g. `openssl rand -base64 48`; store a copy offline>
r2_access_key_id: <R2 access key>
r2_secret_access_key: <R2 secret key>
```

Lose `restic_password` and the backups are unreadable: keep an offline copy.

### `vaultwarden-<stack>-healthchecks`: per-timer ping URLs

```yaml
hc_backup_url:         https://hc-ping.com/<uuid>
hc_restic_check_url:   https://hc-ping.com/<uuid>
hc_dnf_automatic_url:  https://hc-ping.com/<uuid>
hc_podman_update_url:  https://hc-ping.com/<uuid>
```

Create the four checks per stack, with periods matching the timers: backup
daily, restic check weekly, dnf-automatic weekly, podman auto-update daily.

## Owner-only

### `vaultwarden-cloudflare-api-token`

A single raw value, not YAML: a Cloudflare API token with **Workers R2
Storage: Edit** on the account. Only the platform stack's Cloudflare
provider uses it, run locally by the owner:

```sh
CLOUDFLARE_API_TOKEN=$(gcloud secrets versions access latest --secret=vaultwarden-cloudflare-api-token) pulumi up
```

The CI deployer is deliberately **not** granted it (`platform/main_test.go`
enforces this).

## Not in Secret Manager: the CI deployer key

`GCP_DEPLOYER_KEY` is a Gitea Actions repo secret holding a JSON key for
`vaultwarden-deployer@`. It's a key rather than OIDC because Gitea 1.27
can't mint Actions ID tokens. The deployer's grants (all in
`platform/main.go`) let it rebuild the VM, read the secrets above (except the
Cloudflare token), push images, and use IAP SSH. It can't grant IAM, create
SAs, change DNS, or read platform state. Create and rotate it with
`scripts/rotate-deployer-key.sh` (every 90 days).

## Retired

`vaultwarden-wireguard` and `vaultwarden-ssh-private-key` belonged to the
Hetzner/WireGuard design. Nothing reads them; delete them once production is
live (runbook §6).
