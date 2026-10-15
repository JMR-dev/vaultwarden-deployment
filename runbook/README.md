# Vaultwarden deployment runbook

Operator-facing guide. The design reasoning lives in the code comments
(`platform/main.go`, `pulumi/main.go`, `scripts/*.sh`) and in the plan at
`~/.claude/plans/finish-deploying-this-vaultwarden-velvety-cerf.md` — this
file is the *how*, not the *why*.

Shape of the system, in one paragraph: one AlmaLinux 10 GCE VM per stack
(`vault-disposable`, `vault-production`) in `vaultwarden-497422`, us-east1-b.
Two Pulumi projects: `platform/` (owner-run: network, static IPs, DNS, R2
buckets, Artifact Registry, every IAM grant) and `pulumi/` (CI-run: the VM,
its data disk, snapshots). Gitea Actions deploys with a deployer SA key —
Gitea 1.27 can't mint Actions OIDC tokens — and that SA can rebuild the VM
but can't grant IAM. Ansible configures the host over IAP + OS Login; there
is no public SSH and no WireGuard.

Steps marked ⚠ change real resources. Read the preview/diff before applying.

## Table of contents

1. [Prerequisites](#1-prerequisites)
2. [First-time bootstrap](#2-first-time-bootstrap)
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

- **Tools** (operator machine): `gcloud`, `pulumi` (≥ the SDK in `go.mod`;
  CI pins v3.266.0), `go` (1.26.x), `ansible-core` 2.20, `jq`, `ssh`,
  `curl`, `podman` (local Caddy builds, restore drill), `restic` (restore
  drill).
- **GCP** — project `vaultwarden-497422`, already holding:
  - Cloud DNS zone `vault` = `vault.jasonmross.dev.` (gcloud-made,
    delegated from `jasonmross.dev`; deliberately not Pulumi-owned).
  - App state bucket `gs://vaultwarden-497422-pulumi-state`.
  - `vaultwarden-caddy-dns@` SA, whose JSON key Caddy uses for DNS-01
    (stored in the `vaultwarden-vaultwarden` secret as `gcp_sa_dns_json`).
  - `gcloud auth login` **and** `gcloud auth application-default login`
    as the project owner — Pulumi's GCS backend and KMS provider use ADC.
- **Cloudflare**: the account that will own the R2 buckets (note its account
  id), and an API token with **Workers R2 Storage: Edit** for Pulumi. It goes
  into the `vaultwarden-cloudflare-api-token` secret (§2.2); the deployer
  never sees it.
- **Healthchecks.io**: four checks **per stack** (eight total) — backup
  (daily), restic check (weekly, Sun), dnf-automatic (weekly, Tue), podman
  auto-update (daily). Per stack so the disposable box can't keep
  production's checks green.
- **SMTP**: outbound credentials on port **587** (GCE blocks 25) for msmtp.
- **Gitea**: write access to `JMR-dev/vaultwarden-deployment` and a token
  with repo write scope (for `scripts/rotate-deployer-key.sh`).

### Vaultwarden admin token (optional)

Skip this if you're keeping `/admin` disabled (the default). To enable:

```sh
podman run --rm -it docker.io/vaultwarden/server /vaultwarden hash
# Enter a strong password. Add the $argon2id$... hash to the
# vaultwarden-vaultwarden secret as admin_token_argon2.
```

---

## 2. First-time bootstrap

The point of the disposable stack is to flush out platform surprises on a VM
you don't mind destroying. Iterate destroy → redeploy until the stack stands
up with zero hand-intervention, then promote to production.

Order matters: each step needs the previous one's resources.

### 2.1 ⚠ GCP bootstrap (once)

```sh
scripts/bootstrap-gcp.sh            # defaults: vaultwarden-497422 us-east1
```

Idempotent. Enables the APIs, creates the KMS key
`pulumi/stacks` (both Pulumi projects' secrets provider), the owner-only
platform state bucket `gs://vaultwarden-497422-platform-state`, and an
**empty** container for every secret in `secrets/secret-names.txt`.

### 2.2 Secret values you can add now

Schemas and `gcloud secrets versions add` commands are in
`secrets/README.md`. Before the platform stack:

- `vaultwarden-cloudflare-api-token` — the R2-edit token from §1.

Before the first deploy (can be done in parallel with §2.3):

- `vaultwarden-vaultwarden` — already has a version; confirm with
  `gcloud secrets versions list vaultwarden-vaultwarden`.
- `vaultwarden-msmtp`
- `vaultwarden-disposable-healthchecks`, `vaultwarden-production-healthchecks`

The restic secrets need the R2 buckets first (§2.4).

### 2.3 ⚠ Platform stack

```sh
cd platform
pulumi login gs://vaultwarden-497422-platform-state
pulumi stack init prod \
  --secrets-provider gcpkms://projects/vaultwarden-497422/locations/global/keyRings/pulumi/cryptoKeys/stacks
pulumi config set --secret vaultwarden-platform:cloudflareAccountId <account-id>

export CLOUDFLARE_API_TOKEN=$(gcloud secrets versions access latest \
  --secret=vaultwarden-cloudflare-api-token --project vaultwarden-497422)
pulumi preview --diff
pulumi up
unset CLOUDFLARE_API_TOKEN
```

Commit the `secretsprovider`/`encryptedkey`/encrypted-account-id lines that
`stack init` and `config set` added to `platform/Pulumi.prod.yaml`.

Creates: VPC `vaultwarden` + dual-stack subnet, firewall (443 public, ICMP,
22 from IAP `35.235.240.0/20` only), per-stack static IPv4/IPv6 and A/AAAA
records, per-stack R2 buckets `vaultwarden-backups-<stack>` (protected),
AR repo `vaultwarden`, the `vaultwarden-deployer@` SA and every grant.
`pulumi stack output` shows the bucket names and `caddyImage`.

### 2.4 R2 tokens and restic secrets

In the Cloudflare dashboard: **R2 → Manage R2 API Tokens → Create token**,
permission **Object Read & Write**, scoped to **one** bucket. Do it twice,
once per bucket, so a compromised disposable host can't touch production's
backups. Each yields an Access Key ID and Secret Access Key.

Then add `vaultwarden-<stack>-restic` (schema in `secrets/README.md`):

```yaml
restic_repository: s3:https://<account-id>.r2.cloudflarestorage.com/vaultwarden-backups-<stack>
restic_password: <openssl rand -base64 48>
r2_access_key_id: <from the token for this bucket>
r2_secret_access_key: <from the token for this bucket>
```

Store the production `restic_password` somewhere offline too. Without it
the backups are noise.

### 2.5 ⚠ Deployer key → Gitea secret

```sh
scripts/rotate-deployer-key.sh      # prompts for the Gitea token
```

Creates a JSON key for `vaultwarden-deployer@`, PUTs it to the repo's
Actions secret `GCP_DEPLOYER_KEY`, deletes any older user-managed keys, and
shreds the local copies. The same script is the 90-day rotation (§6).

### 2.6 ⚠ App stacks

```sh
cd pulumi
go build -o bin/vaultwarden .       # Pulumi.yaml runs this binary
# Explicit login: the local CLI is often still pointed at gitea's bucket.
pulumi login gs://vaultwarden-497422-pulumi-state
pulumi stack init disposable \
  --secrets-provider gcpkms://projects/vaultwarden-497422/locations/global/keyRings/pulumi/cryptoKeys/stacks
pulumi stack init production \
  --secrets-provider gcpkms://projects/vaultwarden-497422/locations/global/keyRings/pulumi/cryptoKeys/stacks
```

Commit the `secretsprovider`/`encryptedkey` lines added to
`Pulumi.disposable.yaml` and `Pulumi.production.yaml` and push. CI can't
select a stack whose config file lacks them.

### 2.7 Confirm branch protection on `main`

`deploy.yml` refuses a production deploy from any ref but `main`, and a push
to `main` deploys disposable — so `main` must be protected **on Gitea**.
`repo_config_settings` only ever configured the old GitHub repo. Check
**Settings → Branches** in the Gitea UI (or
`GET /api/v1/repos/JMR-dev/vaultwarden-deployment/branch_protections`) and
add a rule for `main` if there is none.

### 2.8 ⚠ First deploy (disposable)

Gitea only offers **Run workflow** for workflows that exist on the default
branch, so the first deploy comes from merging to `main`. Do it only after
§2.1–§2.7 are done, or the push run fails at `image` for want of the key.

1. Merge the branch carrying `.gitea/workflows/deploy.yml` into `main`. The
   push itself deploys disposable with `signups=false`.
2. Then Gitea → **Actions → deploy → Run workflow**: branch `main`,
   `stack=disposable`, `signups=true` — that run opens registration.

After that, any branch can be dispatched against disposable (production
still only from `main`).

The run is `guard → image → infra → configure`:

- **image** builds the Caddy image, Trivy-scans it, pushes `caddy:<sha>`
  and moves the floating `caddy:disposable` tag.
- **infra** previews and applies `pulumi up` (the first run creates the VM
  and disk).
- **configure** runs `scripts/ansible-iap.sh disposable`.

Expect ~10–15 minutes on a fresh VM.

Then:

1. Open `https://disposable.vault.jasonmross.dev` and create the test
   account.
2. Re-run the workflow with `signups=false` (any push to `main` also
   redeploys disposable with signups off).
3. Confirm a second registration attempt is refused.

`/admin` is disabled by default, so the `signups` deploy is the only way to
create the first account on a fresh stack.

---

## 3. Verification checks

Run all of these on the disposable stack before promoting. Each one is a
real test of an actual guarantee, not a smoke test.

`gcloud compute ssh` below always means
`gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap`.

### 3.1 Stack comes up clean from scratch

```sh
cd pulumi && go build -o bin/vaultwarden .
pulumi login gs://vaultwarden-497422-pulumi-state
pulumi destroy -s disposable
# then: Actions → deploy → Run workflow, stack=disposable (signups=true, then false)
```

Zero hand-patching between phases. If anything needed manual intervention,
fix the *code*, then repeat. Every rebuild issues a new Let's Encrypt
certificate (Caddy's ACME state lives on the boot disk). LE allows five per
week for the same name, so don't loop this more than ~3 times a week.

### 3.2 TLS + web vault loads, over both address families

```sh
curl -4 -sSf -o /dev/null -w '%{http_code}\n' https://disposable.vault.jasonmross.dev/
curl -6 -sSf -o /dev/null -w '%{http_code}\n' https://disposable.vault.jasonmross.dev/
```

Both 200 with a valid Let's Encrypt certificate (DNS-01 issued). A browser
should load the web vault.

If `-4` works and `-6` doesn't (the AAAA record is published, so IPv6
clients will try it first), check where the host listens:
`sudo ss -ltnp 'sport = :443'`. With no `[::]:443` listener, rootless
port forwarding is binding IPv4 only. Fix it in `quadlets/caddy.container.j2`
by publishing both families explicitly (`PublishPort=0.0.0.0:443:443` and
`PublishPort=[::]:443:443`), or, as a stopgap, drop the AAAA record in
`platform/main.go`. If `[::]:443` is listening but still unreachable, check the
`vaultwarden-allow-https-v6` VPC rule and that the VM got its IPv6
(`ip -6 addr show scope global`; DHCPv6 is admitted by nftables).

### 3.3 The IAP gate works in both directions

```sh
# Public SSH is closed (VPC firewall + nftables):
nc -vz -w 5 "$(cd platform && pulumi stack output stacks --json | jq -r .disposable.ipv4)" 22
# → timeout/refused
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap --command uptime
# → succeeds

# /admin is hidden publicly...
curl -sS -o /dev/null -w '%{http_code}\n' https://disposable.vault.jasonmross.dev/admin
# → 404
# ...and reachable only through an IAP tunnel to :443:
gcloud compute start-iap-tunnel vault-disposable 443 \
  --local-host-port=localhost:8443 --zone us-east1-b &
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve disposable.vault.jasonmross.dev:8443:127.0.0.1 \
  https://disposable.vault.jasonmross.dev:8443/admin
# → 200 (admin enabled: login page) — anything but 404
kill %1
```

The public `/admin` *must* be 404, not 401/403. 404 hides the route from
scanners. The tunnel case reaches Caddy from `35.235.240.0/20`, the only
range `ADMIN_CIDRS` admits.

### 3.4 Real-IP forwarding wired correctly

```sh
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap
sudo tail -f /data/vaultwarden.log
# From your laptop (no tunnel), attempt a bad login on the web vault.
# The log line must carry your public IP, not a 10.x / 169.254.x address.
```

If the log shows an internal address, rootless podman's bridge port-forward
is hiding client IPs. Two consequences: fail2ban can't ban anyone, and
`/admin` stays 404 even through the IAP tunnel (it fails closed). Stop and
fix before continuing. The fix:

- Run Caddy with `Network=host` (`quadlets/caddy.container.j2`; drop its
  `Sysctl=` line, which podman rejects under host networking).
- Publish Vaultwarden on `PublishPort=127.0.0.1:8080:8080` and point the
  Caddyfile `reverse_proxy` at `127.0.0.1:8080`.
- Lower the host sysctl to `net.ipv4.ip_unprivileged_port_start=80` (podman
  role), so rootless Caddy can bind :80 for its redirects.

### 3.5 fail2ban bans actually drop traffic, and survive a ruleset load

```sh
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap
sudo fail2ban-client set vaultwarden banip <an IP you control, not IAP>
# From that IP: curl https://disposable.vault.jasonmross.dev/ → hangs/refused
sudo nft list ruleset | grep -c f2b          # note the count
sudo nft -f /etc/nftables/main.nft           # what every Ansible run does
sudo nft list ruleset | grep -c f2b          # same count: bans survived
sudo fail2ban-client set vaultwarden unbanip <ip>
```

The status output lies in both directions; only the drill proves it.
`/etc/nftables/main.nft` replaces only `table inet vaultwarden_filter`.
`systemctl restart|reload nftables` would flush fail2ban's tables
(see §9).

### 3.6 Backup → restore round trip

```sh
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap
sudo systemctl start vaultwarden-backup.service
sudo journalctl -u vaultwarden-backup.service --since "5 min ago"
sudo -u vaultwarden bash -c 'set -a; . /etc/vaultwarden/restic.env; set +a; restic snapshots'
```

Then run the full restore drill — see `runbook/restore-drill.md`.

### 3.7 Alerting actually fires

This is the most important verification — alert pipelines that "look" wired
fail silently:

```sh
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap

# Email path, end to end (msmtp → your inbox):
sudo systemctl start status-email-root@drill-test.service
# Check inbox for "[vault-disposable] unit failed: drill-test".

# A real failure: make the backup fail once. (Move the env file; a chmod
# wouldn't do it — systemd reads EnvironmentFile= as root.)
sudo mv /etc/vaultwarden/restic.env /etc/vaultwarden/restic.env.drill
sudo systemctl start vaultwarden-backup.service   # fails
sudo mv /etc/vaultwarden/restic.env.drill /etc/vaultwarden/restic.env
# Expect the OnFailure email, and no Healthchecks success ping.

# Container-down path: the rootless units can't use OnFailure=, so the
# system timer vaultwarden-container-watch polls every 2 min and mails after
# two consecutive misses (~4 min), then again on recovery.
sudo systemctl --user -M vaultwarden@ stop vaultwarden.service
# Wait ~5 min. Expect "[vault-disposable] container down: vaultwarden.service".
sudo systemctl --user -M vaultwarden@ start vaultwarden.service
# Expect "recovered: vaultwarden.service" within ~2 min.

# Healthchecks path: mask the backup timer for one cycle.
sudo systemctl mask vaultwarden-backup.timer
# Wait past the expected fire time + grace. Healthchecks.io should alert.
sudo systemctl unmask vaultwarden-backup.timer
```

Both pipelines must fire on a deliberate break. A check that doesn't is
worth more dead than alive.

### 3.8 Encryption-boundary canary

The LastPass closure. Self-hosting gives you the database access hosted
Bitwarden never did — use it:

1. In the web vault, create a login. In its **notes field**, paste:
   `CANARY_NOTES_FIELD_PLAINTEXT`. Sync.
2. On the server:
   ```sh
   gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap
   sudo grep -c CANARY_NOTES_FIELD_PLAINTEXT /data/db.sqlite3
   # Expected: 0
   sudo sqlite3 /data/db.sqlite3 'SELECT data FROM ciphers LIMIT 1' | head -c 200
   # Expected: opaque encrypted blob, nothing human-readable.
   ```
3. Delete the canary login.

Non-zero grep = a LastPass-class problem. Zero = uniform client-side
envelope confirmed by reading your own disk.

### 3.9 Survives an auto-update + reboot cycle

```sh
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap
sudo systemctl --user -M vaultwarden@ start podman-auto-update.service
sudo reboot
# Reconnect once it's back:
findmnt /data                     # the GCE data disk, ext4
swapon --show                     # /swapfile
ip -6 addr show scope global      # IPv6 came back via DHCPv6
sudo systemctl --user -M vaultwarden@ status vaultwarden.service caddy.service
curl -4 -sSf https://disposable.vault.jasonmross.dev/ >/dev/null && \
curl -6 -sSf https://disposable.vault.jasonmross.dev/ >/dev/null && echo ok
```

Then prove the empty-`/data` guard (disposable only):

```sh
sudo systemctl --user -M vaultwarden@ stop vaultwarden.service
sudo systemctl stop fail2ban                                      # it holds /data/vaultwarden.log open
sudo umount /data
sudo systemctl --user -M vaultwarden@ start vaultwarden.service   # must FAIL (ExecStartPre mountpoint)
sudo mount /data
sudo systemctl start fail2ban
sudo systemctl --user -M vaultwarden@ start vaultwarden.service   # back up
```

Quadlet-survives-restart is the failure most likely to bite a week
post-cutover; catch it here.

### 3.10 Coraza is logging, not blocking

```sh
# Upload a small attachment to a test login. It must succeed.
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap
sudo tail /var/lib/vaultwarden/caddy/logs/coraza-audit.log
# Expect JSON lines flagging the upload (encrypted payload looks like attack
# traffic to CRS) but the response code is what Caddy + Vaultwarden produced,
# not 403.
```

### 3.11 The CI guard rails hold

- **Production only from main.** Run the deploy workflow from a feature
  branch with `stack=production`. The `guard` job must fail.
- **Replace guard.** On a throwaway branch, change `BootImage` in
  `pulumi/main.go`, dispatch `stack=disposable` with `allow_replace=false`.
  The `infra` job must fail listing the instance replacement. Delete the
  branch.
- **The deployer key can't escalate.** List everything it holds:
  ```sh
  gcloud projects get-iam-policy vaultwarden-497422 --flatten=bindings[].members \
    --filter='bindings.members:vaultwarden-deployer@' --format='value(bindings.role)'
  # → exactly compute.instanceAdmin.v1, compute.osAdminLogin, iap.tunnelResourceAccessor
  gcloud secrets get-iam-policy vaultwarden-cloudflare-api-token --format=json \
    | jq -r '.bindings[]?.members[]' | grep -c deployer
  # → 0
  ```
  `platform/main_test.go` enforces the same allow-list on every CI run.

---

## 4. Production deploy

The production stack config is already committed (`Pulumi.production.yaml`
has `deleteProtection: "true"`: the data disk is Pulumi-protected and the
instance refuses API deletion). Prerequisites from §2 that are per stack:
`vaultwarden-production-restic`, `vaultwarden-production-healthchecks`,
`pulumi stack init production`.

1. ⚠ Gitea → **Actions → deploy → Run workflow** from **main**,
   `stack=production`, `signups=true`. The image job promotes the
   already-scanned `caddy:<sha>` (if disposable built it) by moving the
   `caddy:production` tag.
2. Create your real account at `https://vault.jasonmross.dev`.
3. ⚠ Re-run with `signups=false`. Confirm registration is refused.
4. Run the production-safe subset of §3: 3.2, 3.3, 3.4, 3.6 (backup run;
   the restore drill uses production's repo), 3.7 (email + Healthchecks),
   3.11 deployer listing. Skip the destructive ones (3.1, the 3.9 umount).

---

## 5. Migration cutover from hosted Bitwarden

Two-week dual-run window.

### 5.1 Frozen export (the real rollback floor)

In hosted Bitwarden's web vault: **Tools → Export Vault → encrypted JSON**.
File-protected with a strong password. Date it, store offline.

This is the actual rollback artifact — *not* "hosted Bitwarden still has
it". Once clients repoint, hosted Bitwarden goes stale from day 0.

### 5.2 Import to Vaultwarden

In `https://vault.jasonmross.dev`: **Tools → Import Data → Bitwarden (json)**.

### 5.3 Re-upload attachments manually

Attachments are Premium-gated and not in the export. Audit Secure Notes
specifically — that's where attachments most often hide.

### 5.4 Repoint clients

Browser extension, mobile app, desktop: settings → server URL →
`https://vault.jasonmross.dev`. Log in fresh. Verify autofill works.

### 5.5 Two-week window

The pass/fail checklist:

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
  day-0 export (§8, "Inside the cutover window").

After cutover succeeds: shred the day-0 export password (the file is now
stale and dangerous to keep around with a forgotten password).

---

## 6. Day-to-day operations

### Getting a shell

```sh
gcloud compute ssh vault-<stack> --zone us-east1-b --tunnel-through-iap
```

IAM decides who gets in (OS Login + IAP). There are no SSH keys to manage.
The project owner is an OS Login admin (passwordless sudo).

### Status at a glance

```sh
# Quadlets (rootless):
sudo systemctl --user -M vaultwarden@ list-units 'vaultwarden*' 'caddy*'
sudo systemctl --user -M vaultwarden@ list-timers

# System units:
sudo systemctl list-timers
sudo systemctl status vaultwarden-backup.timer restic-check.timer dnf-automatic-install.timer
```

### Tail logs

```sh
# Vaultwarden:
sudo tail -f /data/vaultwarden.log
sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 journalctl --user -u vaultwarden.service -f

# Caddy access log:
sudo tail -f /var/lib/vaultwarden/caddy/logs/access.log | jq -c '{ts:.ts,status:.status,path:.request.uri,ip:.request.client_ip}'

# Coraza audit:
sudo tail -f /var/lib/vaultwarden/caddy/logs/coraza-audit.log | jq

# fail2ban:
sudo fail2ban-client status vaultwarden
sudo journalctl -u fail2ban -f

# Host firewall drops (sampled):
sudo journalctl -k -g nft-drop -f
```

### Manually run a backup / list snapshots

```sh
sudo systemctl start vaultwarden-backup.service
sudo journalctl -u vaultwarden-backup.service --since "10 min ago"

sudo -u vaultwarden bash -c '
  set -a; . /etc/vaultwarden/restic.env; set +a
  restic snapshots
'
```

Daily GCE snapshots of the data disk (`vault-<stack>-daily-snapshots`, 03:00
UTC, 7-day retention) sit underneath restic as a crash-consistent second
copy: `gcloud compute snapshots list --filter='labels.stack=<stack>'`.

### Running Ansible by hand

```sh
scripts/ansible-iap.sh <stack> \
  -e caddy_image=us-east1-docker.pkg.dev/vaultwarden-497422/vaultwarden/caddy:<stack> \
  [--tags ...] [--check --diff]
```

Same script CI uses: ephemeral OS Login key (1h TTL, removed on exit), host
keys pinned from guest attributes, SSH via an IAP tunnel. Never run
`ansible-playbook` directly — there's no default inventory on purpose.

### Enabling `/admin` after the fact

1. Generate an Argon2id hash (§1).
2. Add a new version of `vaultwarden-vaultwarden` with `admin_token_argon2`
   set (keep `gcp_sa_dns_json` unchanged).
3. ⚠ `scripts/ansible-iap.sh <stack> --tags secrets,quadlets -e caddy_image=…:<stack>`
   (or just dispatch a deploy). The secrets role replaces a Podman secret
   only when its value changed, and then restarts both containers, which
   read secrets at start.
4. Reach it through the IAP tunnel (§3.3).

### Key rotation (every 90 days)

Two long-lived keys exist. Rotate both on the same calendar reminder:

- **CI deployer key**: ⚠ `scripts/rotate-deployer-key.sh`. A deploy in
  flight during rotation may fail; re-run it.
- **Caddy DNS-01 key** (`vaultwarden-caddy-dns@`):
  ```sh
  gcloud iam service-accounts keys create /tmp/dns.json \
    --iam-account vaultwarden-caddy-dns@vaultwarden-497422.iam.gserviceaccount.com
  # New version of vaultwarden-vaultwarden with gcp_sa_dns_json = /tmp/dns.json
  # contents (admin_token_argon2 unchanged); shred -u /tmp/dns.json.
  scripts/ansible-iap.sh <stack> --tags secrets,quadlets -e caddy_image=…:<stack>   # each active stack (restarts the containers)
  # Confirm a renewal path works (caddy logs, no DNS errors), then delete the old key:
  gcloud iam service-accounts keys list --iam-account vaultwarden-caddy-dns@vaultwarden-497422.iam.gserviceaccount.com --managed-by user
  gcloud iam service-accounts keys delete <old-key-id> --iam-account vaultwarden-caddy-dns@vaultwarden-497422.iam.gserviceaccount.com
  ```

### Retiring the disposable stack

Once production is live, either keep disposable as staging (~$20/mo) or
retire it:

1. ⚠ `cd pulumi && go build -o bin/vaultwarden . && pulumi login gs://vaultwarden-497422-pulumi-state && pulumi destroy -s disposable`
2. ⚠ In `platform/Pulumi.prod.yaml` set `active: false` for disposable,
   then `pulumi up` in `platform/` (with `CLOUDFLARE_API_TOKEN` as in
   §2.3). That releases its static IPs (idle ones bill) and DNS records and
   drops its secret grants. The R2 bucket is kept (protected).
3. Remove the `push:` trigger from `.gitea/workflows/deploy.yml` so every
   deploy is a deliberate dispatch. Otherwise every push to `main` fails
   at the address lookup.

---

## 7. Update flow

Three independent automated update channels plus the deliberate one.

### OS — `dnf-automatic`

- AlmaLinux 10 is dnf **4**: the unit is `dnf-automatic-install.timer`,
  pinned to `dnf_reboot_dow` at `dnf_reboot_window` (default Tue 04:00).
- Scope: security-only. Reboots only when a package requires it
  (`reboot = when-needed`).
- Watch: `journalctl -u dnf-automatic-install.service`. The stack's
  `dnf-automatic` Healthchecks ping fires on each successful run.

### Containers — `podman auto-update`

- Schedule: daily (rootless user timer). Every deploy also runs it once
  (`rollout` tag) so a new image lands immediately.
- Tracks floating tags: `docker.io/vaultwarden/server:latest` and
  `…/vaultwarden/caddy:<stack>`.
- Vaultwarden is health-gated (`HealthCmd=/healthcheck.sh` +
  `Notify=healthy`): an image that starts but fails its healthcheck is
  rolled back automatically. Caddy (distroless, no shell for a healthcheck)
  rolls back only if it fails to start.
- Watch: `sudo systemctl --user -M vaultwarden@ status podman-auto-update.service`.
  The `podman-auto-update` Healthchecks ping fires on each run.

### Caddy image — CI

- Bump `caddy/versions.env` (Caddy core, Coraza, googleclouddns — bump
  Caddy and Coraza together; see `caddy/README.md`), push to `main`.
- deploy.yml builds, asserts both plugins are compiled in, Trivy-gates
  HIGH/CRITICAL, pushes `caddy:<sha>`, tags `caddy:disposable`, and rolls
  it out to disposable.
- Promote: dispatch `stack=production` from `main` at the same commit. The
  scanned `caddy:<sha>` is re-tagged `caddy:production`, not rebuilt.

### Vaultwarden image

It's `docker.io/vaultwarden/server:latest`; auto-update tracks it. To pin,
change `Image=` in `quadlets/vaultwarden.container` to a version tag and drop
`AutoUpdate=registry`.

---

## 8. Rollback

### Caddy image rolls back broken

```sh
IMAGE=us-east1-docker.pkg.dev/vaultwarden-497422/vaultwarden/caddy
gcloud artifacts docker tags list "$IMAGE"            # find the last good <sha>
gcloud artifacts docker tags add "$IMAGE:<good-sha>" "$IMAGE:<stack>"
gcloud compute ssh vault-<stack> --zone us-east1-b --tunnel-through-iap
sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 podman auto-update
```

The AR repo keeps the 20 most recent tagged versions; untagged images go
after 14 days.

### Bad Ansible or Pulumi change

```sh
git revert <commit>
git push        # main → disposable redeploys; dispatch production after checking it
```

### Anything that would replace the VM or its data disk

The `infra` job refuses any replace/delete of the instance or disk unless
dispatched with `allow_replace=true`. A replacement means ~15 minutes of
downtime and a fresh certificate. Before setting it:

```sh
gcloud compute snapshots create vault-<stack>-data-pre-<change>-$(date +%Y%m%d) \
  --source-disk=vault-<stack>-data --source-disk-zone=us-east1-b --storage-location=us-east1
curl -s 'https://api.certspotter.com/v1/issuances?domain=<fqdn>' | jq length   # < 5 this week?
```

The data disk is a separate resource; a VM replacement re-attaches it.
Machine-type changes are in-place (stop/resize/start), not replacements.

### Catastrophic loss — restore from R2

See `runbook/restore-drill.md` — same procedure, restoring onto the stack's
data disk instead of a scratch directory.

### Inside the cutover window

If you're in the §5 two-week window and decide to abandon:

```sh
# Repoint clients back to https://vault.bitwarden.com
# Restore from the day-0 export in hosted Bitwarden's import UI.
# Tear down production — protection makes this a deliberate two-step:
cd pulumi && pulumi login gs://vaultwarden-497422-pulumi-state
pulumi -s production state unprotect --all
# set vaultwarden:deleteProtection "false" in Pulumi.production.yaml, then:
pulumi -s production up && pulumi -s production destroy
# platform/: set production active: false, pulumi up (bucket is kept).
```

---

## 9. Troubleshooting

### Web vault won't load — TLS error

- Caddy DNS-01 needs Cloud DNS. Check:
  `sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 journalctl --user -u caddy.service | grep -i dns`
- **Bare 403 while presenting the challenge**: googleclouddns finds its
  zone by *listing* the project's zones, which needs the project-level
  `projects/vaultwarden-497422/roles/dnsZoneLister` on
  `vaultwarden-caddy-dns@` on top of zone-scoped `dns.admin`. Both are
  declared in `platform/main.go` (`grantCaddyDNS`).
- The SA key may have been revoked or rotated without redeploying: re-run
  `--tags secrets,quadlets` (§6), which replaces the Podman secret and
  restarts the containers.

### Let's Encrypt refuses a certificate after a rebuild

ACME state lives on the boot disk, so every VM replacement or disposable
destroy/redeploy re-issues. LE allows 5 certificates per week for the same
name set. Check before replacing:
`curl -s 'https://api.certspotter.com/v1/issuances?domain=<fqdn>'`
(crt.sh is often down). If you hit the limit, wait it out; the old cert is
gone with the old boot disk.

### Web vault loads but sync fails

- Vaultwarden may be returning 5xx:
  `sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 journalctl --user -u vaultwarden.service`
- `/data` full: `df -h /data`. Grow the disk in place (`dataDiskGb` in the
  stack config → deploy → `sudo resize2fs /dev/disk/by-id/google-vault-data`).

### Vaultwarden won't start, `mountpoint -q /data` failed

The data disk didn't mount (`nofail` let the boot continue). The guard is
doing its job: without it Vaultwarden would initialise an empty vault on the
boot disk. Check `lsblk`, `journalctl -b -u data.mount`, that the disk is
attached (`gcloud compute instances describe vault-<stack> --zone us-east1-b
--format='value(disks[].deviceName)'` includes `vault-data`), then
`sudo mount /data` and start the unit.

### IAP SSH / Ansible can't connect

- `4033: 'not authorized'` from `start-iap-tunnel`: the caller lacks
  `roles/iap.tunnelResourceAccessor` (deployer: granted in `platform/`).
- `Permission denied (publickey)`: OS Login. Caller lacks
  `roles/compute.osAdminLogin`; the instance lost `enable-oslogin=TRUE`; or
  the ephemeral key expired (1h TTL) on a very long run.
  `gcloud compute ssh vault-<stack> --zone us-east1-b --troubleshoot --tunnel-through-iap`
  diagnoses most of these.
- Connection hangs: VPC rule `vaultwarden-allow-iap-ssh` or the nftables
  `35.235.240.0/20` line missing.
- `ansible-iap: no host keys published`: the guest agent publishes SSH host
  keys as guest attributes a minute or two after boot. Check
  `gcloud compute instances get-guest-attributes vault-<stack> --zone us-east1-b --query-path=hostkeys/`.
  Empty for long → `enable-guest-attributes` missing from metadata or the
  guest agent isn't running (serial console:
  `gcloud compute instances get-serial-port-output vault-<stack> --zone us-east1-b`).
- After a VM replacement your *personal* `gcloud compute ssh` may warn about
  a changed host key — expected; remove the entry from
  `~/.ssh/google_compute_known_hosts`. The Ansible wrapper pins fresh keys
  every run.

### Deploy fails in `infra`

- `Refusing without allow_replace=true` — working as intended; read §8.
- `look up vault-<stack>-ipv4 (is the stack active in platform/?)` — the
  stack is `active: false` in `platform/Pulumi.prod.yaml`, or platform
  hasn't been applied.
- Permission errors on state or KMS — the deployer's grants live in
  `platform/main.go`; add the narrowest missing grant there (and to the
  allow-list in `platform/main_test.go` if it's a new role).

### Never `systemctl restart|reload nftables`

On EL both run `flush ruleset`, wiping fail2ban's ban tables. Load
changes with `sudo nft -f /etc/nftables/main.nft` (it replaces only
`table inet vaultwarden_filter`). If it happened anyway:
`sudo systemctl restart fail2ban` re-applies bans from its database.

### Coraza audit log balloons

Coraza doesn't roll `SecAuditLog` itself; the quadlets role installs
`/etc/logrotate.d/coraza-audit` (daily, 14 kept, copytruncate). Check it
ran: `sudo logrotate -d /etc/logrotate.d/coraza-audit`.

### fail2ban banned the Caddy container IP

Real-IP forwarding broke (§3.4). Verify Vaultwarden env still has
`IP_HEADER=X-Forwarded-For` and the Caddyfile still injects
`X-Forwarded-For {remote_host}`. Unban with
`sudo fail2ban-client unban <ip>`.

### Healthchecks paged but nothing's wrong

Most often clock skew: `timedatectl` should show `Synchronized: yes`.
Second most often: a disposable box pinging into the wrong stack's checks —
each stack's URLs live in its own `vaultwarden-<stack>-healthchecks` secret.

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

Then investigate why — usually a broken `:<stack>` push or a config
incompatibility with a new upstream version.

---

## 10. Where things live

### On the host

| Path / unit                                            | What |
|--------------------------------------------------------|------|
| `/data`                                                | Vaultwarden DB, attachments, sends, log — the GCE data disk (`/dev/disk/by-id/google-vault-data`, ext4, label `vault-data`) |
| `/data/vaultwarden.log`                                | Vaultwarden's log file (fail2ban tails it) |
| `/data/db.sqlite3`                                     | The live DB |
| `/data/db-backup.sqlite3`                              | Latest consistent snapshot (overwritten daily) |
| `/swapfile`                                            | 2 GB swap ballast (`vm.swappiness=10`) |
| `/etc/vaultwarden/restic.env`                          | restic creds (0640 root:vaultwarden) |
| `/etc/vaultwarden/healthchecks.env`                    | HC ping URLs |
| `/etc/nftables/main.nft`                               | Host firewall: `table inet vaultwarden_filter` only |
| `/etc/sysconfig/nftables.conf`                         | Boot-time include of the above |
| `/etc/fail2ban/jail.local`                             | fail2ban jails (`ignoreip` includes the IAP range) |
| `/etc/msmtprc`                                         | system msmtp config |
| `/etc/aliases`                                         | root → operator |
| `/usr/local/sbin/vaultwarden-backup`                   | backup driver script |
| `/usr/local/sbin/systemd-email`                        | OnFailure email helper (system units) |
| `/usr/local/sbin/vaultwarden-container-watch`          | container-down/recovered email (rootless units can't use OnFailure=) |
| `/var/lib/vaultwarden/`                                | rootless user home (uid 1100) |
| `/var/lib/vaultwarden/.config/containers/systemd/`     | quadlets |
| `/var/lib/vaultwarden/.config/systemd/user/`           | user systemd drop-ins |
| `/var/lib/vaultwarden/vaultwarden.env`                 | `DOMAIN`, `SIGNUPS_ALLOWED` |
| `/var/lib/vaultwarden/caddy/Caddyfile`                 | Caddy config |
| `/var/lib/vaultwarden/caddy/caddy.env`                 | `VAULT_FQDN`, `ADMIN_CIDRS`, `GCP_PROJECT` |
| `/var/lib/vaultwarden/caddy/data/`                     | Caddy state (certs, OCSP) — boot disk |
| `/var/lib/vaultwarden/caddy/logs/`                     | Caddy access + Coraza audit |
| `vaultwarden-backup.timer`                             | system timer, daily 02:30 UTC |
| `restic-check.timer`                                   | system timer, Sun 03:30 |
| `restore-drill-reminder.timer`                         | system timer, Jan/Apr/Jul/Oct 1st |
| `dnf-automatic-install.timer`                          | OS security updates |
| `podman-auto-update.timer` (user)                      | container updates (rootless) |
| `vaultwarden-container-watch.timer`                    | system timer, every 2 min: container-down alerting |

### In GCP / Cloudflare / Gitea

| Thing | Where |
|---|---|
| Platform state | `gs://vaultwarden-497422-platform-state` (owner only) |
| App state | `gs://vaultwarden-497422-pulumi-state` (deployer: objectAdmin) |
| Pulumi secrets key | KMS `projects/vaultwarden-497422/locations/global/keyRings/pulumi/cryptoKeys/stacks` |
| Secrets | Secret Manager, names in `secrets/secret-names.txt` |
| Caddy image | `us-east1-docker.pkg.dev/vaultwarden-497422/vaultwarden/caddy:{<sha>,disposable,production}` |
| VMs / disks | `vault-<stack>` / `vault-<stack>-data` in us-east1-b; snapshots `vault-<stack>-daily-snapshots` |
| Addresses + DNS | `vault-<stack>-ipv4/-ipv6`; A/AAAA in zone `vault` (platform/) |
| Backups | R2 buckets `vaultwarden-backups-<stack>` |
| CI | `.gitea/workflows/{ci,deploy}.yml`; repo secret `GCP_DEPLOYER_KEY` |
