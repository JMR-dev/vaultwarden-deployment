# Restore drill

Quarterly. The `restore-drill-reminder.timer` mails the operator on the 1st
of Jan/Apr/Jul/Oct to run this.

A backup you've never restored is a hypothesis, not a backup. The point of
the drill is to *prove* the restore path works — index, blobs, and the
SQLite DB integrity — not to assume.

## Pattern

Restore **production's** R2 repo onto something that is not production: the
operator's laptop, or the `vault-disposable` VM. Never restore over `/data`
on the production host as a drill; that's a recipe for accidentally wiping
live data. The repo is read-only for this purpose — the drill never runs
`backup`, `forget` or `prune`.

`gcloud compute ssh vault-production` below always means
`gcloud compute ssh vault-production --zone us-east1-b --tunnel-through-iap`.

## Procedure

### 1. Pick the restore target

- **Laptop** (simplest): needs `restic`, `sqlite3`, `podman`.
- **`vault-disposable`**: already has all three. Copy the env file there
  with `gcloud compute scp --tunnel-through-iap` instead of keeping it
  locally.

The OS doesn't matter for the drill — only the bytes in R2 do.

### 2. Pull production's restic env

Take it from the production host, so the drill uses exactly what the backup
service uses:

```sh
drill=$(mktemp -d)          # /tmp is tmpfs on Fedora; keeps creds off disk
gcloud compute ssh vault-production --zone us-east1-b --tunnel-through-iap \
  --command 'sudo cat /etc/vaultwarden/restic.env' > "$drill/restic.env"
chmod 600 "$drill/restic.env"
```

(If the production host is gone — a real disaster — rebuild the same four
lines from the `vaultwarden-production-restic` secret:
`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`.)

### 3. Restore the latest snapshot

```sh
set -a; . "$drill/restic.env"; set +a

restic snapshots --latest 3
restic restore latest --target "$drill/restore"

ls "$drill/restore/data/"
# Expect: db-backup.sqlite3, attachments/, sends/, config.json, rsa_key*, ...
```

### 4. Verify the restored DB

```sh
sqlite3 "$drill/restore/data/db-backup.sqlite3" 'PRAGMA integrity_check;'
# Expected: ok

sqlite3 "$drill/restore/data/db-backup.sqlite3" \
  'SELECT COUNT(*) AS ciphers FROM ciphers;
   SELECT COUNT(*) AS users   FROM users;'
# Compare against production:
gcloud compute ssh vault-production --zone us-east1-b --tunnel-through-iap --command \
  "sudo sqlite3 /data/db.sqlite3 'SELECT COUNT(*) FROM ciphers; SELECT COUNT(*) FROM users;'"
```

Counts should match (allowing for any items added since the snapshot was
taken).

### 5. End-to-end restore — actually log in

This is the step that catches "the bytes restored, but the vault is
unusable":

1. Make a throwaway TLS certificate for `localhost`. The web vault won't
   work over plain HTTP, even on `localhost` (found in the 2026-10-24
   drill), so the test container serves HTTPS itself. The key stays in
   `$drill` and step 6 shreds it:
   ```sh
   mkdir "$drill/tls"
   openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
     -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
     -keyout "$drill/tls/key.pem" -out "$drill/tls/cert.pem"
   openssl x509 -in "$drill/tls/cert.pem" -noout -fingerprint -sha256
   ```
2. Bring up a temporary Vaultwarden container against the restored DB,
   serving that certificate on 127.0.0.1 only:
   ```sh
   podman run --rm -d --name vw-restore-test \
     -v "$drill/restore/data:/data:Z" \
     -v "$drill/tls:/ssl:ro,Z" \
     -e DATA_FOLDER=/data \
     -e DATABASE_URL=sqlite:///data/db-backup.sqlite3 \
     -e SIGNUPS_ALLOWED=false \
     -e WEB_VAULT_ENABLED=true \
     -e ROCKET_TLS='{certs="/ssl/cert.pem",key="/ssl/key.pem"}' \
     -e ROCKET_PORT=8443 \
     -e DOMAIN=https://localhost:8443 \
     -p 127.0.0.1:8443:8443 \
     docker.io/vaultwarden/server:latest
   ```
   On `vault-disposable`, reach it with
   `gcloud compute ssh vault-disposable --zone us-east1-b --tunnel-through-iap -- -L 8443:127.0.0.1:8443`.
3. In a browser: `https://localhost:8443/`. The browser warns that the
   certificate isn't trusted. Check that its SHA-256 fingerprint matches
   the one printed in step 1, then accept it for this site only. Log in
   with the operator's actual master password.
4. Verify one login from each cipher type opens and shows the right
   credential. Spot-check one Secure Note for content fidelity and one
   attachment download.
5. Log out, stop the container (`podman stop vw-restore-test`), and remove
   the browser's certificate exception for `localhost:8443`.

### 6. Tear down

```sh
find "$drill" -type f -exec shred -u {} +
rm -rf "$drill"
```

### 7. Record the result

Append a one-liner to `runbook/drill-log.md` (create it if missing):

```
2026-04-01: restore from r2 ok. snapshot 5h old, integrity_check ok,
  counts match prod (ciphers=312, users=1). web login round-tripped on
  vw-restore-test.
```

A drill log makes the next "did this ever actually work?" question
answerable.

## The second copy: GCE snapshots

The data disk also has daily, crash-consistent snapshots
(`vault-production-daily-snapshots`, 7 days, kept even if the disk is
deleted). They are a fast in-provider restore, *not* a substitute for the
R2 drill — same provider, same account, same blast radius. Once a year,
prove they work too:

```sh
gcloud compute snapshots list --filter='labels.stack=production' --sort-by=~creationTimestamp --limit=1
gcloud compute disks create vault-drill-data --zone us-east1-b --source-snapshot=<snapshot>
# Attach to vault-disposable, mount read-only, run the step-4 checks on
# db-backup.sqlite3, detach, then delete vault-drill-data.
```

## What "drill failed" actually means

| Failure mode                                            | What it tells you                                       | Action |
|---------------------------------------------------------|---------------------------------------------------------|--------|
| `restic restore` errors / index mismatch                | R2 corruption or repo metadata damage                   | Re-run `restic check --read-data` *immediately* against the prod env; check the latest restic-check ping for a missed alert |
| `PRAGMA integrity_check` not `ok`                       | The backup *script* uploaded a corrupt snapshot         | A pre-existing snapshot in R2 may also be bad; restore older snapshots one by one until one passes |
| DB counts way off                                       | Backups are running but missing data                    | Confirm the backup script's `--exclude` patterns aren't pulling in the live DB or skipping the snapshot path |
| Web login fails on the restored container               | KDF / master-password mismatch, or DB schema drift      | Verify the Vaultwarden image used in the test matches what wrote the snapshot; a major-version DB schema change can require an upgrade pass |
| `restic.env` can't be fetched                           | IAP/OS Login access broken, or the host is gone         | Fix access (runbook §9); for a real disaster, rebuild the env from Secret Manager (step 2) |

A failed drill is itself an early warning. Better to find it here than the
day an outage forces you to restore for real.

## Restoring for real

Same steps 2–4 against a freshly deployed (or the existing) production VM,
then put the bytes on the data disk:

```sh
gcloud compute ssh vault-production --zone us-east1-b --tunnel-through-iap
sudo systemctl --user -M vaultwarden@ stop vaultwarden.service
# /var/tmp, not /tmp: /tmp may be tmpfs, and this is a 2 GB VM.
sudo -u vaultwarden bash -c 'set -a; . /etc/vaultwarden/restic.env; set +a; restic restore latest --target /var/tmp/restore'
sudo rsync -a --delete --exclude lost+found /var/tmp/restore/data/ /data/   # includes db-backup.sqlite3
sudo -u vaultwarden cp /data/db-backup.sqlite3 /data/db.sqlite3
sudo rm -f /data/db.sqlite3-wal /data/db.sqlite3-shm /data/db.sqlite3-journal
sudo rm -rf /var/tmp/restore
# Back to the vault's private SELinux label. root's writes above are at s0,
# readable by any container; -F resets the MCS level too (base role).
sudo restorecon -R -F /data
sudo systemctl --user -M vaultwarden@ start vaultwarden.service
```

Then log in from a client and confirm recent items exist.
