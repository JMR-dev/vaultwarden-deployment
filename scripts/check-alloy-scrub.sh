#!/usr/bin/env bash
# Runs a client config's scrub rules over a fixture with Alloy itself, and
# checks what would ship. Nothing on watchtower scrubs, so these rules are the
# only thing between a service's logs and storage (docs/client-telemetry.md).
#
#   scripts/check-alloy-scrub.sh [config] [fixture]
#   (defaults: config/alloy/config.alloy.example, config/alloy/testdata/scrub.log)
#
# The rules are the loki.process block between the config's
# "// scrub: begin" and "// scrub: end" lines; they run with the fixture's
# lines in and loki.echo out. Each fixture line carries a tag:
#   keep:<n>   comes out (scrubbed)
#   same:<n>   comes out unchanged (a rule mustn't mangle ordinary lines)
#   drop:<n>   doesn't come out
# and nothing that comes out may match a line of <fixture>.forbidden (grep
# -E). The last line mustn't be a drop: the run ends when it comes out.
#
# SCRUB_SHOW=1 prints what came out. Needs alloy and jq. Service repos copy
# it with the example config.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${1:-${repo_root}/config/alloy/config.alloy.example}"
fixture="${2:-${repo_root}/config/alloy/testdata/scrub.log}"
forbidden="${fixture%.log}.forbidden"
port="${ALLOY_TEST_PORT:-12398}"

fail() { echo "scrub check: $*" >&2; exit 1; }
[[ -f "$config" && -f "$fixture" && -f "$forbidden" ]] || fail "need ${config}, ${fixture} and ${forbidden}"

work="$(mktemp -d)"
pid=
cleanup() { [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

block="$(sed -n '/^\/\/ scrub: begin/,/^\/\/ scrub: end/p' "$config")"
name="$(sed -n 's/^loki\.process "\([^"]*\)" {$/\1/p' <<<"$block" | head -1)"
[[ -n "$name" ]] || fail "no loki.process block between the scrub markers in ${config}"
[[ "$(grep -c 'forward_to' <<<"$block")" -eq 1 ]] || fail "the scrub block must have exactly one forward_to"

cp "$fixture" "${work}/in.log"
last="$(tail -n 1 "$fixture" | cut -d' ' -f1)"
[[ "$last" == keep:* || "$last" == same:* ]] || fail "the fixture's last line must be keep: or same:"
{
  printf 'logging {\n\tlevel  = "info"\n\tformat = "json"\n}\n\n'
  printf 'loki.source.file "fixture" {\n\ttargets    = [{"__path__" = "%s", "service" = "fixture", "job" = "fixture"}]\n' "${work}/in.log"
  printf '\tforward_to = [loki.process.%s.receiver]\n}\n\n' "$name"
  sed -E 's/^([[:space:]]*forward_to[[:space:]]*=[[:space:]]*)\[.*\]$/\1[loki.echo.out.receiver]/' <<<"$block"
  printf '\nloki.echo "out" { }\n'
} >"${work}/harness.alloy"

alloy run --server.http.listen-addr="127.0.0.1:${port}" --storage.path="${work}/data" \
  --disable-reporting "${work}/harness.alloy" >"${work}/alloy.log" 2>&1 &
pid=$!

out="${work}/out.txt"
for _ in $(seq 60); do
  jq -r 'select(.component_id == "loki.echo.out") | .entry' "${work}/alloy.log" 2>/dev/null >"$out" || true
  grep -q "^${last} " "$out" && break
  kill -0 "$pid" 2>/dev/null || { tail -20 "${work}/alloy.log" >&2; fail "alloy exited"; }
  sleep 0.5
done
grep -q "^${last} " "$out" || { tail -20 "${work}/alloy.log" >&2; fail "${last} never came out"; }

[[ -z "${SCRUB_SHOW:-}" ]] || cat "$out"
bad=0
while read -r tag line; do
  case "$tag" in
    keep:*) grep -q "^${tag} " "$out" || { echo "missing: ${tag}"; bad=1; } ;;
    same:*) grep -qxF "${tag} ${line}" "$out" || { echo "changed: ${tag} -> $(grep "^${tag} " "$out" || echo '(missing)')"; bad=1; } ;;
    drop:*) ! grep -q "^${tag} " "$out" || { echo "shipped: ${tag}"; bad=1; } ;;
    *) fail "untagged fixture line: ${tag} ${line}" ;;
  esac
done <"$fixture"
while IFS= read -r pattern; do
  [[ -z "$pattern" ]] && continue
  if hits="$(grep -E -- "$pattern" "$out")"; then
    echo "leaked /${pattern}/: ${hits//$'\n'/ | }"
    bad=1
  fi
done <"$forbidden"
[[ "$bad" -eq 0 ]] || fail "$(basename "$config") ships what it shouldn't (above)"
echo "scrub check: $(basename "$config"): $(wc -l <"$out") of $(wc -l <"$fixture") lines out, all scrubbed"
