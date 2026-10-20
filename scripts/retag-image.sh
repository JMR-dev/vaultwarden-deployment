#!/usr/bin/env bash
# Point a tag at an image already in Artifact Registry by copying its manifest,
# the way `crane tag` does: GET the manifest by its current tag, PUT the same
# bytes under the new tag. Creates the tag, or moves it if it exists.
#
#   scripts/retag-image.sh <region>-docker.pkg.dev/<project>/<repo>/<image>:<from-tag> <to-tag>
#
# Used by deploy.yml to move the floating per-stack tag (caddy:<stack>) onto
# the scanned caddy:<sha>. Why not `gcloud artifacts docker tags add`: it
# moves an existing tag by deleting it first, which needs
# artifactregistry.tags.delete. That's outside the deployer's
# roles/artifactregistry.writer, and not worth granting. A manifest PUT under
# a tag is plain writer access, and the digest stays identical, so the stack
# tag is byte for byte the build that was scanned.
#
# The access token reaches curl through a 0600 config file, never argv.

set -euo pipefail

usage="usage: $0 <region>-docker.pkg.dev/<project>/<repo>/<image>:<from-tag> <to-tag>"
src="${1:?$usage}"
to="${2:?$usage}"

host="${src%%/*}"
rest="${src#*/}"
path="${rest%:*}"
from="${rest##*:}"
[[ "$host" == *-docker.pkg.dev && "$from" != "$rest" && "$path" == */* ]] ||
  { echo "retag-image: not an Artifact Registry <image>:<tag>: $src" >&2; exit 1; }
[[ "$to" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
  { echo "retag-image: bad tag: $to" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"
umask 077

printf 'header = "Authorization: Bearer %s"\n' "$(gcloud auth print-access-token)" >"${work}/auth"

accept="application/vnd.oci.image.index.v1+json"
accept+=",application/vnd.oci.image.manifest.v1+json"
accept+=",application/vnd.docker.distribution.manifest.list.v2+json"
accept+=",application/vnd.docker.distribution.manifest.v2+json"

ctype="$(curl -fsS -K "${work}/auth" -H "Accept: ${accept}" -o "${work}/manifest" \
  -w '%{content_type}' "https://${host}/v2/${path}/manifests/${from}")"
curl -fsS -K "${work}/auth" -X PUT -H "Content-Type: ${ctype}" \
  --data-binary @"${work}/manifest" -o /dev/null "https://${host}/v2/${path}/manifests/${to}"

echo "${host}/${path}:${to} -> sha256:$(sha256sum <"${work}/manifest" | cut -d' ' -f1) (from :${from})"
