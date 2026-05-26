# Restore drill

Quarterly. The `restore-drill-reminder.timer` mails the operator on the 1st
of Jan/Apr/Jul/Oct to run this.

A backup you've never restored is a hypothesis, not a backup. The point of
the drill is to *prove* the restore path works — index, blobs, and the
SQLite DB integrity — not to assume.

## Pattern

Restore to a **scratch host** with no real DNS and no real vault traffic.
Never restore over `/data` on the production host as a drill; that's a
recipe for accidentally wiping live data.

## Procedure

### 1. Stand up a scratch host

Either a fresh Hetzner CX22 from a one-off `pulumi up` against the
disposable stack, or a local Linux VM with `restic` installed. The OS
doesn't matter for the drill — only the bytes in R2 do.

### 2. Pull the restic env from the production host

On a peer with WG up:

```sh
ssh ansible@10.42.0.1 'sudo cat /etc/vaultwarden/restic.env' > /tmp/restic.env
chmod 600 /tmp/restic.env
```

### 3. Restore the latest snapshot

On the scratch host (or anywhere `restic` runs), with `/tmp/restic.env`
present:

```sh
set -a; . /tmp/restic.env; set +a

mkdir -p /tmp/vaultwarden-restore
restic restore latest --target /tmp/vaultwarden-restore

ls /tmp/vaultwarden-restore/data/
# Expect: db-backup.sqlite3, attachments/, sends/, config.json, ...
```

### 4. Verify the restored DB

```sh
sqlite3 /tmp/vaultwarden-restore/data/db-backup.sqlite3 'PRAGMA integrity_check;'
# Expected: ok

sqlite3 /tmp/vaultwarden-restore/data/db-backup.sqlite3 \
  'SELECT COUNT(*) AS ciphers FROM ciphers;
   SELECT COUNT(*) AS users   FROM users;'
# Compare against production:
ssh ansible@10.42.0.1 sudo sqlite3 /data/db.sqlite3 \
  "'SELECT COUNT(*) AS ciphers FROM ciphers; SELECT COUNT(*) AS users FROM users;'"
```

Counts should match (allowing for any items added since the snapshot was
taken).

### 5. End-to-end restore — actually log in

This is the step that catches "the bytes restored, but the vault is
unusable":

1. Bring up a temporary Vaultwarden container against the restored DB:
   ```sh
   podman run --rm -d --name vw-restore-test \
     -v /tmp/vaultwarden-restore/data:/data:Z \
     -e DATA_FOLDER=/data \
     -e DATABASE_URL=data/db-backup.sqlite3 \
     -e SIGNUPS_ALLOWED=false \
     -e WEB_VAULT_ENABLED=true \
     -p 127.0.0.1:8081:8080 \
     docker.io/vaultwarden/server:latest
   ```
2. In a browser: `http://localhost:8081/`. Log in with the operator's
   actual master password.
3. Verify one login from each cipher type opens and shows the right
   credential. Spot-check one Secure Note for content fidelity.
4. Stop: `podman stop vw-restore-test`.

### 6. Tear down

```sh
rm -rf /tmp/vaultwarden-restore /tmp/restic.env
# If you stood up a scratch Hetzner instance for the drill:
cd pulumi && pulumi -s drill destroy
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

## What "drill failed" actually means

| Failure mode                                            | What it tells you                                       | Action |
|---------------------------------------------------------|---------------------------------------------------------|--------|
| `restic restore` errors / index mismatch                | R2 corruption or repo metadata damage                   | Re-run `restic check --read-data` *immediately* against the prod env; check the latest restic-check ping for a missed alert |
| `PRAGMA integrity_check` not `ok`                       | The backup *script* uploaded a corrupt snapshot         | A pre-existing snapshot in R2 may also be bad; restore older snapshots one by one until one passes |
| DB counts way off                                       | Backups are running but missing data                    | Confirm the backup script's `--exclude` patterns aren't pulling in the live DB or skipping the snapshot path |
| Web login fails on the restored container               | KDF / master-password mismatch, or DB schema drift      | Verify the Vaultwarden image used in the test matches what wrote the snapshot; a major-version DB schema change can require an upgrade pass |

A failed drill is itself an early warning. Better to find it here than the
day a regional R2 outage forces you to restore for real.
