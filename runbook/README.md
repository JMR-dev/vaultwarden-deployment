# Vaultwarden deployment runbook

Operator-facing guide. The design reasoning lives in the code comments
(`platform/main.go`, `pulumi/main.go`, `scripts/*.sh`) and in the plan at
`~/.claude/plans/finish-deploying-this-vaultwarden-velvety-cerf.md` — this
file is the *how*, not the *why*.

Shape of the system, in one paragraph: one AlmaLinux 10 GCE VM per stack
(`vault-disposable`, `vault-production`) in `vaultwarden-497422`, us-east1-b.
Two Pulumi projects: `platform/` (owner-run: network, static IPs, DNS, R2
buckets, the Resend mail domain, Artifact Registry, every IAM grant) and
`pulumi/` (CI-run: the VM,
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
  - Cloud DNS zone `vault` = `vault.jasonrossmedia.com.` (gcloud-made,
    delegated by an NS record in zone `main` of project `stoat-burrow`,
    which serves `jasonrossmedia.com`; deliberately not Pulumi-owned).
  - App state bucket `gs://vaultwarden-497422-pulumi-state`.
  - `vaultwarden-caddy-dns@` SA, whose JSON key Caddy uses for DNS-01
    (stored in the `vaultwarden-vaultwarden` secret as `gcp_sa_dns_json`).
  - `gcloud auth login` **and** `gcloud auth application-default login`
    as the project owner — Pulumi's GCS backend and KMS provider use ADC.
- **Cloudflare**: the account that will own the R2 buckets (note its account
  id), and an API token with **Workers R2 Storage: Edit** for Pulumi. It goes
  into the `vaultwarden-cloudflare-api-token` secret (§2.2); the deployer
  never sees it, and neither do the hosts (§2.4).
- **Healthchecks.io**: four checks **per stack** (eight total) in the
  `jasonrossmedia.com` project, named `vaultwarden-<stack>-<job>` and tagged
  `vaultwarden <stack>`, on cron schedules (UTC) matching the timers: backup
  daily 02:30, restic check Sun 03:30, dnf-automatic Tue 04:00, podman
  auto-update daily 00:00. Per stack so the disposable box can't keep
  production's checks green. Keep the project's read-write API key at hand
  for pausing disposable's checks (§2.9).
- **Resend** sends the alert mail (port **587**; GCE blocks 25): a
  full-access API key for `platform/`, which manages the sending domain
  `vault.jasonrossmedia.com` (secret `vaultwarden-resend-api-key`), plus the
  address alerts go to (`msmtp_alert_to`, kept in the secret, not the
  inventory). The hosts get their own sending-only key (§2.3).
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

`disposable` is a temporary stack, not a long-lived staging environment: it
exists for one test cycle (§2.9) and is destroyed after it. The first cycle
flushes out platform surprises on a VM you don't mind destroying. Iterate
destroy → redeploy until the stack stands up with zero hand-intervention,
then promote to production.

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
- `vaultwarden-resend-api-key` — the full-access Resend key from §1.

Before the first deploy (can be done in parallel with §2.3):

- `vaultwarden-vaultwarden` — already has a version; confirm with
  `gcloud secrets versions list vaultwarden-vaultwarden`.
- `vaultwarden-disposable-healthchecks`, `vaultwarden-production-healthchecks`

`vaultwarden-msmtp` needs the mail domain (§2.3) and the restic secrets need
the R2 buckets (§2.4).

### 2.3 ⚠ Platform stack

```sh
cd platform
pulumi login gs://vaultwarden-497422-platform-state
pulumi stack init prod \
  --secrets-provider gcpkms://projects/vaultwarden-497422/locations/global/keyRings/pulumi/cryptoKeys/stacks
pulumi config set --secret vaultwarden-platform:cloudflareAccountId <account-id>

export CLOUDFLARE_API_TOKEN=$(gcloud secrets versions access latest \
  --secret=vaultwarden-cloudflare-api-token --project vaultwarden-497422)
export RESEND_API_KEY=$(gcloud secrets versions access latest \
  --secret=vaultwarden-resend-api-key --project vaultwarden-497422)
pulumi preview --diff
pulumi up
unset CLOUDFLARE_API_TOKEN RESEND_API_KEY
```

Commit the `secretsprovider`/`encryptedkey`/encrypted-account-id lines that
`stack init` and `config set` added to `platform/Pulumi.prod.yaml`.

Creates: VPC `vaultwarden` + dual-stack subnet, firewall (443 public, ICMP,
22 from IAP `35.235.240.0/20` only), per-stack static IPv4/IPv6 and A/AAAA
records, per-stack R2 buckets `vaultwarden-backups-<stack>` (protected),
the Resend domain `vault.jasonrossmedia.com` (protected) with its DKIM and
return-path records, AR repo `vaultwarden`, the `vaultwarden-deployer@` SA
and every grant. `pulumi up` waits until Resend has verified the domain
(usually minutes). `pulumi stack output` shows the bucket names,
`caddyImage` and `mailDomainId`.

Then give the hosts their own mail key: in Resend, **API Keys → Create**,
permission **Sending access**, domain `vault.jasonrossmedia.com`. It is the
`msmtp_smtp_password` in `vaultwarden-msmtp` (schema in `secrets/README.md`).
Never give the hosts the full-access key.

### 2.4 R2 tokens and restic secrets

In the Cloudflare dashboard: **R2 → Manage R2 API Tokens → Create token**,
permission **Object Read & Write**, scoped to the two
`vaultwarden-backups-*` buckets. Both stacks share it. That's a deliberate
trade-off: a compromised disposable host could delete production's backups,
though not read them, since each stack has its own `restic_password`. For
full isolation, make one token per bucket instead. The token yields an
Access Key ID and Secret Access Key.

Never use the platform's Cloudflare token here. R2's S3 credentials are
derived from an API token (key id = token id, secret = SHA-256 of the
token), so that token's S3 pair reaches every bucket in the account, and
the deployer can read the restic secrets.

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

`deploy.yml` refuses a production deploy from any ref but `main`, so `main`
must be protected **on Gitea**.
`repo_config_settings` only ever configured the old GitHub repo. Check
**Settings → Branches** in the Gitea UI (or
`GET /api/v1/repos/JMR-dev/vaultwarden-deployment/branch_protections`) and
add a rule for `main` if there is none.

### 2.8 ⚠ First deploy (disposable)

Gitea only offers **Run workflow** for workflows that exist on the default
branch, so `.gitea/workflows/deploy.yml` has to reach `main` first. Merging
deploys nothing: `deploy.yml` is dispatch-only.

1. Merge the branch carrying `.gitea/workflows/deploy.yml` into `main`.
2. Gitea → **Actions → deploy → Run workflow**: `stack=disposable`,
   `signups=true`. That run opens registration.

Any branch can be dispatched against disposable; production only from
`main`.

The run is `guard → image → infra → configure`:

- **image** builds the Caddy image, Trivy-scans it, pushes `caddy:<sha>`
  and moves the floating `caddy:disposable` tag.
- **infra** previews and applies `pulumi up` (the first run creates the VM
  and disk).
- **configure** runs `scripts/ansible-iap.sh disposable`.

Expect ~10–15 minutes on a fresh VM.

Then create the test account **through an IAP tunnel**. Caddy answers 404 to
registration from anywhere else, even while signups are open. The new
hostname is in the public Certificate Transparency logs within minutes, and
bots register on fresh instances to host files with Send.

1. Open the tunnel. Your Google identity is the gate: it needs
   `iap.tunnelResourceAccessor`.
   ```sh
   gcloud compute start-iap-tunnel vault-disposable 443 \
     --local-host-port=localhost:8443 --zone us-east1-b
   ```
2. Point the hostname at the tunnel. Temporarily add this line to
   `/etc/hosts`:
   `127.0.0.1 disposable.vault.jasonrossmedia.com`. The certificate then
   matches, and Caddy sees an IAP source address.
3. Browse to `https://disposable.vault.jasonrossmedia.com:8443/#/signup` and
   create the account.
4. Remove the hosts line and stop the tunnel.
5. Confirm a stranger can't register:
   `curl -s -o /dev/null -w '%{http_code}\n' -X POST https://disposable.vault.jasonrossmedia.com/identity/accounts/register`
   should print `404`.

The window closes itself `vaultwarden_signups_window_minutes` (30) after the
deploy. `vaultwarden-signups-close.timer` turns `SIGNUPS_ALLOWED` off, and the
timer is persistent, so it survives a reboot. Root then gets a mail listing
**every account in the vault**: check that each one is yours. Re-running the
workflow with `signups=false` closes the window early, as any later deploy
does. To close it by hand: `sudo /usr/local/sbin/vaultwarden-signups-close`.

`/admin` is disabled by default, so the `signups` deploy is the only way to
create the first account on a fresh stack.

**An account that is not yours** (it shouldn't happen behind the IAP gate):
1. Set `admin_token_argon2` in `vaultwarden-vaultwarden`.
2. Redeploy with `--tags secrets,quadlets`.
3. Delete the account in `/admin` through the same IAP tunnel (`/admin` is
   IAP-only too).
4. Clear the token and redeploy.

### 2.9 The disposable cycle (repeatable)

Bring disposable up to test a change (a Caddy bump, an Ansible role, the
drills in §3), then take it down. Between cycles nothing of it exists but
its R2 bucket. The first cycle is §2.8 plus §3; later ones are just this.

**Start**

1. ⚠ In `platform/Pulumi.prod.yaml`, set `active: true` for disposable, then
   run `pulumi up` in `platform/` (credentials as in §2.3) and commit. This
   reserves its static IPs, writes its A/AAAA records and grants its
   secrets.
2. ⚠ Dispatch deploy: `stack=disposable`, from the branch under test, with
   `signups=true` on a fresh VM, then once more with `signups=false`.
3. Test. Its Healthchecks checks resume on their first ping.

**End**

1. ⚠ Destroy the app stack:
   ```sh
   cd pulumi && go build -o bin/vaultwarden .
   pulumi login gs://vaultwarden-497422-pulumi-state
   pulumi destroy -s disposable
   ```
   Its disk snapshots then age out on the 7-day retention instead of being
   kept (`deleteProtection` is off).
2. Pause its checks so they don't alert while it's gone:
   `scripts/healthchecks-pause.sh disposable` (prompts for the
   Healthchecks API key).
3. ⚠ Set `active: false` for disposable, `pulumi up` in `platform/`, and
   commit. That releases its static IPs (idle ones bill), drops its DNS
   records and secret grants. The R2 bucket stays (protected), and so does
   its restic repository, which the next cycle's backups reuse.

Every cycle issues a new Let's Encrypt certificate for
`disposable.vault.jasonrossmedia.com`, at most five a week (§3.1).

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
curl -4 -sSf -o /dev/null -w '%{http_code}\n' https://disposable.vault.jasonrossmedia.com/
curl -6 -sSf -o /dev/null -w '%{http_code}\n' https://disposable.vault.jasonrossmedia.com/
```

Both 200 with a valid Let's Encrypt certificate (DNS-01 issued). A browser
should load the web vault.

If `-4` works and `-6` doesn't (the AAAA record is published, so IPv6
clients will try it first), check where the host listens:
`sudo ss -ltnp 'sport = :443'`. You should see both `0.0.0.0:443` and
`[::]:443`, held by the vaultwarden user's systemd (`caddy.socket`). If
either is missing, run `systemctl --user -M vaultwarden@ status caddy.socket`.
As a stopgap, drop the AAAA record in `platform/main.go`. If `[::]:443` is
listening but still unreachable, check the
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
curl -sS -o /dev/null -w '%{http_code}\n' https://disposable.vault.jasonrossmedia.com/admin
# → 404
# ...and reachable only through an IAP tunnel to :443:
gcloud compute start-iap-tunnel vault-disposable 443 \
  --local-host-port=localhost:8443 --zone us-east1-b &
curl -sS -o /dev/null -w '%{http_code}\n' \
  --resolve disposable.vault.jasonrossmedia.com:8443:127.0.0.1 \
  https://disposable.vault.jasonrossmedia.com:8443/admin
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

Caddy's access log must show the same address:
`sudo tail -n 3 /var/lib/vaultwarden/caddy/logs/access.log | jq -r .request.remote_ip`.

If either shows an internal address (`10.89.0.x`), Caddy isn't getting its
listeners from `caddy.socket`, and rootless Podman's port forwarder is
hiding client IPs. A `PublishPort=` crept back into
`quadlets/caddy.container.j2`, or the socket isn't active. Three
consequences:
- fail2ban can't ban anyone;
- `/admin` stays 404 even through the IAP tunnel (it fails closed);
- so does account registration, so nobody can create an account.

Stop and fix before continuing:
`systemctl --user -M vaultwarden@ status caddy.socket caddy.service`.

Don't "fix" it with `Network=host` for Caddy. That would put the
internet-facing proxy in the host's network namespace, with every
host-local service in reach. Socket activation preserves addresses
without that tradeoff: a socket systemd opened on the host keeps the real
peer address, and Caddy stays on its own bridge network.

### 3.5 fail2ban bans actually drop traffic, and survive a ruleset load

```sh
gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap
sudo fail2ban-client set vaultwarden banip <an IP you control, not IAP>
# From that IP: curl https://disposable.vault.jasonrossmedia.com/ → hangs/refused
sudo nft list ruleset | grep -c f2b          # note the count
sudo nft -f /etc/nftables/main.nft           # what every Ansible run does
sudo nft list ruleset | grep -c f2b          # same count: bans survived
sudo fail2ban-client set vaultwarden unbanip <ip>

# The ban reaches you in the daily digest (fail2ban mails nothing per ban).
# Send it now instead of waiting for 12:00 UTC:
sudo systemctl start fail2ban-digest.service
# Expect "[vault-disposable] fail2ban: N ban(s) since the last digest".
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
curl -4 -sSf https://disposable.vault.jasonrossmedia.com/ >/dev/null && \
curl -6 -sSf https://disposable.vault.jasonrossmedia.com/ >/dev/null && echo ok
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
  for s in vaultwarden-cloudflare-api-token vaultwarden-resend-api-key; do
    gcloud secrets get-iam-policy "$s" --format=json \
      | jq -r '.bindings[]?.members[]' | grep -c deployer
  done
  # → 0, twice
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
2. Create your real account through the IAP tunnel, as in §2.8:
   `gcloud compute start-iap-tunnel vault-production 443 --local-host-port=localhost:8443 --zone us-east1-b`,
   then add `127.0.0.1 vault.jasonrossmedia.com` to `/etc/hosts` and browse
   `https://vault.jasonrossmedia.com:8443/#/signup`. Then remove the hosts
   line.
3. ⚠ Re-run with `signups=false`, or let the 30-minute timer close it.
   Confirm registration is refused, and that the account-list mail shows
   only your account.
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

In `https://vault.jasonrossmedia.com`: **Tools → Import Data → Bitwarden (json)**.

### 5.3 Re-upload attachments manually

Attachments are Premium-gated and not in the export. Audit Secure Notes
specifically — that's where attachments most often hide.

### 5.4 Repoint clients

Browser extension, mobile app, desktop: settings → server URL →
`https://vault.jasonrossmedia.com`. Log in fresh. Verify autofill works.

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

### Testing a change on disposable

disposable exists only during a test cycle. To bring it up and take it down
again, see §2.9.

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
  Caddy and Coraza together; see `caddy/README.md`) on a branch, and run a
  disposable cycle from it (§2.9).
- deploy.yml builds, asserts both plugins are compiled in, Trivy-gates
  HIGH/CRITICAL, pushes `caddy:<sha>`, tags `caddy:disposable`, and rolls
  it out to disposable.
- Promote: merge (fast-forward, so `main` is the same commit), then
  dispatch `stack=production` from `main`. The scanned `caddy:<sha>` is
  re-tagged `caddy:production`, not rebuilt.

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
scripts/retag-image.sh "$IMAGE:<good-sha>" <stack>    # same move deploy.yml makes
gcloud compute ssh vault-<stack> --zone us-east1-b --tunnel-through-iap
sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1100 podman auto-update
```

The AR repo keeps the 20 most recent tagged versions; untagged images go
after 14 days.

### Bad Ansible or Pulumi change

```sh
git revert <commit>
git push        # then dispatch the affected stack; nothing deploys on push
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
| `/etc/fail2ban/jail.local`                             | fail2ban jails (`ignoreip` includes the IAP range); ban-only, no mail |
| `/etc/fail2ban/fail2ban.local`                         | fail2ban logs to the journal (`journalctl -u fail2ban`) |
| `/usr/local/sbin/fail2ban-digest`, `fail2ban-digest.timer` | daily mail of the bans since the last digest (12:00 UTC; cursor in `/var/lib/fail2ban-digest/`) |
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
