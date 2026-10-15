# Caddy build

Custom Caddy image:
- `github.com/corazawaf/coraza-caddy/v2 @ v2.5.0` (WAF, DetectionOnly)
- `github.com/caddy-dns/googleclouddns @ v1.1.0` (DNS-01 challenge provider)

Pinned versions live in `versions.env`. Bumps are deliberate; the Coraza
maintenance notes live in
`~/.claude/projects/.../memory/coraza_caddy_version.md`.

## How it's built

`scripts/build-caddy.sh <ref>` does the whole build, for CI and locally:

1. Sources `versions.env` and builds `Containerfile` with the version args.
   The build fails if either plugin is missing from `caddy list-modules` (a
   dropped `--with` otherwise yields a Caddy that only fails at runtime).
2. Scans the image with Trivy (minor pinned in `versions.env`, patch resolved
   by `cmd/trivy-version`) and fails on fixable HIGH/CRITICAL findings.

`.gitea/workflows/ci.yml` runs it on every branch without pushing.
`.gitea/workflows/deploy.yml` runs it and pushes to Artifact Registry
(`us-east1-docker.pkg.dev/vaultwarden-497422/vaultwarden/caddy`, owned by
`platform/`) with two tags:

- `:<sha>` (first 12 hex chars of the commit): immutable, the rollback target.
- `:<stack>` (`:disposable` / `:production`): the floating tag `podman
  auto-update` watches on that stack's host. A production deploy re-tags the
  `:<sha>` disposable already built and scanned instead of rebuilding.

The repo grants `roles/artifactregistry.reader` to `allUsers` so the host
pulls without any credential; the image holds no secrets.

## Building locally (operator iteration)

```sh
scripts/build-caddy.sh vaultwarden-caddy:local    # needs docker (or podman-docker) and go
```

Useful when iterating on the Caddyfile — start the local image with
`-v ./Caddyfile:/etc/caddy/Caddyfile:Z` and watch the boot logs.

## Why pin Caddy v2.11.3

`coraza-caddy/v2 v2.5.0` declares `github.com/caddyserver/caddy v2.11.3` in
its `go.mod`. Bumping Caddy past what the WAF module targets risks a build
break. Pinned + Trivy-gated rebuilds make every bump a reviewed event;
`podman auto-update` would happily pull a broken `:<stack>` if we let CI
publish one.
