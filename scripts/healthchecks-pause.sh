#!/usr/bin/env bash
# Pause a stack's Healthchecks.io checks, so a stack that is gone on purpose
# (disposable between test cycles) doesn't alert. A paused check resumes on its
# next ping, so the next deploy brings them back with no other step.
#
#   scripts/healthchecks-pause.sh disposable
#
# Needs curl, jq, and the read-write API key of the jasonrossmedia.com
# Healthchecks project (prompted for, or HC_API_KEY in the environment). The
# checks are found by their tags, `vaultwarden <stack>`.
#
# The key never appears on a command line (where `ps` shows it): it reaches
# curl as a header file through a process substitution.

set -euo pipefail

STACK="${1:?usage: $0 <stack>}"
API=https://healthchecks.io/api/v3

if [[ -z "${HC_API_KEY:-}" ]]; then
  read -rsp "Healthchecks API key (read-write): " HC_API_KEY
  echo
fi

hc() { curl -fsS -H @<(printf 'X-Api-Key: %s\n' "$HC_API_KEY") "$@"; }

checks="$(hc "${API}/checks/?tag=vaultwarden&tag=${STACK}" | jq -r '.checks[] | "\(.update_url) \(.name)"')"
if [[ -z "$checks" ]]; then
  echo "no checks tagged 'vaultwarden ${STACK}'" >&2
  exit 1
fi
while read -r url name; do
  hc -X POST --data '' "${url}/pause" >/dev/null
  echo "paused ${name}"
done <<<"$checks"
