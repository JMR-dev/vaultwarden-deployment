# shellcheck shell=bash
# What scripts/e2e-disposable.sh runs ON vault-disposable. It isn't run as a
# file: e2e-disposable.sh sends this file plus one call line to
# `sudo bash -s` over SSH, so nothing from here reaches a command line on the
# host or sudo's log (that shows only `/bin/bash -s`).
#
# Every call starts with guard_disposable. Nothing here prints a secret: the
# restic credentials are sourced inside a shell and never echoed, and the
# only key-derived value printed is the restore drill's throwaway SPKI pin,
# which the caller captures and masks.
#
# Conventions: results go to stdout as key=value lines for the caller to
# parse; progress and errors go to stderr, which the job log shows.

set -euo pipefail
# The SSH user's home may be closed to the vaultwarden user, whom several
# steps run as.
cd /

vault_user=vaultwarden
vault_uid=1100
data=/data
vault_env=/var/lib/vaultwarden/vaultwarden.env
caddy_logs=/var/lib/vaultwarden/caddy/logs
signups_timer=/etc/systemd/system/vaultwarden-signups-close.timer

# The restore drill's temporary Vaultwarden. It runs rootless as the
# vaultwarden user (the only account with subuids), from the image the real
# one runs, published on the host's loopback only.
restore_dir=/var/tmp/e2e-restore
restore_name=vw-e2e-restore
restore_port=8444

fail() {
  printf 'vault-disposable: %s\n' "$*" >&2
  exit 1
}
note() { printf '  [host] %s\n' "$*" >&2; }

as_vault() { runuser -u "$vault_user" -- "$@"; }
vault_podman() {
  as_vault env XDG_RUNTIME_DIR="/run/user/${vault_uid}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${vault_uid}/bus" podman "$@"
}
vault_systemctl() { systemctl --user -M "${vault_user}@" "$@"; }

# Every entry point runs this first: the third gate, after the workflow's
# `if:` and the script's own refusal, and the only one on the host itself.
guard_disposable() {
  local name
  name="$(hostname -s)"
  [[ "$name" == vault-disposable ]] || fail "this host is ${name}, not vault-disposable: refusing"
}

# restic, as the vaultwarden user with the host's own credentials. The env
# file is sourced inside that shell, so its values never reach an argument.
vault_restic() {
  as_vault bash -c 'set -euo pipefail; set -a; . /etc/vaultwarden/restic.env; set +a; exec restic "$@"' restic "$@"
}

# --- Read-only checks -------------------------------------------------------

boot_id() { printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"; }

audit_log_size() {
  local log="${caddy_logs}/coraza-audit.log"
  printf 'audit_bytes=%s\n' "$(stat -c %s "$log" 2>/dev/null || echo 0)"
}

# runner_address <marker>: the client address Caddy logged for the request
# whose URI carries <marker>, both as the TCP peer and as Caddy's client_ip.
runner_address() {
  local marker="$1" line
  line="$(grep -F -- "$marker" "${caddy_logs}/access.log" | tail -n 1 || true)"
  [[ -n "$line" ]] || fail "no request carrying the marker in Caddy's access log"
  printf 'remote_ip=%s\n' "$(jq -r '.request.remote_ip' <<<"$line")"
  printf 'client_ip=%s\n' "$(jq -r '.request.client_ip' <<<"$line")"
}

# failed_login_address <username>: the IP: field of Vaultwarden's
# failed-login line for <username>.
failed_login_address() {
  local username="$1" line
  line="$(grep -F -- "Username: ${username}." "${data}/vaultwarden.log" | tail -n 1 || true)"
  [[ -n "$line" ]] || fail "no failed-login line for the marker in ${data}/vaultwarden.log"
  printf 'log_ip=%s\n' "$(sed -E 's/.* IP: ([^ ]+)\. Username: .*/\1/' <<<"$line")"
}

# canary_hits <notes canary> <attachment canary>: plaintext copies of either
# on the data disk. Checkpoint the WAL first (as the vaultwarden user, so no
# file changes owner), then count across the live database's files, the
# backup copy and the attachments.
canary_hits() {
  local notes="$1" attachment="$2" total=0 count file
  if [[ -e "${data}/db.sqlite3-wal" ]]; then
    as_vault sqlite3 "${data}/db.sqlite3" -cmd '.timeout 30000' 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null
  fi
  for file in "${data}"/db.sqlite3 "${data}"/db.sqlite3-wal "${data}"/db.sqlite3-shm "${data}"/db-backup.sqlite3; do
    [[ -e "$file" ]] || continue
    count="$(grep -a -c -F -e "$notes" -e "$attachment" "$file" || true)"
    total=$((total + count))
  done
  if [[ -d "${data}/attachments" ]]; then
    count="$(grep -r -a -l -F -e "$notes" -e "$attachment" "${data}/attachments" | wc -l)"
    total=$((total + count))
  fi
  printf 'canary_hits=%s\n' "$total"
}

# telemetry_checks <epoch the deploy started>: runbook §3.12's host block.
# Runs every check, then fails listing the ones that didn't hold.
telemetry_checks() {
  local since="$1" failed=() handshake now restarts state metrics secrets
  now="$(date +%s)"

  handshake="$(wg show wg-watchtower latest-handshakes 2>/dev/null | awk 'NR == 1 {print $2}' || true)"
  if [[ "${handshake:-0}" =~ ^[0-9]+$ ]] && ((handshake > 0 && now - handshake < 600)); then
    note "tunnel handshake $((now - handshake))s ago"
  else
    failed+=("no WireGuard handshake with watchtower in the last 10 minutes (got '${handshake:-none}')")
  fi

  if curl -fsS -m 10 -o /dev/null http://127.0.0.1:12345/-/ready; then
    note "Alloy ready"
  else
    failed+=("Alloy's /-/ready didn't answer")
  fi

  metrics="$(curl -fsS -m 10 http://127.0.0.1:2020/metrics 2>/dev/null | grep -c '^caddy_' || true)"
  if ((metrics > 0)); then
    note "Caddy metrics on 127.0.0.1:2020: ${metrics} lines"
  else
    failed+=("no caddy_ metrics on 127.0.0.1:2020")
  fi

  if nft list chain inet vaultwarden_filter input | grep -q 'iifname "wg-watchtower".* drop'; then
    note "nftables drops what comes in on wg-watchtower"
  else
    failed+=("the input chain has no drop for wg-watchtower")
  fi

  secrets="$(journalctl -t sudo --since "@${since}" -o cat 2>/dev/null | grep -c SECRET_VALUE || true)"
  if ((secrets == 0)); then
    note "no SECRET_VALUE in sudo's lines since the deploy"
  else
    failed+=("${secrets} sudo line(s) since the deploy hold SECRET_VALUE (runbook §9, 'No telemetry from a host')")
  fi

  state="$(systemctl show alloy -p ActiveState --value)"
  restarts="$(systemctl show alloy -p NRestarts --value)"
  if [[ "$state" == active && "$restarts" == 0 ]]; then
    note "Alloy active, never restarted"
  else
    failed+=("Alloy is ${state} with ${restarts} restart(s)")
  fi

  alloy_cannot_see_data || failed+=("Alloy can see ${data}")

  if ((${#failed[@]} > 0)); then
    printf '  [host] FAILED: %s\n' "${failed[@]}" >&2
    fail "runbook §3.12 host checks: ${#failed[@]} failed"
  fi
}

# alloy_cannot_see_data: in Alloy's own mount namespace and as its user,
# listing /data must be refused (alloy.service's InaccessiblePaths=).
alloy_cannot_see_data() {
  local pid view
  pid="$(systemctl show alloy -p MainPID --value)"
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { note "Alloy has no main process"; return 1; }
  view="$(nsenter -t "$pid" -m -S "$(id -u alloy)" -G "$(id -g alloy)" ls "$data" 2>&1 || true)"
  if [[ "$view" == *"Permission denied"* ]]; then
    note "Alloy's view of ${data}: Permission denied"
    return 0
  fi
  note "Alloy's view of ${data} was not refused"
  return 1
}

# alloy_sandbox: the same check on its own, for after the mount guard.
alloy_sandbox() {
  alloy_cannot_see_data || fail "Alloy can see ${data} after the remount"
}

# --- Signups ----------------------------------------------------------------

# close_signups: what a signups=false deploy does, by hand. The closer flips
# SIGNUPS_ALLOWED, restarts Vaultwarden (it's health-gated, so this returns
# once it serves again) and mails root the account list; it doesn't disarm
# its own timer, so that's done here as the quadlets role does. Idempotent:
# on a closed window with no timer it does nothing.
close_signups() {
  if grep -qx 'SIGNUPS_ALLOWED=true' "$vault_env"; then
    note "closing the signup window"
    /usr/local/sbin/vaultwarden-signups-close
  fi
  if [[ -e "$signups_timer" ]]; then
    note "disarming the signup-window timer"
    systemctl disable --now vaultwarden-signups-close.timer
    rm -f "$signups_timer"
    systemctl daemon-reload
  fi
  grep -qx 'SIGNUPS_ALLOWED=false' "$vault_env" || fail "SIGNUPS_ALLOWED is not false after closing"
  [[ ! -e "$signups_timer" ]] || fail "the signup-window timer is still there"
  printf 'signups=closed\n'
}

# --- fail2ban ---------------------------------------------------------------

# f2b_state <ip>: lines in the ruleset that mention fail2ban, and whether
# <ip> is in it (as runbook §3.5 counts them).
f2b_state() {
  local ip="$1" ruleset
  ruleset="$(nft list ruleset)"
  printf 'f2b_lines=%s\n' "$(grep -c f2b <<<"$ruleset" || true)"
  printf 'ip_listed=%s\n' "$(grep -cF -- "$ip" <<<"$ruleset" || true)"
}

f2b_ban() {
  fail2ban-client set vaultwarden banip "$1" >/dev/null
  f2b_state "$1"
}

f2b_unban() { fail2ban-client set vaultwarden unbanip "$1" >/dev/null 2>&1 || true; }

# nft_reload <ip>: what every Ansible run does (never systemctl
# reload|restart nftables, runbook §9), then the state again.
nft_reload() {
  nft -f /etc/nftables/main.nft
  f2b_state "$1"
}

# --- Backup and restore -----------------------------------------------------

# backup_now: run the backup (oneshot, so this blocks until it's done) and
# show that the newest snapshot is from just now.
backup_now() {
  local started snapshot taken
  started="$(date +%s)"
  note "running vaultwarden-backup.service"
  systemctl start vaultwarden-backup.service
  snapshot="$(vault_restic snapshots --no-lock --latest 1 --json | jq -c 'max_by(.time)')"
  taken="$(date -d "$(jq -r .time <<<"$snapshot")" +%s)"
  ((taken >= started - 5)) || fail "the newest snapshot ($(jq -r .short_id <<<"$snapshot")) is older than this backup"
  printf 'snapshot=%s\n' "$(jq -r .short_id <<<"$snapshot")"
}

# sql_count <database> <table>, read-only, as the vaultwarden user.
sql_count() { as_vault sqlite3 -readonly "$1" "SELECT COUNT(*) FROM $2;"; }

# restore_start <notes canary> <attachment canary>: restore the newest
# snapshot to /var/tmp, check it, and serve it on 127.0.0.1:8444 with a
# throwaway certificate. Prints counts and, last, the certificate's SPKI pin.
restore_start() {
  local notes="$1" attachment="$2" restored integrity image item canary_files
  restore_stop
  install -d -m 0700 -o "$vault_user" -g "$vault_user" "$restore_dir" "${restore_dir}/tls"

  note "restoring the newest snapshot to ${restore_dir}"
  vault_restic restore --no-lock latest --target "${restore_dir}/restore" >/dev/null
  restored="${restore_dir}/restore${data}/db-backup.sqlite3"
  [[ -f "$restored" ]] || fail "the snapshot holds no db-backup.sqlite3"

  integrity="$(as_vault sqlite3 "$restored" 'PRAGMA integrity_check;')"
  [[ "$integrity" == ok ]] || fail "integrity_check of the restored database: ${integrity}"
  for item in ciphers users attachments; do
    printf '%s_restored=%s\n' "$item" "$(sql_count "$restored" "$item")"
    printf '%s_live=%s\n' "$item" "$(sql_count "${data}/db.sqlite3" "$item")"
  done
  canary_files="$(grep -r -a -l -F -e "$notes" -e "$attachment" "${restore_dir}/restore" | wc -l)"
  printf 'restored_canary_hits=%s\n' "$canary_files"

  # The web vault needs a secure origin, so the temporary server speaks
  # HTTPS with a certificate made here and shredded by restore_stop.
  as_vault openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    -keyout "${restore_dir}/tls/key.pem" -out "${restore_dir}/tls/cert.pem" 2>/dev/null

  # The image the live Vaultwarden runs, so the drill reads the snapshot
  # with the code that wrote it.
  image="$(vault_podman inspect --format '{{.Image}}' vaultwarden)"
  note "starting ${restore_name} on 127.0.0.1:${restore_port}"
  # Logs to a file in its own storage (gone with --rm), not the journal, so
  # nothing from it ships to watchtower.
  vault_podman run -d --rm --name "$restore_name" --log-driver k8s-file \
    -p "127.0.0.1:${restore_port}:${restore_port}" \
    -v "${restore_dir}/restore${data}:/data:Z" \
    -v "${restore_dir}/tls:/ssl:ro,Z" \
    -e DATA_FOLDER=/data \
    -e DATABASE_URL=sqlite:///data/db-backup.sqlite3 \
    -e SIGNUPS_ALLOWED=false \
    -e INVITATIONS_ALLOWED=false \
    -e WEB_VAULT_ENABLED=true \
    -e ROCKET_PORT="$restore_port" \
    -e 'ROCKET_TLS={certs="/ssl/cert.pem",key="/ssl/key.pem"}' \
    -e DOMAIN="https://localhost:${restore_port}" \
    "$image" >/dev/null
  for _ in $(seq 1 60); do
    if curl -fsk -m 5 -o /dev/null "https://127.0.0.1:${restore_port}/alive"; then
      break
    fi
    sleep 2
  done
  curl -fsk -m 5 -o /dev/null "https://127.0.0.1:${restore_port}/alive" || {
    vault_podman logs --tail 30 "$restore_name" >&2 || true
    fail "${restore_name} never answered on 127.0.0.1:${restore_port}"
  }
  printf 'restore_spki=%s\n' "$(openssl x509 -in "${restore_dir}/tls/cert.pem" -pubkey -noout |
    openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
}

# restore_stop: remove the temporary server and shred everything restored.
# Safe when nothing was started.
restore_stop() {
  vault_podman rm -f --time 10 "$restore_name" >/dev/null 2>&1 || true
  if [[ -d "$restore_dir" ]]; then
    find "$restore_dir" -type f -exec shred -u {} +
    rm -rf "$restore_dir"
  fi
}

# --- Reboot and the mount guard ---------------------------------------------

# update_and_reboot: runbook §3.9's podman auto-update, then a reboot a few
# seconds from now, so this SSH session ends cleanly first.
update_and_reboot() {
  note "podman auto-update"
  vault_systemctl start podman-auto-update.service
  # Already scheduled if this is a retry after a dropped connection.
  systemd-run --quiet --on-active=5s --unit=e2e-reboot /usr/bin/systemctl reboot ||
    note "e2e-reboot was already scheduled"
  boot_id
}

# after_reboot <boot id before>: the host came back as it should.
after_reboot() {
  local before="$1" now failed=()
  now="$(cat /proc/sys/kernel/random/boot_id)"
  [[ "$now" != "$before" ]] || fail "the boot id didn't change: no reboot happened"
  findmnt -n -o FSTYPE "$data" | grep -qx ext4 || failed+=("${data} is not the ext4 data disk")
  swapon --show=NAME --noheadings | grep -qx /swapfile || failed+=("/swapfile is not swapped on")
  [[ -n "$(ip -6 addr show scope global)" ]] || failed+=("no global IPv6 address (DHCPv6)")
  # Linger starts both at boot; Vaultwarden is health-gated, so give it time.
  for _ in $(seq 1 36); do
    vault_systemctl is-active --quiet vaultwarden.service caddy.service && break
    sleep 5
  done
  vault_systemctl is-active --quiet vaultwarden.service || failed+=("vaultwarden.service is not active")
  vault_systemctl is-active --quiet caddy.service || failed+=("caddy.service is not active")
  grep -qx 'SIGNUPS_ALLOWED=false' "$vault_env" || failed+=("signups are open after the reboot")
  if ((${#failed[@]} > 0)); then
    printf '  [host] FAILED: %s\n' "${failed[@]}" >&2
    fail "runbook §3.9 after the reboot: ${#failed[@]} failed"
  fi
  note "after the reboot: ${data} mounted, swap on, IPv6 up, both containers active"
}

# mount_guard: runbook §3.9's empty-/data guard. With /data unmounted,
# Vaultwarden must refuse to start. Then put everything back, and restart
# Alloy: the remount reaches its private mount namespace without the
# InaccessiblePaths= cover, so until it restarts it could see /data.
mount_guard() {
  local refused=0
  vault_systemctl stop vaultwarden.service
  systemctl stop fail2ban.service # it holds ${data}/vaultwarden.log open
  if ! umount "$data"; then
    note "what holds ${data} open: $(lsof -n "$data" 2>/dev/null | awk 'NR > 1 {print $1}' | sort -u | tr '\n' ' ')"
    restore_services
    fail "could not unmount ${data}"
  fi
  if vault_systemctl start vaultwarden.service 2>/dev/null; then
    refused=0
  else
    refused=1
  fi
  vault_systemctl stop vaultwarden.service 2>/dev/null || true
  vault_systemctl reset-failed vaultwarden.service 2>/dev/null || true
  restore_services
  ((refused == 1)) || fail "Vaultwarden started with ${data} unmounted"
  note "Vaultwarden refused to start on an empty ${data}, and is back"
}

# restore_services: /data mounted, fail2ban and Vaultwarden running, Alloy
# restarted if /data was remounted. Idempotent; the mount guard and the
# cleanup both end with it.
restore_services() {
  if ! mountpoint -q "$data"; then
    mount "$data"
    systemctl restart alloy.service 2>/dev/null || true
  fi
  systemctl is-active --quiet fail2ban.service || systemctl start fail2ban.service
  if ! vault_systemctl is-active --quiet vaultwarden.service; then
    vault_systemctl reset-failed vaultwarden.service 2>/dev/null || true
    vault_systemctl start vaultwarden.service
  fi
}

# --- Cleanup ----------------------------------------------------------------

# cleanup [banned ip]: put the host back however far the run got. Every part
# is safe when its step never started, and one failing doesn't stop the rest.
cleanup() {
  local ip="${1:-}" status=0
  if [[ -n "$ip" ]]; then
    f2b_unban "$ip"
    note "unbanned the runner's address"
  fi
  restore_services || { note "could not bring /data, fail2ban or Vaultwarden back"; status=1; }
  restore_stop || { note "could not remove the restore drill's files"; status=1; }
  close_signups >/dev/null || { note "could not close signups"; status=1; }
  return "$status"
}
