#!/usr/bin/env bash
# Create a fresh JSON key for the CI deployer SA, store it as the Gitea Actions
# repo secret GCP_DEPLOYER_KEY, then delete every older user-managed key.
# Also how the key is created the first time.
#
#   scripts/rotate-deployer-key.sh
#
# Run every 90 days (runbook §6). Needs: gcloud as the project owner, jq,
# curl, and a Gitea token with write access to the repo (prompted for, or
# GITEA_TOKEN in the environment).
#
# Why a key at all: Gitea 1.27 can't mint Actions OIDC tokens, so there is
# nothing for Workload Identity Federation to trust. The key's reach is capped
# by the deployer's grants in platform/main.go.
#
# The key and the token never appear on a command line (where `ps` shows
# them): the key goes file -> request body file, the token -> header file.
# Both live in a 0700 temp dir that is shredded on exit.

set -euo pipefail

PROJECT="${GCP_PROJECT:-vaultwarden-497422}"
SA="vaultwarden-deployer@${PROJECT}.iam.gserviceaccount.com"
GITEA_URL="${GITEA_URL:-https://gitea.jasonmross.dev}"
REPO="${GITEA_REPO:-JMR-dev/vaultwarden-deployment}"
SECRET_NAME=GCP_DEPLOYER_KEY

if [[ -z "${GITEA_TOKEN:-}" ]]; then
  read -rsp "Gitea token with write access to ${REPO}: " GITEA_TOKEN
  echo
fi
[[ -n "$GITEA_TOKEN" ]] || { echo "no token" >&2; exit 1; }

work="$(mktemp -d)"
chmod 0700 "$work"
cleanup() {
  find "$work" -type f -exec shred -u {} + 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
umask 077

printf 'Authorization: token %s\n' "$GITEA_TOKEN" >"${work}/auth-header"
unset GITEA_TOKEN

echo "==> Creating a new key for ${SA}"
gcloud iam service-accounts keys create "${work}/key.json" \
  --iam-account "$SA" --project "$PROJECT" --quiet
new_id="$(jq -r .private_key_id "${work}/key.json")"

echo "==> Storing it as ${SECRET_NAME} on ${REPO}"
jq -n --rawfile data "${work}/key.json" '{data: $data}' >"${work}/body.json"
status="$(curl -sS -o "${work}/response" -w '%{http_code}' -X PUT \
  -H @"${work}/auth-header" -H 'Content-Type: application/json' \
  --data @"${work}/body.json" \
  "${GITEA_URL}/api/v1/repos/${REPO}/actions/secrets/${SECRET_NAME}")"
if [[ "$status" != 201 && "$status" != 204 ]]; then
  echo "Gitea returned HTTP ${status}; deleting the new key so it doesn't linger" >&2
  cat "${work}/response" >&2 || true
  gcloud iam service-accounts keys delete "$new_id" --iam-account "$SA" --project "$PROJECT" --quiet
  exit 1
fi

echo "==> Deleting older user-managed keys"
while read -r id; do
  [[ -z "$id" || "$id" == "$new_id" ]] && continue
  gcloud iam service-accounts keys delete "$id" --iam-account "$SA" --project "$PROJECT" --quiet
  echo "    deleted ${id}"
done < <(gcloud iam service-accounts keys list --iam-account "$SA" --project "$PROJECT" \
           --managed-by user --format='value(name.basename())')

echo "Done. Active key: ${new_id}. Any deploy already running keeps the old key and may fail; re-run it."
