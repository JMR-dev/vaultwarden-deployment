#!/usr/bin/env bash
# Run the site playbook against one stack's VM, over IAP with OS Login.
#
#   scripts/ansible-iap.sh <stack> [ansible-playbook args...]
#   scripts/ansible-iap.sh disposable -e caddy_image=.../caddy:disposable
#   scripts/ansible-iap.sh production --tags secrets,quadlets -e caddy_image=...
#
# Used identically by CI (deployer SA, key-activated gcloud) and by the
# operator (their own gcloud login). The VM has no public SSH and no metadata
# SSH keys, so this script supplies everything the connection needs:
#
#   1. An ephemeral ed25519 key, added to the CALLER's OS Login profile with a
#      1h TTL and removed again on exit. No long-lived SSH key exists anywhere.
#   2. A known_hosts built from the host keys the guest agent publishes as
#      guest attributes (pulumi/main.go sets enable-guest-attributes), read
#      through the authenticated Compute API. Host keys are pinned, never
#      trust-on-first-use, with StrictHostKeyChecking=yes.
#   3. `gcloud compute start-iap-tunnel` as the ProxyCommand. The VPC firewall
#      and host nftables admit :22 from the IAP range only.
#
# Requires: gcloud (authenticated), ssh, ssh-keygen, ansible-playbook.

set -euo pipefail

die() { printf 'ansible-iap: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

[[ $# -ge 1 ]] || die "usage: $0 <stack> [ansible-playbook args...]"
stack="$1"
shift
[[ "$stack" =~ ^[a-z][a-z0-9]{1,15}$ ]] || die "bad stack name: $stack"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="ansible/inventory/${stack}.yml"
[[ -f "${repo_root}/${inventory}" ]] || die "no inventory at ${inventory}"

project="${GCP_PROJECT:-vaultwarden-497422}"
instance="vault-${stack}"
zone="$(awk '$1 == "gce_zone:" {print $2}' "${repo_root}/${inventory}")"
[[ -n "$zone" ]] || die "gce_zone missing from ${inventory}"

work="$(mktemp -d)"
chmod 0700 "$work"
key_added=0
cleanup() {
  if [[ "$key_added" == 1 ]]; then
    gcloud compute os-login ssh-keys remove --key-file="${work}/id.pub" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# 1. Ephemeral key on the caller's OS Login profile. The TTL is the backstop
#    if this script is killed before the trap runs.
ssh-keygen -q -t ed25519 -N '' -C "ansible-iap-${stack}-$(date -u +%Y%m%dT%H%M%SZ)" -f "${work}/id"
gcloud compute os-login ssh-keys add --key-file="${work}/id.pub" --ttl=1h >/dev/null
key_added=1

# OS Login usernames are per-profile (a service account's is sa_<id>). Prefer
# the POSIX account for this project; fall back to the primary one.
profile="$(gcloud compute os-login describe-profile --format=json)"
user="$(jq -r --arg p "$project" \
  '[.posixAccounts[]? | select(.accountId == $p)][0].username // .posixAccounts[0].username // empty' \
  <<<"$profile")"
[[ -n "$user" ]] || die "could not determine the OS Login username"

# 2. Pinned host keys. On a fresh VM the guest agent needs a minute or two to
#    publish them; allow ~5 minutes.
log "Fetching ${instance} SSH host keys from guest attributes"
for _ in $(seq 1 60); do
  if gcloud compute instances get-guest-attributes "$instance" \
       --zone "$zone" --project "$project" --query-path=hostkeys/ \
       --format='value(key,value)' >"${work}/hostkeys" 2>/dev/null \
     && [[ -s "${work}/hostkeys" ]]; then
    break
  fi
  sleep 5
done
[[ -s "${work}/hostkeys" ]] || die "no host keys published for ${instance} (enable-guest-attributes missing, or the VM isn't up)"
awk -v h="$instance" 'NF == 2 {print h, $1, $2}' "${work}/hostkeys" >"${work}/known_hosts"

# 3. One ssh option set, shared by the readiness probe and Ansible.
proxy="gcloud compute start-iap-tunnel %h 22 --listen-on-stdin --zone=${zone} --project=${project} --verbosity=warning"
ssh_opts=(
  -o "ProxyCommand=${proxy}"
  -o "UserKnownHostsFile=${work}/known_hosts"
  -o StrictHostKeyChecking=yes
  -o IdentitiesOnly=yes
  -o ConnectTimeout=30
)

# OS Login key propagation and first-boot sshd can both lag; wait until a
# trivial command succeeds before handing over to Ansible.
log "Waiting for SSH to ${instance} as ${user} via IAP"
for attempt in $(seq 1 30); do
  if ssh -F /dev/null "${ssh_opts[@]}" -i "${work}/id" -o BatchMode=yes \
       "${user}@${instance}" true 2>"${work}/ssh.err"; then
    break
  fi
  [[ "$attempt" == 30 ]] && { cat "${work}/ssh.err" >&2; die "SSH over IAP never came up"; }
  sleep 10
done

cd "${repo_root}/ansible"
# Idempotent; a bare directory check isn't enough (an empty
# .collections/ansible_collections silently falls back to whatever the
# system Ansible bundles).
ansible-galaxy collection install -r requirements.yml -p .collections >/dev/null

# ansible-playbook re-splits --ssh-common-args with shlex, so the
# ProxyCommand value carries its own quotes.
common="-o 'ProxyCommand=${proxy}' -o UserKnownHostsFile=${work}/known_hosts -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes"

log "Running playbook against ${stack}"
ansible-playbook -i "inventory/${stack}.yml" playbook.yml \
  -u "$user" --private-key "${work}/id" --ssh-common-args "$common" "$@"
