#!/usr/bin/env bash
# Tests for how setup.sh turns an MCP server off. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a hook.
#
# The bug these guard against: setup.sh wrote "disabled": true into
# ~/.claude.json to mean "configured but off". Claude Code has no such field
# and starts the server anyway, so every opt-in server ran, and a keyless one
# printed a connection error on every launch. A server is now on when it is in
# mcpServers and off when it is not. What must hold:
#   1. drop_disabled_mcp_servers removes entries still carrying "disabled",
#      and leaves every other entry byte-for-byte alone.
#   2. An entry preflight quarantined (it carries _preflight) is not lost: it
#      moves to the quarantine file with its date and reason.
#   3. It is idempotent: a converged config produces no write and no output,
#      so it is safe on the `setup.sh update` path every fleet host runs.
#   4. `setup.sh add` writes no "disabled" field and clears a quarantine
#      record for the server it re-adds.
#   5. `setup.sh list` names a quarantined server as quarantined.
#
# Nothing here touches the network or the real $HOME.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SETUP="$ROOT/setup.sh"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mcpoff.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# setup.sh dispatches on "$1" at the very bottom; everything above is
# definitions, so sourcing that prefix gets the functions without running one.
DISPATCH=$(awk '/^case /{print NR; exit}' "$SETUP")
if [ -z "$DISPATCH" ]; then
  printf '  FAIL  cannot locate the setup.sh dispatch case — test needs updating\n'
  exit 1
fi
sed -n "1,$((DISPATCH - 1))p" "$SETUP" > "$TMP/defs.sh"

# Run a setup.sh function against a fake home. Echoes its stdout and stderr.
in_home() {
  local dir="$1"; shift
  (cd "$ROOT" && bash -c '
    set -uo pipefail
    source "$1"
    CLAUDE_DIR="$2/.claude"
    CLAUDE_JSON="$2/claude.json"
    shift 2
    "$@"
  ' _ "$TMP/defs.sh" "$dir" "$@" </dev/null 2>&1)
}

make_home() {
  mkdir -p "$1/.claude"
  printf '%s\n' "$2" > "$1/claude.json"
  : > "$1/.claude/.env"
}

QFILE_OF() { printf '%s\n' "$1/claude-mcp-quarantine.json"; }

# ── 1 + 2: disabled entries leave; quarantined ones are parked, not lost ──
H="$TMP/h1"
make_home "$H" '{"mcpServers":{
  "context7":{"type":"stdio","command":"npx","args":["-y","@upstash/context7-mcp"],"env":{}},
  "playwright":{"command":"npx","args":["@playwright/mcp@latest"],"disabled":true},
  "browser-tools-mcp":{"command":"npx","args":["-y","@agentdeskai/browser-tools-mcp@latest"],"disabled":true},
  "magic":{"type":"stdio","command":"npx","args":["-y","@21st-dev/magic"],"disabled":true,
           "_preflight":{"quarantinedAt":"2026-07-20T10:00:00Z","reason":"Not authenticated"}}
},"numStartups":7}'
before_c7=$(jq -cS '.mcpServers.context7' "$H/claude.json")

out=$(in_home "$H" drop_disabled_mcp_servers)

[ "$(jq -r '.mcpServers | has("playwright")' "$H/claude.json")" = "false" ] \
  && ok "a disabled entry is removed from mcpServers" \
  || ko "a disabled entry is removed from mcpServers" "$(cat "$H/claude.json")"

[ "$(jq -cS '.mcpServers.context7' "$H/claude.json")" = "$before_c7" ] \
  && ok "an enabled entry is left untouched" \
  || ko "an enabled entry is left untouched" "$(jq -c '.mcpServers.context7' "$H/claude.json")"

[ "$(jq -r '.numStartups' "$H/claude.json")" = "7" ] \
  && ok "the rest of claude.json survives" \
  || ko "the rest of claude.json survives"

[ "$(jq -r '.mcpServers | has("magic")' "$H/claude.json")" = "false" ] \
  && ok "a quarantined entry leaves mcpServers too" \
  || ko "a quarantined entry leaves mcpServers too"

got=$(jq -c '.servers.magic | [.quarantinedAt, .reason, .server.args, (.server | has("disabled") or has("_preflight"))]' \
      "$(QFILE_OF "$H")" 2>&1)
[ "$got" = '["2026-07-20T10:00:00Z","Not authenticated",["-y","@21st-dev/magic"],false]' ] \
  && ok "a quarantined entry is parked with its date, reason and clean config" \
  || ko "a quarantined entry is parked with its date, reason and clean config" "got $got"

grep -q 'playwright' <<<"$out" && grep -q './setup.sh add' <<<"$out" \
  && ok "each removal is reported with how to bring it back" \
  || ko "each removal is reported with how to bring it back" "output: $out"

# The hint must name the integration, not its config key: they differ for
# browser-tools (key browser-tools-mcp), and `add browser-tools-mcp` fails.
grep -q './setup.sh add browser-tools$' <<<"$out" \
  && ok "the hint names the integration, not its mcpServers key" \
  || ko "the hint names the integration, not its mcpServers key" "output: $(grep browser <<<"$out")"

# ── 3: idempotence ──
hash1=$(cksum < "$H/claude.json")
out2=$(in_home "$H" drop_disabled_mcp_servers)
[ -z "${out2//[[:space:]]/}" ] && [ "$(cksum < "$H/claude.json")" = "$hash1" ] \
  && ok "second run is silent and writes nothing" \
  || ko "second run is silent and writes nothing" "output: $out2"

# ── 4: add writes no disabled field and clears the quarantine record ──
printf 'API_KEY_21ST=k-21st\n' > "$H/.claude/.env"
in_home "$H" cmd_add magic >/dev/null
got=$(jq -c '.mcpServers.magic | [has("disabled"), .env.API_KEY_21ST]' "$H/claude.json" 2>&1)
[ "$got" = '[false,"k-21st"]' ] \
  && ok "add re-adds the server on, with its key" \
  || ko "add re-adds the server on, with its key" "got $got"

got=$(jq -r '.servers | has("magic")' "$(QFILE_OF "$H")" 2>&1)
[ "$got" = "false" ] \
  && ok "add clears the server's quarantine record" \
  || ko "add clears the server's quarantine record" "has=$got"

# ── 5: list names a quarantined server ──
H="$TMP/h2"
make_home "$H" '{"mcpServers":{}}'
printf '%s\n' '{"servers":{"magic":{"quarantinedAt":"2026-07-20T10:00:00Z","reason":"x","server":{}}}}' \
  > "$(QFILE_OF "$H")"
out=$(in_home "$H" cmd_list)
grep -E 'magic .*quarantined' <<<"$out" >/dev/null \
  && ok "list shows a quarantined server as quarantined" \
  || ko "list shows a quarantined server as quarantined" "output: $(grep magic <<<"$out")"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
