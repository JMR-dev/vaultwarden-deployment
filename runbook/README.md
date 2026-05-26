# Vaultwarden deployment runbook

Operator-facing guide. The architectural reasoning is in the plan at
`~/.claude/plans/vaultwarden-self-host-sharded-creek.md` — this file is the
*how*, not the *why*.

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [First-time bootstrap (disposable instance)](#2-first-time-bootstrap-disposable-instance)
3. [Verification checks](#3-verification-checks)
4. [Production deploy](#4-production-deploy)
5. [Migration cutover from hosted Bitwarden](#5-migration-cutover-from-hosted-bitwarden)
6. [Day-to-day operations](#6-day-to-day-operations)
7. [Update flow](#7-update-flow)
8. [Rollback](#8-rollback)
9. [Troubleshooting](#9-troubleshooting)
10. [Where things live](#10-where-things-live)

---

## 1. Prerequisites

One-time setup on the operator's machine + accounts:

- **Tools**: `pulumi`, `go` (1.x), `ansible-core ≥ 2.18`, `gcloud`, `wg`,
  `ssh`, `gh`, `podman` (for local Caddy image iteration).
- **Hetzner Cloud**: project + API token.
- **GCP**:
  - Project owning a Cloud DNS managed zone for the vault FQDN.
  - Service account with `roles/dns.admin` scoped to that zone, key JSON
    downloaded *(stored in Secret Manager as part of vaultwarden-vaultwarden,
    not on disk)*.
  - Secret Manager API enabled
    (`gcloud services enable secretmanager.googleapis.com`).
  - GCS bucket for Pulumi state.
  - Cloud Build SA (e.g. `vaultwarden-cb@<project>.iam.gserviceaccount.com`)
    with `roles/secretmanager.secretAccessor` on the secrets below,
    `roles/dns.admin` on the zone, `roles/storage.objectAdmin` on the
    Pulumi state bucket.
  - Domain NS records pointed at Cloud DNS.
- **Cloudflare R2**: bucket + S3-compatible token.
- **Healthchecks.io**: four checks (backup, restic check, podman
  auto-update, dnf-automatic). Note the ping URLs.
- **SMTP**: outbound creds for msmtp.
- **Artifact Registry**: Pulumi owns the Docker repo (`vault-images-<stack>`)
  per stack and grants `allUsers` reader on it. You don't pre-create it.
  Cloud Build SA needs `roles/artifactregistry.writer` on each repo Pulumi
  creates so it can push. Pick a region with `vaultwarden:gcpArRegion` in
  Pulumi config (close to Hetzner = `europe-west*`).
- **Local GCP auth**: `gcloud auth application-default login` once. ADC
  lands at `~/.config/gcloud/application_default_credentials.json` and
  Ansible's `gcloud secrets versions access` calls pick it up.
- **SSH key**: an ed25519 key for first-boot login (public half →
  `pulumi config vaultwarden:sshPubkey`; private half → Secret Manager).
- **Pulumi state backend**:
  `pulumi login gs://<your-pulumi-state-bucket>`.

### Create Secret Manager secrets

See `secrets/README.md` for the schema and `gcloud secrets create` commands
for each:

- `vaultwarden-msmtp`
- `vaultwarden-wireguard`
- `vaultwarden-vaultwarden` (admin token + GCP DNS SA JSON)
- `vaultwarden-restic`
- `vaultwarden-healthchecks`

Plus the Cloud Build-only secrets:

- `vaultwarden-hcloud-token`
- `vaultwarden-ssh-private-key`

(There's no GHCR token here — Artifact Registry auth uses the Cloud Build
SA's ADC, not a long-lived token.)

### Vaultwarden admin token (optional)

Skip this if you're keeping `/admin` disabled (the default). To enable:

```sh
podman run --rm -it docker.io/vaultwarden/server /vaultwarden hash
# Enter a strong password. Add the $argon2id$... hash to the
# vaultwarden-vaultwarden secret as admin_token_argon2.
```

---

## 2. First-time bootstrap (disposable instance)

The point of the disposable stack is to flush out platform surprises on
hardware you don't mind destroying. `pulumi destroy && pulumi up` until the
stack stands up with zero hand-intervention, then promote to production.

First-time bootstrap runs locally — Cloud Build can't take over until the
Pulumi stack exists. After bootstrap, normal deploys are
`gcloud builds submit --config cloudbuild.yaml`.

### 2.1 Build and push the custom Caddy image (first time only)

The image must exist in Artifact Registry before Ansible deploys the
Caddy quadlet. On the first run, build it locally — `pulumi up` (next
step) creates the AR repo, then this builds and pushes into it:

```sh
# After §2.2 pulumi up has created the AR repo, read its full path from
# the Pulumi output:
cd ../pulumi
IMAGE=$(pulumi -s disposable stack output imageRepo):latest
AR_HOST=$(echo "$IMAGE" | cut -d/ -f1)

# Configure podman to auth via gcloud ADC (one-time per shell).
gcloud auth configure-docker "$AR_HOST"

cd ../caddy
set -a; . versions.env; set +a
podman build \
  --build-arg GO_BUILDER_IMAGE="$GO_BUILDER_IMAGE" \
  --build-arg RUNTIME_IMAGE="$RUNTIME_IMAGE" \
  --build-arg XCADDY_VERSION="$XCADDY_VERSION" \
  --build-arg CADDY_VERSION="$CADDY_VERSION" \
  --build-arg CORAZA_CADDY_MODULE="$CORAZA_CADDY_MODULE" \
  --build-arg CORAZA_CADDY_VERSION="$CORAZA_CADDY_VERSION" \
  --build-arg GCD_MODULE="$GCD_MODULE" \
  --build-arg GCD_VERSION="$GCD_VERSION" \
  -t "$IMAGE" \
  -f Containerfile .

podman push "$IMAGE"
```

This step needs Pulumi to have already created the AR repo, so on a
fully-clean first deploy the order is: §2.2 Pulumi (creates repo) → §2.1
(builds + pushes into it) → §2.3 (Ansible deploys quadlets that pull it).
Subsequent rebuilds happen via Cloud Build.

### 2.2 Provision the disposable instance

```sh
cd ../pulumi
pulumi login gs://<your-pulumi-state-bucket>
pulumi stack init disposable
export HCLOUD_TOKEN=$(gcloud secrets versions access latest --secret=vaultwarden-hcloud-token)
pulumi config set vaultwarden:hostname            vault-disposable
pulumi config set vaultwarden:location            nbg1
pulumi config set vaultwarden:sshPubkey           "$(cat ~/.ssh/id_ed25519.pub)"
pulumi config set vaultwarden:bootstrapSshCidr    "$(curl -s ifconfig.me)/32"
pulumi config set vaultwarden:gcpProject          <project-id>
pulumi config set vaultwarden:dnsManagedZone      <zone-resource-name>
pulumi config set vaultwarden:dnsRecordName       vault-disposable.example.com.
pulumi config set vaultwarden:gcpArRegion         europe-west3

pulumi up
```

Note the `ipv4` output — that's the `ansible_host` for the inventory.

### 2.3 Run the Ansible playbook

```sh
cd ../ansible
ansible-galaxy collection install -r requirements.yml -p .collections
cp inventory/disposable.yml.example inventory/disposable.yml
# Edit inventory/disposable.yml: paste the IP, fill wg_peers with your peer
# pubkeys + addresses, set vault_fqdn = vault-disposable.example.com.
# Commit this file once happy — Cloud Build reads it on subsequent runs.

# Update group_vars/all.yml gcp_project to the real value.
ansible-playbook -i inventory/disposable.yml playbook.yml \
  --extra-vars "caddy_image=$(cd ../pulumi && pulumi -s disposable stack output imageRepo):latest"
```

ADC handles GCP auth for the Secret Manager lookups during the run.
Expect ~5 minutes for the first run (package downloads dominate).

### 2.4 Tighten the Cloud Firewall

Now that WireGuard is up and the operator can SSH over WG:

```sh
cd ../pulumi
pulumi config set vaultwarden:bootstrapSshCidr ""
pulumi up
```

The public-22 rule disappears. Confirm by trying SSH from a non-WG network:
should hang or refuse. From a WG-connected client, SSH should still work.

### 2.5 Connect a WG peer

On your laptop, create a peer config matching the inventory entry:

```ini
[Interface]
PrivateKey = <your-laptop-private-key>
Address    = 10.42.0.10/32

[Peer]
PublicKey  = <wg-server-pubkey>
Endpoint   = <server-ipv4>:51820
AllowedIPs = 10.42.0.0/24
PersistentKeepalive = 25
```

The server's WG public key isn't stored anywhere — derive it from the
private key in Secret Manager:

```sh
gcloud secrets versions access latest --secret=vaultwarden-wireguard \
  | yq '.wg_server_privkey' -r | wg pubkey
```

### 2.6 Hand off to Cloud Build

Once the disposable stack is verified end-to-end (§3), set up a Cloud Build
trigger so future deploys don't need local Ansible runs:

```sh
gcloud builds triggers create manual \
  --name=vaultwarden-deploy \
  --build-config=cloudbuild.yaml \
  --repo-type=GITHUB \
  --repo=jasonross/vaultwarden_deployment \
  --branch=main \
  --service-account=projects/<PROJECT>/serviceAccounts/vaultwarden-cb@<PROJECT>.iam.gserviceaccount.com \
  --substitutions=_PULUMI_STACK=production,_PULUMI_STATE_BUCKET=gs://<bucket>
```

Manual triggers: `gcloud builds triggers run vaultwarden-deploy --branch=main`.
Or convert to a push trigger if you want every commit to main to deploy.

Bring it up: `sudo wg-quick up <config>`. Test: `ping 10.42.0.1`.

---

## 3. Verification checks

Run all of these on the disposable instance before promoting. Each one is a
real test of an actual guarantee, not a smoke test.

### 3.1 Stack comes up clean from scratch

```sh
cd pulumi   && pulumi destroy && pulumi up
cd ansible  && ansible-playbook -i inventory/disposable.yml playbook.yml
```

Zero hand-patching between phases. If anything required manual intervention,
fix the *code*, then repeat.

### 3.2 TLS + web vault loads

From a browser: `https://vault-disposable.example.com/`. The web vault
should load with a valid Let's Encrypt cert (DNS-01 issued).

### 3.3 WG gate works in both directions

```sh
# From WG-connected client:
curl -sSf https://vault-disposable.example.com/admin    # → 401 (admin enabled) or 200/redirect (disabled but proxied)
ssh ansible@10.42.0.1 'uptime'                          # → succeeds

# From a non-WG IP (e.g. your phone on cellular without WG):
curl -sS  https://vault-disposable.example.com/admin    # → HTTP 404
ssh ansible@<public-ipv4> 'uptime'                      # → connection refused/timeout
```

The non-WG `/admin` *must* be 404, not 401/403. 404 hides the route's
existence from scanners.

### 3.4 Real-IP forwarding wired correctly

```sh
ssh ansible@10.42.0.1
sudo tail -f /data/vaultwarden.log
# In another shell, attempt a bad login from a known client IP.
# The log line should carry your client IP, not Caddy's container IP.
```

If the log shows a 10.89.x.x or similar bridge IP, fail2ban will ban Caddy
on the first 5 wrong passwords. Stop and fix the Caddyfile X-Forwarded-For
wiring before continuing.

### 3.5 Backup → restore round trip

```sh
ssh ansible@10.42.0.1
sudo systemctl start vaultwarden-backup.service
sudo journalctl -u vaultwarden-backup.service --since "5 min ago"
sudo -u vaultwarden bash -c 'set -a; . /etc/vaultwarden/restic.env; set +a; restic snapshots'
```

Then run the full restore drill on a scratch host — see
`runbook/restore-drill.md`.

### 3.6 Alerting actually fires

This is the most important verification — alert pipelines that "look" wired
fail silently:

```sh
# Email path: stop vaultwarden manually.
sudo systemctl --user -M vaultwarden@ stop vaultwarden.service
# Wait. Check inbox for "[host] unit failed: vaultwarden.service" email.
sudo systemctl --user -M vaultwarden@ start vaultwarden.service

# Healthchecks path: mask the backup timer for one cycle.
sudo systemctl mask vaultwarden-backup.timer
# Wait past the expected fire time. Healthchecks.io should alert.
sudo systemctl unmask vaultwarden-backup.timer
```

Both pipelines must fire on a deliberate break. A check that doesn't is
worth more dead than alive.

### 3.7 Encryption-boundary canary

The LastPass closure. Self-hosting gives you the database access hosted
Bitwarden never did — use it:

1. In the web vault, create a login. In its **notes field**, paste:
   `CANARY_NOTES_FIELD_PLAINTEXT`. Sync.
2. On the server:
   ```sh
   ssh ansible@10.42.0.1
   sudo grep -c CANARY_NOTES_FIELD_PLAINTEXT /data/db.sqlite3
   # Expected: 0
   sudo sqlite3 /data/db.sqlite3 'SELECT data FROM ciphers LIMIT 1' | head -c 200
   # Expected: opaque encrypted blob, nothing human-readable.
   ```
3. Delete the canary login.

Non-zero grep = a LastPass-class problem. Zero = uniform client-side
envelope confirmed by reading your own disk.

### 3.8 Survives an auto-update + reboot cycle

```sh
ssh ansible@10.42.0.1
sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 systemctl --user start podman-auto-update.service
sudo reboot
# Wait for the host to come back. Confirm:
sudo systemctl --user -M vaultwarden@ status vaultwarden.service caddy.service
curl -sSf https://vault-disposable.example.com/
```

Both containers must come back up clean. Quadlet-survives-restart is the
failure most likely to bite a week post-cutover; catch it here.

### 3.9 Coraza is logging, not blocking

```sh
# Upload a small attachment to a test login. It must succeed.
# Then check the audit log:
ssh ansible@10.42.0.1
sudo tail /var/lib/vaultwarden/caddy/logs/coraza-audit.log
# Expect JSON lines flagging the upload (encrypted payload looks like attack
# traffic to CRS) but the response code is what Caddy + Vaultwarden produced,
# not 403.
```

---

## 4. Production deploy

Identical to §2 with `disposable` → `production` everywhere:

```sh
cd pulumi   && pulumi stack init production
cd ansible  && cp inventory/production.yml.example inventory/production.yml
```

Stack config differs only in `hostname`, `dnsRecordName`. Run the same
verification suite from §3.

---

## 5. Migration cutover from hosted Bitwarden

Two-week dual-run window.

### 5.1 Frozen export (the real rollback floor)

In hosted Bitwarden's web vault: **Tools → Export Vault → encrypted JSON**.
File-protected with a strong password. Date it, store offline.

This is the actual rollback artifact — *not* "hosted Bitwarden still has
it". Once clients repoint, hosted Bitwarden goes stale from day 0.

### 5.2 Import to Vaultwarden

In the new web vault: **Tools → Import Data → Bitwarden (json)**.

### 5.3 Re-upload attachments manually

Attachments are Premium-gated and not in the export. Audit Secure Notes
specifically — that's where attachments most often hide.

### 5.4 Repoint clients

Browser extension, mobile app, desktop: settings → server URL →
`https://vault.example.com`. Log in fresh. Verify autofill works.

### 5.5 Two-week window

The pass/fail checklist from the plan:

- [ ] Web vault loads and unlocks
- [ ] Browser extension autofills **and saves a new login**
- [ ] Mobile autofill works
- [ ] Attachment upload + download round-trips (Coraza canary)
- [ ] Send creates and retrieves (second canary)
- [ ] TOTP generates
- [ ] Cross-device sync propagates phone→desktop in reasonable time
- [ ] Stack survives an auto-update / reboot cycle (force one during the window)
- [ ] Healthchecks fires on a deliberately broken backup run

All hold for two weeks **including one update cycle** → cut over.
Any fail and unfixable inside the box → abandon, the day-0 export restores you.

### 5.6 Disposition

- **Transient breakage** during the window (crash, wedged update, Caddy
  misconfig): do *not* fall back. Clients hold the vault cached and serve
  reads through the outage. Wait, fix; the cache carries you.
- **Total abandonment**: fall back to hosted Bitwarden, restore from the
  day-0 export.

After cutover succeeds: shred the day-0 export password (the file is now
stale and dangerous to keep around with a forgotten password).

---

## 6. Day-to-day operations

### Status at a glance

```sh
ssh ansible@10.42.0.1

# Quadlets (rootless):
sudo machinectl shell vaultwarden@
systemctl --user list-units 'vaultwarden*' 'caddy*'
systemctl --user list-timers

# System units:
sudo systemctl list-timers
sudo systemctl status vaultwarden-backup.timer restic-check.timer
```

### Tail logs

```sh
# Vaultwarden:
sudo tail -f /data/vaultwarden.log
sudo -u vaultwarden journalctl --user -u vaultwarden.service -f

# Caddy access log:
sudo tail -f /var/lib/vaultwarden/caddy/logs/access.log | jq -c '{ts:.ts,status:.status,path:.request.uri,ip:.request.client_ip}'

# Coraza audit:
sudo tail -f /var/lib/vaultwarden/caddy/logs/coraza-audit.log | jq

# fail2ban:
sudo fail2ban-client status vaultwarden
sudo journalctl -u fail2ban -f
```

### Manually run a backup

```sh
sudo systemctl start vaultwarden-backup.service
sudo journalctl -u vaultwarden-backup.service --since "10 min ago"
```

### List restic snapshots

```sh
sudo -u vaultwarden bash -c '
  set -a; . /etc/vaultwarden/restic.env; set +a
  restic snapshots
'
```

### Enabling `/admin` after the fact

1. Generate an Argon2id hash (§1 prereqs).
2. Update the `vaultwarden-vaultwarden` secret in Secret Manager — add a
   new version with `admin_token_argon2` set to the Argon2 hash.
3. `ansible-playbook -i inventory/<stack>.yml playbook.yml --tags secrets,quadlets`.

The Caddy WG gate already passes `/admin` through — the only change is
Vaultwarden no longer rejecting all admin requests.

---

## 7. Update flow

Two independent automated update channels. Both are needed; neither is
optional.

### OS — `dnf-automatic`

- Schedule: every `dnf_reboot_dow` at `dnf_reboot_window` (default Tue 04:00),
  via a systemd timer drop-in.
- Scope: security-only.
- Reboots only when a package requires it (`reboot = when-needed`).
- Watch: `journalctl -u dnf-automatic-install.service`; Healthchecks ping
  named `dnf-automatic` should fire on each successful run.

### Containers — `podman auto-update`

- Schedule: default daily (rootless user timer).
- Scope: containers with `AutoUpdate=registry` (both quadlets here).
- Behavior: pulls the `:latest` tag for each watched image, restarts the
  container if the digest changed.
- Watch: `journalctl --user -u podman-auto-update.service` (as vaultwarden);
  Healthchecks ping named `podman-auto-update` should fire on each run.

### Bumping a pinned version

- **Caddy core / Coraza / googleclouddns**: edit
  `caddy/versions.env`, push — Cloud Build rebuilds + scans + republishes.
  Auto-update picks
  up the new `:latest` on next tick. Roll back by re-tagging an earlier
  `<sha>` as `:latest` in Artifact Registry.
- **Vaultwarden image**: it's `docker.io/vaultwarden/server:latest` — pinning
  to a tag isn't done; auto-update tracks `:latest`. If you want to pin,
  change `Image=` to a SHA-tagged version and drop `AutoUpdate=registry`.

---

## 8. Rollback

### Caddy image rolls back broken

```sh
gh auth login        # if needed
# Find the previous SHA:
gh api /users/<owner>/packages/container/vaultwarden-caddy/versions
# Re-tag a known-good <sha> as :latest in AR, e.g.:
# gcloud artifacts docker tags add \
#   <region>-docker.pkg.dev/<project>/<repo>/vaultwarden-caddy:<good-sha> \
#   <region>-docker.pkg.dev/<project>/<repo>/vaultwarden-caddy:latest
ssh ansible@10.42.0.1
sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 podman auto-update --rollback
```

### Bad Ansible change

```sh
git revert <commit>
ansible-playbook -i inventory/<stack>.yml playbook.yml
```

### Bad Pulumi change

```sh
git revert <commit>
pulumi -s <stack> up
```

### Catastrophic loss — restore from R2

See `runbook/restore-drill.md` — same procedure, against the production
host instead of a scratch one.

### Inside the cutover window

If you're in the §5 two-week window and decide to abandon:

```sh
# Repoint clients back to https://vault.bitwarden.com
# Restore from the day-0 export in hosted Bitwarden's import UI.
# Tear down:
cd pulumi && pulumi -s production destroy
```

---

## 9. Troubleshooting

### Web vault won't load — TLS error

- Caddy DNS-01 needs GCP Cloud DNS reachable. Check:
  `sudo -u vaultwarden journalctl --user -u caddy.service | grep -i dns`
- SA JSON key may have expired or lost dns.admin. Verify in GCP console.
- The `gcp-sa-dns` Podman secret may be stale: re-run
  `ansible-playbook --tags secrets`.

### Web vault loads but sync fails

- Vaultwarden may be returning 5xx. Check
  `sudo -u vaultwarden journalctl --user -u vaultwarden.service`.
- Disk full on `/data`: `df -h /data`. Most often the Coraza audit log —
  rotate it (see §10).

### Coraza audit log balloons

Coraza doesn't roll `SecAuditLog` itself. A one-shot logrotate config:

```
/var/lib/vaultwarden/caddy/logs/coraza-audit.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
```

Drop in `/etc/logrotate.d/coraza-audit` and confirm with `logrotate -d`.

### fail2ban banned the Caddy container IP

Real-IP forwarding broke. Verify Vaultwarden env still has
`IP_HEADER=X-Forwarded-For` and the Caddyfile still injects
`X-Forwarded-For {remote_host}`. Unban with
`sudo fail2ban-client unban <ip>`.

### Healthchecks paged but nothing's wrong

Most often: clock skew on the host. `timedatectl` should show
`Synchronized: yes` and a sane NTP source.

### SELinux denial on a quadlet

```sh
sudo ausearch -m avc -ts recent
sudo audit2why -a < <(sudo ausearch -m avc -ts recent)
```

Read the suggested policy *before* loading it with `audit2allow -M`.
Blindly loading `audit2allow` output is how you punch holes in enforcing
mode.

### A container won't restart after auto-update

```sh
sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 podman auto-update --rollback
```

Then investigate why — usually a broken `:latest` push or a config
incompatibility with a new upstream version.

---

## 10. Where things live

| Path / unit                                            | What |
|--------------------------------------------------------|------|
| `/data`                                                | Vaultwarden DB, attachments, sends, log (bind-mounted from `/mnt/HC_Volume_<id>`) |
| `/data/vaultwarden.log`                                | Vaultwarden's log file (fail2ban tails it) |
| `/data/db.sqlite3`                                     | The live DB |
| `/data/db-backup.sqlite3`                              | Latest consistent snapshot (overwritten daily) |
| `/etc/vaultwarden/restic.env`                          | restic creds (0640 root:vaultwarden) |
| `/etc/vaultwarden/healthchecks.env`                    | HC ping URLs |
| `/etc/wireguard/wg0.conf`                              | WG server config |
| `/etc/nftables/main.nft`                               | Host firewall ruleset |
| `/etc/fail2ban/jail.local`                             | fail2ban jails |
| `/etc/msmtprc`                                         | system msmtp config |
| `/etc/aliases`                                         | root → operator |
| `/usr/local/sbin/vaultwarden-backup`                   | backup driver script |
| `/usr/local/sbin/systemd-email`                        | OnFailure email helper |
| `/var/lib/vaultwarden/`                                | rootless user home |
| `/var/lib/vaultwarden/.config/containers/systemd/`     | quadlets |
| `/var/lib/vaultwarden/.config/systemd/user/`           | user systemd drop-ins |
| `/var/lib/vaultwarden/caddy/Caddyfile`                 | Caddy config |
| `/var/lib/vaultwarden/caddy/data/`                     | Caddy state (certs, OCSP) |
| `/var/lib/vaultwarden/caddy/logs/`                     | Caddy access + Coraza audit |
| `vaultwarden-backup.timer`                             | system timer, daily 02:30 |
| `restic-check.timer`                                   | system timer, Sun 03:30 |
| `restore-drill-reminder.timer`                         | system timer, Jan/Apr/Jul/Oct 1st |
| `dnf-automatic-install.timer`                          | OS security updates |
| `podman-auto-update.timer` (user)                      | container updates (rootless) |
