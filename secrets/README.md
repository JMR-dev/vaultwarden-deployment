# Secrets

Secrets live in **Google Cloud Secret Manager**, not in this repo. Ansible
fetches them at deploy time via `gcloud secrets versions access` (the
controller — operator's laptop or Cloud Build — must be authed to GCP via
ADC).

This directory only holds documentation now; nothing here is committed
beyond this file.

## One-time setup

Pick a GCP project (the same one that owns the Cloud DNS zone is the
obvious fit) and enable the API:

```sh
gcloud services enable secretmanager.googleapis.com --project <PROJECT>
```

Set `gcp_project` in `ansible/group_vars/all.yml`.

Grant the **Cloud Build service account** (the one referenced from
`cloudbuild.yaml`) `roles/secretmanager.secretAccessor` on each of the
secrets below.

For local operator runs:

```sh
gcloud auth application-default login
```

ADC lands at `~/.config/gcloud/application_default_credentials.json` and
Ansible's `gcloud` invocations pick it up automatically.

## Required secrets

### `vaultwarden-msmtp` — outbound mail (system-wide msmtp)

```yaml
msmtp_smtp_host: smtp.example.com
msmtp_smtp_port: 587
msmtp_smtp_user: vault@example.com
msmtp_smtp_password: <smtp password>
msmtp_from: vault@example.com
```

```sh
gcloud secrets create vaultwarden-msmtp --replication-policy=automatic
gcloud secrets versions add vaultwarden-msmtp --data-file=- < msmtp.yml
```

### `vaultwarden-wireguard` — WG server privkey

```yaml
wg_server_privkey: <output of `wg genkey`>
```

Peer pubkeys + addresses live in the inventory file (they aren't secret —
public-key crypto, the name says it).

```sh
wg genkey > /tmp/wg.key
printf 'wg_server_privkey: %s\n' "$(cat /tmp/wg.key)" \
  | gcloud secrets create vaultwarden-wireguard --replication-policy=automatic --data-file=-
shred -u /tmp/wg.key
```

### `vaultwarden-vaultwarden` — admin token + GCP SA JSON

```yaml
# Argon2id hash of the admin password. Generate with:
#   podman run --rm -it docker.io/vaultwarden/server /vaultwarden hash
# Leave empty/absent to disable /admin entirely.
admin_token_argon2: |
  $argon2id$v=19$...

# GCP service account JSON (dns.admin on the vault DNS zone). Used by
# Caddy for DNS-01 challenges. Paste the whole JSON as a YAML literal.
gcp_sa_dns_json: |
  {
    "type": "service_account",
    ...
  }
```

### `vaultwarden-restic` — backup destination

```yaml
restic_repository: s3:s3.<region>.r2.cloudflarestorage.com/<bucket>
restic_password: <strong, randomly-generated>
r2_access_key_id: <R2 access key>
r2_secret_access_key: <R2 secret key>
```

### `vaultwarden-healthchecks` — per-timer ping URLs

```yaml
hc_backup_url:         https://hc-ping.com/<uuid>
hc_restic_check_url:   https://hc-ping.com/<uuid>
hc_dnf_automatic_url:  https://hc-ping.com/<uuid>
hc_podman_update_url:  https://hc-ping.com/<uuid>
```

Create one Healthchecks check per timer with the expected interval set to
match the corresponding systemd timer.

## Cloud Build-only secrets

These are referenced from `cloudbuild.yaml` and only matter when running
deploys through Cloud Build. Each holds a single raw value (not YAML).

### `vaultwarden-hcloud-token` — Hetzner Cloud API token

```sh
read -s -p "hcloud token: " TOK; echo
printf '%s' "$TOK" \
  | gcloud secrets create vaultwarden-hcloud-token --replication-policy=automatic --data-file=-
unset TOK
```

Used by Pulumi (to provision the host) and by the Cloud Build deploy
step's firewall flip-and-close trap.

### `vaultwarden-ssh-private-key` — Ansible SSH key

The private half of the keypair whose public half is in
`pulumi config vaultwarden:sshPubkey`. Cloud Build writes this to
`~/.ssh/id_ed25519` for the duration of the deploy step.

```sh
ssh-keygen -t ed25519 -f /tmp/vault-ssh -N ""
gcloud secrets create vaultwarden-ssh-private-key --replication-policy=automatic --data-file=/tmp/vault-ssh
# Put /tmp/vault-ssh.pub into Pulumi config as vaultwarden:sshPubkey.
shred -u /tmp/vault-ssh /tmp/vault-ssh.pub
```

## Editing

```sh
# Read:
gcloud secrets versions access latest --secret=vaultwarden-msmtp

# Update (creates a new version; old versions remain in audit history):
gcloud secrets versions add vaultwarden-msmtp --data-file=msmtp.yml

# Delete an old version (optional; versioned secrets are cheap):
gcloud secrets versions destroy 1 --secret=vaultwarden-msmtp
```

## Why no local SOPS files

The repo used to ship `.sops.yaml` and `secrets/*.sops.yml`. Trade-off
moving to GCSM + OIDC:

- **+** No long-lived age key on the operator's laptop. ADC re-authes via
  browser; Cloud Build authenticates via its own SA identity.
- **+** Rotation happens in Secret Manager without a git commit.
- **+** Audit trail moves to GCP audit logs (centralized, searchable).
- **−** Secrets aren't versioned in git history (they're versioned in
  GCSM instead — different system, same property).
- **−** Deploys now depend on Secret Manager API being reachable.
