# Caddy build

Custom Caddy image:
- `github.com/corazawaf/coraza-caddy/v2 @ v2.5.0` (WAF, DetectionOnly)
- `github.com/caddy-dns/googleclouddns @ v1.1.0` (DNS-01 challenge provider)

Pinned versions live in `versions.env`. Bumps are deliberate; the Coraza
maintenance notes live in
`~/.claude/projects/.../memory/coraza_caddy_version.md`.

## How it's built

`cloudbuild.yaml` (top of repo) runs the build:

1. Reads `caddy/versions.env`
2. Builds `caddy/Containerfile` with the version args
3. Runs Trivy against the resulting image; fails the build on HIGH/CRITICAL
4. Pushes to Artifact Registry at the path Pulumi exports as `imageRepo`
   (the AR repo itself is owned by Pulumi, per stack), with two tags:
   `:<short-sha>` (immutable, for rollback) and `:latest` (the moving
   target).

`podman auto-update` on the Hetzner host watches `:latest`. The AR repo
grants `roles/artifactregistry.reader` to `allUsers` so the host pulls
without auth — same posture as a public GHCR repo, just on the project's
native registry.

## Building locally (operator iteration)

```sh
set -a; . versions.env; set +a
podman build \
  --build-arg GO_BUILDER_IMAGE="$GO_BUILDER_IMAGE" \
  --build-arg RUNTIME_IMAGE="$RUNTIME_IMAGE" \
  --build-arg XCADDY_VERSION="$XCADDY_VERSION" \
  --build-arg CADDY_VERSION="$CADDY_VERSION" \
  --build-arg CORAZA_CADDY_MODULE="$CORAZA_CADDY_MODULE" \
  --build-arg CORAZA_CADDY_VERSION="$CORAZA_CADDY_VERSION" \
  --build-arg GCD_MODULE="$GCD_MODULE" \
  --build-arg GCD_VERSION="$GCD_VERSION" \
  -t vaultwarden-caddy:local \
  -f Containerfile .
```

Useful when iterating on the Caddyfile — start the local image with
`-v ./Caddyfile:/etc/caddy/Caddyfile:Z` and watch the boot logs.

## Why pin Caddy v2.11.3

`coraza-caddy/v2 v2.5.0` declares `github.com/caddyserver/caddy v2.11.3` in
its `go.mod`. Bumping Caddy past what the WAF module targets risks a build
break. Pinned + Trivy-gated rebuilds make every bump a reviewed event;
`podman auto-update` would happily pull a broken `:latest` if we let CI
publish one.
