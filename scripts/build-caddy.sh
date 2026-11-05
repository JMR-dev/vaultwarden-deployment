#!/usr/bin/env bash
# Build the custom Caddy image and gate it on a Trivy scan.
#
#   scripts/build-caddy.sh <image-ref>
#
# Shared by ci.yml (build + scan only) and deploy.yml (which pushes the ref
# afterwards). Needs docker. Fails on any fixable HIGH/CRITICAL finding.
#
# Trivy gets the image over stdin (`docker save | docker run -i`) instead of a
# bind-mounted docker socket: on the Gitea runners the daemon is rootless
# Docker-in-Docker, where a -v /var/run/docker.sock path would resolve on the
# daemon's filesystem, not the job container's.

set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <image-ref>" >&2; exit 1; }
ref="$1"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}/caddy"

set -a
# shellcheck source=caddy/versions.env
. ./versions.env
set +a

DOCKER_BUILDKIT=1 docker build \
  --build-arg XCADDY_VERSION="$XCADDY_VERSION" \
  --build-arg CADDY_VERSION="$CADDY_VERSION" \
  --build-arg CORAZA_CADDY_MODULE="$CORAZA_CADDY_MODULE" \
  --build-arg CORAZA_CADDY_VERSION="$CORAZA_CADDY_VERSION" \
  --build-arg GCD_MODULE="$GCD_MODULE" \
  --build-arg GCD_VERSION="$GCD_VERSION" \
  --build-arg GO_MODULE_PINS="$GO_MODULE_PINS" \
  -t "$ref" \
  -f Containerfile .

# versions.env pins the Trivy image by digest.
echo "Scanning ${ref} with ${TRIVY_IMAGE}"

docker save "$ref" | docker run --rm -i --entrypoint sh "$TRIVY_IMAGE" -c '
  set -e
  cat >/tmp/image.tar
  trivy image --input /tmp/image.tar \
    --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --no-progress
'
