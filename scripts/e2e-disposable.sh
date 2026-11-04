#!/usr/bin/env bash
# End-to-end checks of the disposable stack, run by deploy.yml's verify job
# right after `configure`. Everything in runbook §3 that can prove itself,
# the restore drill included; what stays manual is listed in the job summary.
#
#   scripts/e2e-disposable.sh
#
# It only ever tests vault-disposable: the name is fixed here, it refuses to
# run if STACK says anything else, and every command on the host first checks
# the hostname (scripts/lib/e2e-remote.sh). Its Google identity can't reach
# any other VM anyway (platform/main.go, grantE2E).
#
# One run step on purpose: each Actions step is its own exec stream, so a
# tunnel opened in one step would be gone by the next.
#
# What it touches, and what the EXIT trap puts back however far it got:
#   - an ephemeral OS Login key on this job's account (1h TTL; removed);
#   - an IAP tunnel to the VM's :443 on this machine's 127.0.0.1:443, which
#     only the browser uses (closed);
#   - a fail2ban ban of this runner's public address on the VM (unbanned);
#   - /data unmounted and fail2ban stopped by the mount guard (remounted,
#     restarted, with Vaultwarden and Alloy);
#   - the restore drill's /var/tmp/e2e-restore and its temporary container,
#     plus the `ssh -L` that reaches it (removed, shredded, closed);
#   - the signup window `configure` opened (closed, timer disarmed).
# It also leaves, by design: one account per run (e2e-<marker>@example.com)
# with one item, a backup snapshot, the signup-close mail to root, a
# Healthchecks ping from the backup, and a reboot of the VM.
#
# The run's master password is made here, masked in the job log with
# ::add-mask:: before any use, passed to Playwright in the environment only,
# and never printed or written to a file. A failed run uploads screenshots
# and the HTML report, but only after every error-context.md (which can hold
# a snapshot of the page, typed values included) is deleted and
# e2e/scan-secret.mjs finds the password in nothing that's left.
#
# Requires: gcloud (authenticated: Workload Identity in CI), ssh, ssh-keygen,
# jq, curl, getent, timeout, node and pnpm, and `pnpm install` done in e2e/.
# Must run as root (Playwright's container does), to listen on 127.0.0.1:443.

set -euo pipefail

die() {
  printf 'e2e-disposable: %s\n' "$*" >&2
  exit 1
}
log() { printf '==> %s\n' "$*" >&2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/iap-ssh.sh
source "${repo_root}/scripts/lib/iap-ssh.sh"
remote_lib="${repo_root}/scripts/lib/e2e-remote.sh"
e2e_dir="${repo_root}/e2e"
inventory="${repo_root}/ansible/inventory/disposable.yml"

# --- The target: disposable, and nothing else --------------------------------

instance=vault-disposable
if [[ -n "${STACK:-}" && "$STACK" != disposable ]]; then
  die "STACK is '${STACK}': this script only ever tests disposable"
fi
project=vaultwarden-497422
export CLOUDSDK_CORE_PROJECT="$project"
zone="$(awk '$1 == "gce_zone:" {print $2}' "$inventory")"
fqdn="$(awk '$1 == "vault_fqdn:" {print $2}' "$inventory")"
iap_range="$(awk '$1 == "iap_range:" {print $2}' "${repo_root}/ansible/group_vars/all.yml")"
[[ -n "$zone" && -n "$fqdn" && -n "$iap_range" ]] || die "gce_zone, vault_fqdn or iap_range missing from the inventory"
tunnel_port=443
restore_port=8444

for tool in gcloud ssh ssh-keygen jq curl getent timeout node pnpm; do
  command -v "$tool" >/dev/null || die "${tool} is not installed"
done
[[ -d "${e2e_dir}/node_modules" ]] || die "run 'pnpm install --frozen-lockfile' in e2e/ first"
[[ "$(id -u)" == 0 ]] || die "run as root: the tunnel listens on 127.0.0.1:443"

# --- This run's values ---------------------------------------------------------

started_at="$(date -u '+%Y-%m-%d %H:%M:%S')"
marker="${GITHUB_RUN_ID:-local}-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
email="e2e-${marker}@example.com"
password="$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
[[ ${#password} == 32 ]] || die "could not make a password"
# Masked before anything could print it.
printf '::add-mask::%s\n' "$password"
canary="E2E_NOTES_CANARY_${marker}"
attachment_canary="E2E_ATTACHMENT_CANARY_${marker}"
device_id="$(cat /proc/sys/kernel/random/uuid)"
# configure's start (deploy.yml passes it), for "since this deploy".
deploy_started="${DEPLOY_STARTED:-}"
deploy_started_note=""
if [[ ! "$deploy_started" =~ ^[0-9]+$ ]]; then
  deploy_started="$(($(date +%s) - 7200))"
  deploy_started_note="DEPLOY_STARTED was not set; checked the last two hours instead"
fi

# --- Results, for the job summary ----------------------------------------------

results=()
current=""
skips=()
check() {
  current="$1"
  log "$1"
}
passed() {
  results+=("pass|${current}|${1:-}")
  current=""
}
skipped() {
  results+=("skipped|$1|$2")
  skips+=("$1: $2")
}

# kv <key> <output>: the last value of key=value in a remote call's output.
# Always capture the call first (out="$(remote ...)"), so a failed call
# stops the run instead of yielding an empty value.
kv() { sed -n "s/^$1=//p" <<<"$2" | tail -n 1; }

# positive <value>: a whole number above zero.
positive() { [[ "$1" =~ ^[0-9]+$ ]] && (($1 > 0)); }

# --- Cleanup -------------------------------------------------------------------

work="$(mktemp -d "${RUNNER_TEMP:-/var/tmp}/e2e-disposable.XXXXXX")"
chmod 0700 "$work"
iap_ssh_init e2e-disposable "$work" "$instance" "$zone" "$project"
# The restore drill's `ssh -L` lives for minutes; notice a dead tunnel.
iap_ssh_opts+=(-o ServerAliveInterval=15 -o ServerAliveCountMax=4)
iap_user=""
ssh_ready=0
tunnel_pid=""
forward_pid=""
banned_ip=""
artifacts_note=""

on_exit() {
  local status=$?
  set +e
  if [[ "$status" != 0 && -n "$current" ]]; then
    results+=("FAILED|${current}|see the job log")
  fi
  if [[ "$ssh_ready" == 1 ]]; then
    log "Putting vault-disposable back (unban, /data, fail2ban, restore drill, signups)"
    # The host may be mid-reboot; give it up to ~3 minutes.
    iap_ssh_wait "$iap_user" 18 || log "SSH didn't come back; trying the cleanup anyway"
    if ! remote cleanup "$banned_ip"; then
      results+=("FAILED|cleanup on vault-disposable|see the job log; the signup timer and the 1h ban are the backstops")
      status=1
    fi
  fi
  [[ -n "$forward_pid" ]] && kill "$forward_pid" 2>/dev/null
  [[ -n "$tunnel_pid" ]] && kill "$tunnel_pid" 2>/dev/null
  iap_ssh_remove_key
  if [[ "$status" != 0 ]]; then
    prepare_artifacts
  fi
  write_summary "$status"
  rm -rf "$work"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# prepare_artifacts: what the workflow uploads on failure, in e2e/artifacts/:
# the HTML reports and the screenshots, never an error-context.md, and only
# if the password is in none of it.
prepare_artifacts() {
  local out="${e2e_dir}/artifacts" dirs=() dir scan=0
  rm -rf "$out"
  for dir in reports test-results; do
    [[ -d "${e2e_dir}/${dir}" ]] && dirs+=("$dir")
  done
  ((${#dirs[@]} > 0)) || return 0
  (cd "$e2e_dir" && find "${dirs[@]}" -name '*.md' -delete)
  (cd "$e2e_dir" && printf '%s\n' "$password" | node scan-secret.mjs "${dirs[@]}") || scan=$?
  if [[ "$scan" != 0 ]]; then
    (cd "$e2e_dir" && rm -rf reports test-results)
    artifacts_note="Withheld: the password scan exited ${scan} (1: found in the files named above; 2: couldn't read them)."
    return 0
  fi
  mkdir -p "$out"
  (cd "$e2e_dir" && { [[ ! -d reports ]] || cp -r reports "${out}/"; })
  (cd "$e2e_dir" && { [[ ! -d test-results ]] || find test-results -name '*.png' -exec cp --parents {} "$out" \; ; })
  artifacts_note="Uploaded as e2e-disposable-report: the HTML reports and screenshots (no traces, no error contexts)."
}

# write_summary <status>: the results table, what stays manual and this
# run's markers, to the job summary (if this runner has one) and the log.
write_summary() {
  local status="$1" verdict=passed line result name detail item
  [[ "$status" == 0 ]] || verdict=FAILED
  # The backticks are Markdown, not command substitution.
  # shellcheck disable=SC2016
  {
    printf '## Disposable end-to-end checks: %s\n\n' "$verdict"
    printf 'vault-disposable, %s to %s UTC, marker `%s`.\n\n' "$started_at" "$(date -u '+%Y-%m-%d %H:%M:%S')" "$marker"
    printf '| Result | Check | Detail |\n|---|---|---|\n'
    for line in "${results[@]}"; do
      IFS='|' read -r result name detail <<<"$line"
      printf '| %s | %s | %s |\n' "$result" "$name" "$detail"
    done
    if ((${#skips[@]} > 0)); then
      printf '\n### Skipped\n\n'
      for item in "${skips[@]}"; do
        printf -- '- %s\n' "$item"
      done
    fi
    if [[ -n "$deploy_started_note" ]]; then
      printf '\nNote: %s.\n' "$deploy_started_note"
    fi
    if [[ -n "$artifacts_note" ]]; then
      printf '\n%s\n' "$artifacts_note"
    fi
    printf '\n### Still manual (runbook §3)\n\n'
    printf -- '- §3.7a-d: the mail and Healthchecks paths.\n'
    printf -- '- §3.11a/b: the production-only-from-main guard and the replace guard.\n'
    printf -- '- §3.12 in watchtower (Grafana Explore, host `vault-disposable`, from %s UTC): nothing may match\n' "$started_at"
    printf -- '  `nobody-%s`, `not-a-password-%s` or `e2e-realip-%s`, nor any of the other queries in §3.12;\n' "$marker" "$marker" "$marker"
    printf -- '  `loki_process_custom_vaultwarden_failed_logins` should rise by 3 (those three logins).\n'
    printf -- "- The signup-close mail to root lists this run's account, \`%s\`.\n" "$email"
  } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" >&2
}

# --- Remote calls, tunnels and requests ---------------------------------------

# remote <function> [args...]: run one function of e2e-remote.sh on the host
# as root. The file and the call go in on stdin, so nothing reaches a command
# line there. Retries only when SSH itself failed (exit 255).
remote() {
  local attempt status
  for attempt in 1 2 3; do
    status=0
    {
      cat "$remote_lib"
      printf 'guard_disposable\n'
      printf '%q ' "$@"
      printf '\n'
    } | iap_ssh "${iap_user}@${instance}" sudo bash -s || status=$?
    [[ "$status" == 255 ]] || return "$status"
    log "  SSH failed (attempt ${attempt} of 3)"
    sleep 10
  done
  return 255
}

# port_open <host> <port>: a TCP connect within 5 seconds. The inner shell
# expands $0 and $1 itself, hence the single quotes.
# shellcheck disable=SC2016
port_open() { timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null; }

# wait_for_port <host> <port> <pid> <log>: until it accepts, while <pid> lives.
wait_for_port() {
  for _ in $(seq 1 90); do
    port_open "$1" "$2" && return 0
    if ! kill -0 "$3" 2>/dev/null; then
      cat "$4" >&2
      return 1
    fi
    sleep 1
  done
  return 1
}

# public <family> <address> <path> [curl args...]: HTTP status of a request to
# the vault's name pinned to its public address, never the tunnel.
public() {
  local family="$1" address="$2" path="$3"
  shift 3
  [[ "$address" == *:* ]] && address="[${address}]"
  curl "$family" -sS -o /dev/null -w '%{http_code}' -m 30 \
    --resolve "${fqdn}:443:${address}" "$@" "https://${fqdn}${path}"
}
public4() { public -4 "$public_v4" "$@"; }

# tunnel <path> [curl args...]: the same through the IAP tunnel, so it
# arrives at Caddy from IAP's range.
tunnel() {
  local path="$1"
  shift
  curl -sS -o /dev/null -w '%{http_code}' -m 30 \
    --resolve "${fqdn}:${tunnel_port}:127.0.0.1" "$@" "https://${fqdn}:${tunnel_port}${path}"
}

# failed_login <public4|tunnel> <username>: a password login that must fail,
# as the web vault sends it, with a made-up password hash.
failed_login() {
  "$1" /identity/connect/token -X POST -H 'Device-Type: 14' \
    --data-urlencode grant_type=password \
    --data-urlencode "username=$2" \
    --data-urlencode 'password=bm90LWEtcmVhbC1oYXNo' \
    --data-urlencode 'scope=api offline_access' \
    --data-urlencode client_id=web \
    --data-urlencode deviceType=14 \
    --data-urlencode "deviceIdentifier=${device_id}" \
    --data-urlencode deviceName=e2e
}

# public_refused: a request from this runner's (banned) address must not get
# through: refused (7), timed out (28) or reset (35, 56).
public_refused() {
  local code=0
  curl -4 -sS -o /dev/null --connect-timeout 10 -m 15 \
    --resolve "${fqdn}:443:${public_v4}" "https://${fqdn}/" 2>/dev/null || code=$?
  case "$code" in
    7 | 28 | 35 | 56) return 0 ;;
    0) log "  the request got through" ;;
    *) log "  curl failed with ${code}, which isn't a refusal" ;;
  esac
  return 1
}

# ipv4_in <address> <cidr>
ipv4_in() {
  local a b c d net bits address_n net_n mask
  IFS=. read -r a b c d <<<"$1"
  address_n=$(((a << 24) | (b << 16) | (c << 8) | d))
  net="${2%/*}"
  bits="${2#*/}"
  IFS=. read -r a b c d <<<"$net"
  net_n=$(((a << 24) | (b << 16) | (c << 8) | d))
  mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
  (((address_n & mask) == (net_n & mask)))
}

# a_public_ipv4 <address>: a dotted quad outside private, link-local,
# loopback, shared (CGNAT) and IAP's ranges.
a_public_ipv4() {
  local cidr
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 127.0.0.0/8 100.64.0.0/10 "$iap_range"; do
    if ipv4_in "$1" "$cidr"; then
      return 1
    fi
  done
}

# has_ipv6_route: a default IPv6 route on something other than loopback.
has_ipv6_route() {
  awk '$1 == "00000000000000000000000000000000" && $2 == "00" && $10 != "lo" {found = 1} END {exit !found}' \
    /proc/net/ipv6_route 2>/dev/null
}

# browser_tests <stage> <project>: one stage of the Playwright tests. The
# password goes in the environment (export is a shell builtin: no argument
# list). A page snapshot in error-context.md can show typed values, so those
# go at once.
browser_tests() {
  local stage="$1" project="$2" status=0
  (
    cd "$e2e_dir"
    export CI=1 PLAYWRIGHT_NO_COPY_PROMPT=1 E2E_STAGE="$stage"
    export E2E_VAULT_URL="https://${fqdn}" E2E_EMAIL="$email" E2E_PASSWORD="$password"
    export E2E_MARKER="$marker" E2E_CANARY="$canary" E2E_ATTACHMENT_CANARY="$attachment_canary"
    export E2E_RESTORE_URL="https://localhost:${restore_port}" E2E_RESTORE_SPKI="${restore_spki:-}"
    pnpm exec playwright test --project "$project"
  ) || status=$?
  find "${e2e_dir}/test-results" "${e2e_dir}/reports" -name '*.md' -delete 2>/dev/null || true
  return "$status"
}

# --- Setup ---------------------------------------------------------------------

log "Run ${marker}: account ${email}"
public_v4="$(getent ahostsv4 "$fqdn" | awk 'NR == 1 {print $1}' || true)"
public_v6="$(getent ahostsv6 "$fqdn" | awk '$1 !~ /^::ffff:/ {print $1; exit}' || true)"
[[ -n "$public_v4" ]] || die "${fqdn} has no IPv4 address in DNS"
log "${fqdn} is ${public_v4} and ${public_v6:-no IPv6} in public DNS"

check "SSH to vault-disposable over IAP, with an ephemeral OS Login key"
iap_ssh_add_key "e2e-disposable-${marker}"
iap_user="$(iap_ssh_username)"
iap_ssh_pin_host_keys
iap_ssh_wait "$iap_user" || die "SSH over IAP never came up"
ssh_ready=1
out="$(remote audit_log_size)"
audit_before="$(kv audit_bytes "$out")"
passed "as ${iap_user}, host keys pinned from guest attributes"

check "IAP tunnel to vault-disposable:443 on 127.0.0.1:${tunnel_port}"
gcloud compute start-iap-tunnel "$instance" 443 --local-host-port="127.0.0.1:${tunnel_port}" \
  --zone "$zone" --project "$project" >"${work}/tunnel.log" 2>&1 &
tunnel_pid=$!
wait_for_port 127.0.0.1 "$tunnel_port" "$tunnel_pid" "${work}/tunnel.log" || die "the tunnel to :443 never listened"
passed

# --- Registration first: the window `configure` opened is the clock -------------

check "runbook §2.8, §3.8, §3.10, §3.12: browser through the tunnel (register, log in, item, attachment, log out, a failed login)"
browser_tests vault vault
passed "account ${email}, item 'e2e canary ${marker}'"

check "runbook §3.12: a 'password' in the username field, through the tunnel"
status="$(failed_login tunnel "not-a-password-${marker}")" || die "the request through the tunnel failed (curl's error above)"
[[ "$status" == 400 ]] || die "the made-up login answered ${status}, not 400"
passed "not-a-password-${marker}: 400"

check "runbook §2.8 step 5, §3.3: registration and /admin are hidden publicly, while signups are open"
for path in /identity/accounts/register /identity/accounts/register/send-verification-email /api/accounts/register; do
  status="$(public4 "$path" -X POST -H 'Content-Type: application/json' --data '{}')" || die "public POST ${path} failed (curl's error above)"
  [[ "$status" == 404 ]] || die "public POST ${path} answered ${status}, not 404"
done
status="$(public4 /admin)" || die "public /admin failed (curl's error above)"
[[ "$status" == 404 ]] || die "public /admin answered ${status}, not 404"
if port_open "$public_v4" 22; then
  die "port 22 on ${public_v4} accepted a connection from the internet"
fi
admin_tunnel="$(tunnel /admin)" || die "/admin through the tunnel failed (curl's error above)"
[[ "$admin_tunnel" != 404 ]] || die "/admin through the IAP tunnel is 404: Caddy doesn't see IAP's address (runbook §3.4)"
passed "public: register 404, /admin 404, :22 closed; tunnel: /admin ${admin_tunnel}"

check "close the signup window and disarm its timer"
remote close_signups >/dev/null
passed "SIGNUPS_ALLOWED=false, timer removed"

# --- Public checks ---------------------------------------------------------------

check "runbook §3.2: TLS and the web vault over IPv4"
# curl checks the certificate against the system's CAs; a bad one is an error.
status="$(public4 /)" || die "https://${fqdn}/ over IPv4 failed (curl's error above)"
[[ "$status" == 200 ]] || die "https://${fqdn}/ over IPv4 answered ${status}"
passed "200, certificate verified"

if [[ -n "$public_v6" ]] && has_ipv6_route; then
  check "runbook §3.2: TLS and the web vault over IPv6"
  status="$(public -6 "$public_v6" /)" || die "https://${fqdn}/ over IPv6 failed (curl's error above)"
  [[ "$status" == 200 ]] || die "https://${fqdn}/ over IPv6 answered ${status}"
  passed "200, certificate verified"
else
  skipped "runbook §3.2 over IPv6" "this runner has no IPv6 route (or the name has no AAAA); check it by hand"
fi

check "runbook §3.4: Caddy and Vaultwarden see the runner's real address"
# The marker rides in the query string, which Caddy logs with the address.
status="$(public4 "/alive?e2e=${marker}")" || die "public /alive failed (curl's error above)"
[[ "$status" == 200 ]] || die "/alive answered ${status}"
out="$(remote runner_address "e2e=${marker}")"
runner_ip="$(kv remote_ip "$out")"
[[ "$(kv client_ip "$out")" == "$runner_ip" ]] || die "Caddy's client_ip differs from the TCP peer"
a_public_ipv4 "$runner_ip" || die "Caddy logged '${runner_ip}': a private, link-local or IAP address, not the runner's public one"
# The only failed login from this address all run: fail2ban bans at 5.
status="$(failed_login public4 "e2e-realip-${marker}@example.com")" || die "the public failed login failed (curl's error above)"
[[ "$status" == 400 ]] || die "the public failed login answered ${status}, not 400"
out="$(remote failed_login_address "e2e-realip-${marker}@example.com")"
log_ip="$(kv log_ip "$out")"
[[ "$log_ip" == "$runner_ip" ]] || die "vaultwarden.log has ${log_ip} for the failed login, Caddy has ${runner_ip}"
passed "${runner_ip} in Caddy's access log and vaultwarden.log"

# --- On the host -----------------------------------------------------------------

check "runbook §3.8: no plaintext canary on the data disk"
out="$(remote canary_hits "$canary" "$attachment_canary")"
hits="$(kv canary_hits "$out")"
[[ "$hits" == 0 ]] || die "the notes or attachment canary is on /data in plaintext ('${hits}' hits): client-side encryption is broken"
passed "0 hits in db.sqlite3*, db-backup.sqlite3 and attachments/, after a WAL checkpoint"

check "runbook §3.10: the WAF logged and didn't block"
out="$(remote audit_log_size)"
audit_after="$(kv audit_bytes "$out")"
positive "$audit_after" || die "coraza-audit.log is empty or missing"
[[ "$audit_after" != "$audit_before" ]] || die "coraza-audit.log didn't change during the run"
passed "uploads not refused (browser step); coraza-audit.log ${audit_before} -> ${audit_after} bytes"

check "runbook §3.12: telemetry on the host"
remote telemetry_checks "$deploy_started"
passed "handshake, Alloy ready, :2020, nft drop, no SECRET_VALUE, no restarts, /data denied"

check "runbook §3.5: a ban drops the runner's traffic and survives a ruleset reload"
banned_ip="$runner_ip"
out="$(remote f2b_ban "$runner_ip")"
before="$(kv f2b_lines "$out")"
positive "$(kv ip_listed "$out")" || die "the ban isn't in the nftables ruleset"
public_refused || die "a request from the banned address still got through"
out="$(remote nft_reload "$runner_ip")"
after="$(kv f2b_lines "$out")"
positive "$(kv ip_listed "$out")" || die "the ban was lost when main.nft was reloaded"
positive "$before" && [[ "$before" == "$after" ]] || die "fail2ban's ruleset lines went from '${before}' to '${after}' on reload"
public_refused || die "after the reload, the banned address got through"
# Unbanned here as well as in the trap: every Gitea runner shares this
# address, so keep the ban as short as the check.
remote f2b_unban "$runner_ip"
banned_ip=""
for _ in $(seq 1 15); do
  status="$(public4 / || true)"
  [[ "$status" == 200 ]] && break
  sleep 2
done
[[ "$status" == 200 ]] || die "after the unban, the runner still can't reach the vault (${status})"
passed "dropped, ${before} f2b lines before and after the reload, unbanned"

check "runbook §3.6: a backup now, and its snapshot is the newest"
out="$(remote backup_now)"
snapshot="$(kv snapshot "$out")"
passed "snapshot ${snapshot}"

check "restore drill (disposable): restore, integrity_check, counts, log in"
out="$(remote restore_start "$canary" "$attachment_canary")"
restore_spki="$(kv restore_spki "$out")"
[[ -n "$restore_spki" ]] || die "no certificate pin from the restore"
printf '::add-mask::%s\n' "$restore_spki"
for item in ciphers users attachments; do
  restored="$(kv "${item}_restored" "$out")"
  live="$(kv "${item}_live" "$out")"
  log "  ${item}: ${restored} restored, ${live} live"
  [[ -n "$restored" && "$restored" == "$live" ]] || die "${item}: ${restored} in the restored copy, ${live} live"
done
[[ "$(kv restored_canary_hits "$out")" == 0 ]] || die "the restored copy holds a plaintext canary"
iap_ssh -N -o ExitOnForwardFailure=yes -L "127.0.0.1:${restore_port}:127.0.0.1:${restore_port}" \
  "${iap_user}@${instance}" </dev/null 2>"${work}/forward.log" &
forward_pid=$!
wait_for_port 127.0.0.1 "$restore_port" "$forward_pid" "${work}/forward.log" || die "ssh -L to the restored copy never listened"
browser_tests restore restore
kill "$forward_pid" 2>/dev/null || true
forward_pid=""
remote restore_stop
passed "integrity ok, counts match live, logged in, canary item and attachment intact"

# --- Last, because it disrupts ---------------------------------------------------

check "runbook §3.9: podman auto-update and a reboot"
out="$(remote update_and_reboot)"
boot_before="$(kv boot_id "$out")"
sleep 30
iap_ssh_wait "$iap_user" 30 || die "SSH didn't come back after the reboot"
remote after_reboot "$boot_before"
for _ in $(seq 1 30); do
  status="$(public4 / || true)"
  [[ "$status" == 200 ]] && break
  sleep 4
done
[[ "$status" == 200 ]] || die "after the reboot, https://${fqdn}/ answers ${status} over IPv4"
if [[ -n "$public_v6" ]] && has_ipv6_route; then
  status="$(public -6 "$public_v6" / || true)"
  [[ "$status" == 200 ]] || die "after the reboot, https://${fqdn}/ answers ${status} over IPv6"
fi
passed "back up: /data, swap, IPv6 address, both containers, public HTTPS"

check "runbook §3.9: Vaultwarden refuses an empty /data"
remote mount_guard
remote alloy_sandbox
passed "start refused while unmounted; remounted, fail2ban and Vaultwarden back, Alloy still kept out of /data"

current=""
log "All checks passed"
