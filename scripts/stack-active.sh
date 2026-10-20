#!/usr/bin/env bash
# Switch a runtime-switched app stack on or off by writing the boolean
# platform/ reads from Parameter Manager. No code change or commit is needed.
#
#   scripts/stack-active.sh <stack> true|false    # set it
#   scripts/stack-active.sh <stack>               # show the current value
#
# Then run `pulumi up` in platform/ (runbook §2.9):
# - true reserves the stack's static IPs, writes its A/AAAA records and
#   grants its secrets;
# - false releases them. Its R2 bucket stays.
# Only stacks configured with `activeParameter` in platform/Pulumi.prod.yaml
# read this. Production's `active` is fixed in code.
#
# The parameter is vaultwarden-<stack>-active (location global, JSON format),
# created by scripts/bootstrap-gcp.sh. Each call adds a version, and platform/
# reads the newest enabled one. So a mistaken flip is undone by disabling the
# version it created:
#   gcloud parametermanager parameters versions update <version> \
#     --parameter=vaultwarden-<stack>-active --location=global --disabled
#
# Only the JSON booleans true and false are written. platform/ refuses
# anything else too (ParseActive), because the JSON format alone would also
# accept "true" or 1.

set -euo pipefail

PROJECT="${GCP_PROJECT:-vaultwarden-497422}"
usage="usage: $0 <stack> [true|false]"

stack="${1:?$usage}"
[[ "$stack" =~ ^[a-z][a-z0-9]{1,15}$ ]] || { echo "stack-active: bad stack name: $stack" >&2; exit 1; }
param="vaultwarden-${stack}-active"
where=(--parameter="$param" --location=global --project="$PROJECT")

gcloud parametermanager parameters describe "$param" --location=global --project="$PROJECT" >/dev/null 2>&1 ||
  { echo "stack-active: no parameter ${param}; run scripts/bootstrap-gcp.sh first" >&2; exit 1; }

if [[ $# -eq 1 ]]; then
  # The newest enabled version, as platform/ picks it.
  # --verbosity=error: until a version is disabled, gcloud warns that no
  # resource has the `disabled` key.
  version="$(gcloud parametermanager parameters versions list "${where[@]}" --verbosity=error \
    --filter='-disabled:true' --sort-by='~createTime' --limit=1 --format='value(name.basename())')"
  [[ -n "$version" ]] || { echo "${param}: no enabled version" >&2; exit 1; }
  value="$(gcloud parametermanager parameters versions describe "$version" "${where[@]}" \
    --format='value(payload.data)' | base64 -d)"
  echo "${param} = ${value} (version ${version})"
  exit 0
fi

[[ $# -eq 2 ]] || { echo "$usage" >&2; exit 1; }
value="$2"
[[ "$value" == true || "$value" == false ]] ||
  { echo "stack-active: the value must be true or false, got: ${value}" >&2; exit 1; }

version="v$(date -u +%Y%m%d-%H%M%S)"
gcloud parametermanager parameters versions create "$version" "${where[@]}" --payload-data="$value" >/dev/null
echo "${param} = ${value} (version ${version}). Next: pulumi up in platform/ (runbook §2.9)."
