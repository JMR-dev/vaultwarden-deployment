#!/usr/bin/env bash
# One-time, idempotent GCP bootstrap for the pieces Pulumi can't (or mustn't)
# own. Safe to re-run; every step checks before it creates.
#
#   scripts/bootstrap-gcp.sh [project] [region]
#
# What it does, and why it isn't Pulumi:
#   - Enables the APIs both Pulumi projects call. The KMS key below has to
#     exist before either stack can be initialised, so this can't wait for a
#     Pulumi-managed `projects.Service`.
#   - Creates the KMS key both stacks use as their secrets provider
#     (gcpkms://...). KMS keys can never be deleted, only their versions, so
#     there is nothing for `pulumi destroy` to usefully own here.
#   - Creates gs://<project>-platform-state, the owner-only state bucket for
#     platform/. It is separate from the app state bucket so the CI deployer
#     (objectAdmin on the app bucket) can't read or rewrite platform state.
#   - Creates every secret in secrets/secret-names.txt as an empty container,
#     so platform/ can grant access by id before any value exists. Secrets stay
#     out of Pulumi so `pulumi destroy` can never take them.
#
# Pre-existing and left alone: the app state bucket
# gs://<project>-pulumi-state and the Cloud DNS zone `vault` (both gcloud-made).

set -euo pipefail

PROJECT="${1:-vaultwarden-497422}"
REGION="${2:-us-east1}"
KEYRING=pulumi
KEY=stacks
PLATFORM_BUCKET="gs://${PROJECT}-platform-state"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secret_names="${repo_root}/secrets/secret-names.txt"

owner="$(gcloud config get-value account 2>/dev/null)"
[[ -n "$owner" ]] || { echo "gcloud has no active account; run gcloud auth login" >&2; exit 1; }

log() { printf '==> %s\n' "$*"; }

# IAM is eventually consistent and policy writes are read-modify-write, so a
# binding right after a create can fail with "does not exist" or a concurrent
# modification error. Retry those; fail on anything else.
retry_iam() {
  local attempt out
  for attempt in 1 2 3 4 5 6; do
    if out="$("$@" 2>&1)"; then
      return 0
    fi
    if grep -qiE 'does not exist|concurrent|409|There were concurrent policy changes' <<<"$out"; then
      sleep $((attempt * 5))
      continue
    fi
    printf '%s\n' "$out" >&2
    return 1
  done
  printf '%s\n' "$out" >&2
  return 1
}

log "Enabling APIs on ${PROJECT}"
gcloud services enable --project "$PROJECT" \
  compute.googleapis.com \
  iap.googleapis.com \
  oslogin.googleapis.com \
  cloudkms.googleapis.com \
  secretmanager.googleapis.com \
  artifactregistry.googleapis.com \
  dns.googleapis.com \
  iam.googleapis.com \
  storage.googleapis.com

# Enabling compute.googleapis.com creates two things this deployment never
# uses and doesn't want lying around: the default compute SA with project
# Editor (anything that can attach it to a VM inherits Editor), and the
# `default` VPC with SSH/RDP open to 0.0.0.0/0. The vault VM lives in the
# platform's own VPC with no attached SA; remove both.
project_number="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
default_sa="${project_number}-compute@developer.gserviceaccount.com"
log "Stripping roles/editor from the default compute SA"
if gcloud projects get-iam-policy "$PROJECT" --format=json \
     | jq -e --arg m "serviceAccount:${default_sa}" \
         '.bindings[] | select(.role == "roles/editor") | .members | index($m)' >/dev/null; then
  retry_iam gcloud projects remove-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:${default_sa}" --role roles/editor --condition=None >/dev/null
fi

log "Deleting the default VPC and its firewall rules"
while read -r rule; do
  [[ -n "$rule" ]] && gcloud compute firewall-rules delete "$rule" --project "$PROJECT" --quiet
done < <(gcloud compute firewall-rules list --project "$PROJECT" \
           --filter='network~/networks/default$' --format='value(name)')
if gcloud compute networks describe default --project "$PROJECT" >/dev/null 2>&1; then
  gcloud compute networks delete default --project "$PROJECT" --quiet
fi

log "KMS key ${KEYRING}/${KEY} (Pulumi secrets provider)"
if ! gcloud kms keyrings describe "$KEYRING" --location global --project "$PROJECT" >/dev/null 2>&1; then
  gcloud kms keyrings create "$KEYRING" --location global --project "$PROJECT"
fi
if ! gcloud kms keys describe "$KEY" --keyring "$KEYRING" --location global --project "$PROJECT" >/dev/null 2>&1; then
  gcloud kms keys create "$KEY" --keyring "$KEYRING" --location global --project "$PROJECT" \
    --purpose encryption
fi
# Explicit, rather than relying on what roles/owner happens to include.
retry_iam gcloud kms keys add-iam-policy-binding "$KEY" \
  --keyring "$KEYRING" --location global --project "$PROJECT" \
  --member "user:${owner}" --role roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --condition=None >/dev/null

log "Platform state bucket ${PLATFORM_BUCKET}"
if ! gcloud storage buckets describe "$PLATFORM_BUCKET" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud storage buckets create "$PLATFORM_BUCKET" --project "$PROJECT" \
    --location "$REGION" --uniform-bucket-level-access --public-access-prevention
fi
gcloud storage buckets update "$PLATFORM_BUCKET" --versioning >/dev/null

log "Secret containers from secrets/secret-names.txt"
while IFS= read -r name; do
  name="${name%%#*}"
  name="${name//[[:space:]]/}"
  [[ -z "$name" ]] && continue
  if gcloud secrets describe "$name" --project "$PROJECT" >/dev/null 2>&1; then
    printf '    exists   %s\n' "$name"
  else
    gcloud secrets create "$name" --project "$PROJECT" \
      --replication-policy automatic --labels app=vaultwarden >/dev/null
    printf '    created  %s\n' "$name"
  fi
done <"$secret_names"

cat <<EOF

Done. Next:
  1. Add values to any secret with no versions yet (schemas in secrets/README.md):
       gcloud secrets versions add <name> --project ${PROJECT} --data-file=-
  2. Bring up platform/ (runbook §2.2):
       cd platform && pulumi login ${PLATFORM_BUCKET}
EOF
