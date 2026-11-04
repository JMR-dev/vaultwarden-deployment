#!/usr/bin/env bash
# Run the site playbook against one stack's VM, over IAP with OS Login.
#
#   scripts/ansible-iap.sh <stack> [ansible-playbook args...]
#   scripts/ansible-iap.sh disposable -e caddy_image=.../caddy:disposable
#   scripts/ansible-iap.sh production --tags secrets,quadlets -e caddy_image=...
#
# Used identically by CI (deployer SA, key-activated gcloud) and by the
# operator (their own gcloud login). The VM has no public SSH and no metadata
# SSH keys; scripts/lib/iap-ssh.sh supplies everything the connection needs:
# an ephemeral OS Login key (1h TTL, removed on exit), host keys pinned from
# guest attributes, and `gcloud compute start-iap-tunnel` as the ProxyCommand.
#
# Requires: gcloud (authenticated), ssh, ssh-keygen, jq, ansible-playbook.

set -euo pipefail

die() { printf 'ansible-iap: %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*" >&2; }

[[ $# -ge 1 ]] || die "usage: $0 <stack> [ansible-playbook args...]"
stack="$1"
shift
[[ "$stack" =~ ^[a-z][a-z0-9]{1,15}$ ]] || die "bad stack name: $stack"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/iap-ssh.sh
source "${repo_root}/scripts/lib/iap-ssh.sh"

inventory="ansible/inventory/${stack}.yml"
[[ -f "${repo_root}/${inventory}" ]] || die "no inventory at ${inventory}"

project="${GCP_PROJECT:-vaultwarden-497422}"
# Some calls below (os-login ssh-keys) take no --project and need a default
# one. CI's setup action sets it; an operator's gcloud may not.
export CLOUDSDK_CORE_PROJECT="$project"
instance="vault-${stack}"
zone="$(awk '$1 == "gce_zone:" {print $2}' "${repo_root}/${inventory}")"
[[ -n "$zone" ]] || die "gce_zone missing from ${inventory}"

work="$(mktemp -d)"
chmod 0700 "$work"
iap_ssh_init ansible-iap "$work" "$instance" "$zone" "$project"
cleanup() {
  iap_ssh_remove_key
  rm -rf "$work"
}
trap cleanup EXIT

# 1. Ephemeral key on the caller's OS Login profile.
iap_ssh_add_key "ansible-iap-${stack}"
user="$(iap_ssh_username)"

# 2. Pinned host keys.
iap_ssh_pin_host_keys

# 3. Wait until a trivial command succeeds before handing over to Ansible.
iap_ssh_wait "$user" || die "SSH over IAP never came up"

cd "${repo_root}/ansible"
# Idempotent; a bare directory check isn't enough (an empty
# .collections/ansible_collections silently falls back to whatever the
# system Ansible bundles).
ansible-galaxy collection install -r requirements.yml -p .collections >/dev/null

log "Running playbook against ${stack}"
ansible-playbook -i "inventory/${stack}.yml" playbook.yml \
  -u "$user" --private-key "$iap_key" --ssh-common-args "$(iap_ssh_ansible_args)" "$@"
