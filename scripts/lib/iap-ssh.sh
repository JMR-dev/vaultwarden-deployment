# shellcheck shell=bash
# SSH to a stack's VM over IAP with OS Login: the pieces scripts/ansible-iap.sh
# and scripts/e2e-disposable.sh share. Source it; it only defines functions.
#
# The VM has no public SSH and no metadata SSH keys, so the caller supplies
# everything the connection needs:
#
#   1. An ephemeral ed25519 key, added to the CALLER's OS Login profile with a
#      1h TTL and removed again on exit. No long-lived SSH key exists anywhere.
#      The TTL is the backstop if the caller is killed before its trap runs.
#   2. A known_hosts built from the host keys the guest agent publishes as
#      guest attributes (pulumi/main.go sets enable-guest-attributes), read
#      through the authenticated Compute API. Host keys are pinned, never
#      trust-on-first-use, with StrictHostKeyChecking=yes.
#   3. `gcloud compute start-iap-tunnel` as the ProxyCommand. The VPC firewall
#      and host nftables admit :22 from the IAP range only.
#
# Usage, in order:
#
#   iap_ssh_init <name> <work-dir> <instance> <zone> <project>
#   trap iap_ssh_remove_key EXIT        # (or call it from the caller's trap)
#   iap_ssh_add_key <comment>
#   user="$(iap_ssh_username)"
#   iap_ssh_pin_host_keys
#   iap_ssh_wait "$user" || die "..."
#   iap_ssh "$user@<instance>" <command>
#
# <work-dir> must be a 0700 directory the caller owns and removes; the key,
# the known_hosts and ssh's error output live there. Nothing here prints a key
# or a fingerprint.
#
# Requires: gcloud (authenticated), ssh, ssh-keygen, jq.

# iap_die <message>: print "<name>: <message>" and exit the calling script
# (which runs its EXIT trap).
iap_die() {
  printf '%s: %s\n' "${iap_name:-iap-ssh}" "$*" >&2
  exit 1
}

iap_log() { printf '==> %s\n' "$*" >&2; }

# iap_ssh_init <name> <work-dir> <instance> <zone> <project>
# Sets the globals the other functions use, and iap_ssh_opts, the one ssh
# option set shared by every connection (and, as a string, by Ansible).
iap_ssh_init() {
  iap_name="$1"
  iap_work="$2"
  iap_instance="$3"
  iap_zone="$4"
  iap_project="$5"
  iap_key="${iap_work}/id"
  iap_known_hosts="${iap_work}/known_hosts"
  iap_key_added=0
  iap_proxy="gcloud compute start-iap-tunnel %h 22 --listen-on-stdin --zone=${iap_zone} --project=${iap_project} --verbosity=warning"
  iap_ssh_opts=(
    -o "ProxyCommand=${iap_proxy}"
    -o "UserKnownHostsFile=${iap_known_hosts}"
    -o StrictHostKeyChecking=yes
    -o IdentitiesOnly=yes
    -o ConnectTimeout=30
  )
}

# iap_ssh_add_key <comment>: make the ephemeral key and add it to the
# caller's OS Login profile for an hour.
iap_ssh_add_key() {
  ssh-keygen -q -t ed25519 -N '' -C "$1-$(date -u +%Y%m%dT%H%M%SZ)" -f "$iap_key"
  # Its output is the whole login profile, keys included: never shown.
  gcloud compute os-login ssh-keys add --key-file="${iap_key}.pub" --ttl=1h >/dev/null
  iap_key_added=1
}

# iap_ssh_remove_key: take the key off the profile again. Safe to call at any
# time, including before iap_ssh_add_key ran or twice.
iap_ssh_remove_key() {
  if [[ "${iap_key_added:-0}" == 1 ]]; then
    gcloud compute os-login ssh-keys remove --key-file="${iap_key}.pub" >/dev/null 2>&1 || true
    iap_key_added=0
  fi
}

# iap_ssh_username: print the caller's OS Login username. They're per profile
# (a service account's is sa_<id>). Prefer the POSIX account for this
# project; fall back to the primary one.
iap_ssh_username() {
  local profile user
  profile="$(gcloud compute os-login describe-profile --format=json)"
  user="$(jq -r --arg p "$iap_project" \
    '[.posixAccounts[]? | select(.accountId == $p)][0].username // .posixAccounts[0].username // empty' \
    <<<"$profile")"
  [[ -n "$user" ]] || iap_die "could not determine the OS Login username"
  printf '%s\n' "$user"
}

# iap_ssh_pin_host_keys: write known_hosts from the instance's guest
# attributes. On a fresh VM the guest agent needs a minute or two to publish
# them; allow ~5 minutes.
iap_ssh_pin_host_keys() {
  local hostkeys="${iap_work}/hostkeys"
  iap_log "Fetching ${iap_instance} SSH host keys from guest attributes"
  for _ in $(seq 1 60); do
    if gcloud compute instances get-guest-attributes "$iap_instance" \
         --zone "$iap_zone" --project "$iap_project" --query-path=hostkeys/ \
         --format='value(key,value)' >"$hostkeys" 2>/dev/null \
       && [[ -s "$hostkeys" ]]; then
      break
    fi
    sleep 5
  done
  [[ -s "$hostkeys" ]] || iap_die "no host keys published for ${iap_instance} (enable-guest-attributes missing, or the VM isn't up)"
  awk -v h="$iap_instance" 'NF == 2 {print h, $1, $2}' "$hostkeys" >"$iap_known_hosts"
}

# iap_ssh <ssh arguments...>: ssh with the shared options, the ephemeral key
# and no prompts. The caller adds <user>@<instance> and the command.
iap_ssh() {
  ssh -F /dev/null "${iap_ssh_opts[@]}" -i "$iap_key" -o BatchMode=yes "$@"
}

# iap_ssh_wait <user> [attempts]: wait until a trivial command succeeds, 10s
# apart (default 30 attempts). OS Login key propagation and a booting sshd can
# both lag. On the last failure it shows ssh's error and returns 1.
iap_ssh_wait() {
  local user="$1" attempts="${2:-30}" attempt
  iap_log "Waiting for SSH to ${iap_instance} as ${user} via IAP"
  for attempt in $(seq 1 "$attempts"); do
    if iap_ssh "${user}@${iap_instance}" true 2>"${iap_work}/ssh.err"; then
      return 0
    fi
    if [[ "$attempt" == "$attempts" ]]; then
      cat "${iap_work}/ssh.err" >&2
      return 1
    fi
    sleep 10
  done
}

# iap_ssh_ansible_args: print the options as one --ssh-common-args string.
# ansible-playbook re-splits it with shlex, so the ProxyCommand value carries
# its own quotes.
iap_ssh_ansible_args() {
  printf '%s\n' "-o 'ProxyCommand=${iap_proxy}' -o UserKnownHostsFile=${iap_known_hosts} -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"
}
