#!/usr/bin/env bash
# Vaultwarden backup driver.
#
# 1. SQLite .backup → consistent snapshot of the live, written-to DB without
#    blocking the writer. NOT a file copy of db.sqlite3 — that's racy in WAL
#    mode (the WAL file holds uncheckpointed writes), and no amount of locking
#    on the host fixes it.
#
# 2. restic backup → snapshot dir to the R2 repo, excluding the live DB triple
#    (db.sqlite3, -wal, -shm) and the running log file. Only the snapshot
#    copy is uploaded.
#
# 3. restic forget --prune → retention sweep.
#
# Environment (from /etc/vaultwarden/restic.env):
#   RESTIC_REPOSITORY, RESTIC_PASSWORD
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY     # R2 S3-compat creds
#
# Healthchecks success-ping is ExecStartPost on the systemd unit, not in this
# script. Script exit code drives unit success/failure → OnFailure email +
# Healthchecks missed-ping alert if it fails.

set -euo pipefail

: "${RESTIC_REPOSITORY:?required}"
: "${RESTIC_PASSWORD:?required}"

DATA_DIR=/data
DB=$DATA_DIR/db.sqlite3
DB_SNAPSHOT=$DATA_DIR/db-backup.sqlite3
TAG_HOST=$(hostname -s)

# .backup with a busy-timeout. SQLite returns SQLITE_BUSY if a writer holds
# the lock at the moment .backup is invoked — 30s is well above what
# Vaultwarden's single-user write rate produces.
sqlite3 "$DB" -cmd ".timeout 30000" ".backup $DB_SNAPSHOT"

# Quick integrity check on the snapshot itself before we ship it. A corrupt
# snapshot uploaded to R2 is a successful backup of garbage, which is worse
# than a failed backup.
sqlite3 "$DB_SNAPSHOT" "PRAGMA integrity_check;" | grep -qx "ok"

restic backup \
    --tag vaultwarden \
    --tag daily \
    --host "$TAG_HOST" \
    --exclude "$DB" \
    --exclude "$DB.wal" \
    --exclude "$DB.shm" \
    --exclude "$DATA_DIR/vaultwarden.log" \
    --exclude "$DATA_DIR/vaultwarden.log.*" \
    "$DATA_DIR"

# Retention: a week of dailies, a month of weeklies, a year of monthlies.
# Single-user vault; this is more than enough.
restic forget \
    --tag vaultwarden \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 12 \
    --prune
