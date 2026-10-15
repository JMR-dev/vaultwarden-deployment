#!/usr/bin/env bash
# Build the custom Caddy image and gate it on a Trivy scan.
#
#   scripts/build-caddy.sh <image-ref>
#
# Shared by ci.yml (build + scan only) and deploy.yml (which pushes the ref
# afterwards). Needs docker and go (for the Trivy version resolver). Fails on
# any fixable HIGH/CRITICAL finding.
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
  --build-arg GO_BUILDER_IMAGE="$GO_BUILDER_IMAGE" \
  --build-arg RUNTIME_IMAGE="$RUNTIME_IMAGE" \
  --build-arg XCADDY_VERSION="$XCADDY_VERSION" \
  --build-arg CADDY_VERSION="$CADDY_VERSION" \
  --build-arg CORAZA_CADDY_MODULE="$CORAZA_CADDY_MODULE" \
  --build-arg CORAZA_CADDY_VERSION="$CORAZA_CADDY_VERSION" \
  --build-arg GCD_MODULE="$GCD_MODULE" \
  --build-arg GCD_VERSION="$GCD_VERSION" \
  -t "$ref" \
  -f Containerfile .

# versions.env pins a Trivy minor; the helper resolves its highest patch from
# Docker Hub and falls back to TRIVY_FALLBACK on any lookup failure.
trivy_tag="$(cd cmd/trivy-version && go run .)"
echo "Scanning ${ref} with aquasec/trivy:${trivy_tag}"

docker save "$ref" | docker run --rm -i --entrypoint sh "docker.io/aquasec/trivy:${trivy_tag}" -c '
  set -e
  cat >/tmp/image.tar
  trivy image --input /tmp/image.tar \
    --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --no-progress
'
