#!/usr/bin/env bash
# Tests for setup.sh's env_file_key and sync_mcp_keys. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a hook.
#
# The bug these guard against: setup.sh snapshotted an API key into
# ~/.claude.json at the moment it was typed and never refreshed it. Answering
# the prompt with a bare Enter baked the literal string PLACEHOLDER. Adding the
# real key to ~/.claude/.env afterwards changed nothing, so the MCP server kept
# launching with PLACEHOLDER and every call returned 401 while `preflight`
# happily reported the key as present. One secret, two stores, one maintained.
#
# sync_mcp_keys makes ~/.claude.json derived: the env file wins. What must hold:
#   1. A stale baked value is replaced by the env-file value.
#   2. `disabled` is cleared for integrations the registry enables by default
#      (firecrawl), and LEFT ALONE for opt-in ones (github, openrouter, apify,
#      digitalocean). Handing someone a key must not switch on a server they
#      deliberately never turned on.
#   3. It is idempotent — a converged config produces no write and no output,
#      so it is safe on the `setup.sh update` path every fleet host runs.
#   4. Servers absent from ~/.claude.json are skipped, not created. Syncing a
#      key must never wire up an integration the host opted out of.
#   5. http/sse servers, which carry the secret in an Authorization header
#      rather than an env block, are left untouched. Guessing at a header
#      shape here would corrupt a working n8n or crawl4ai entry.
#
# Nothing here touches the network or the real $HOME.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SETUP="$ROOT/setup.sh"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/mcpkeysync.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# setup.sh dispatches on "$1" at the very bottom; everything above is
# definitions, so sourcing that prefix gets the functions without running one.
DISPATCH=$(awk '/^case /{print NR; exit}' "$SETUP")
if [ -z "$DISPATCH" ]; then
  printf '  FAIL  cannot locate the setup.sh dispatch case — test needs updating\n'
  exit 1
fi
sed -n "1,$((DISPATCH - 1))p" "$SETUP" > "$TMP/defs.sh"

# Build a fake home and run sync_mcp_keys against it. Echoes the function's
# stdout; the caller inspects $2/claude.json afterwards.
run_sync() {
  local dir="$1"
  bash -c '
    set -uo pipefail
    source "$1"
    CLAUDE_DIR="$2/.claude"
    CLAUDE_JSON="$2/claude.json"
    sync_mcp_keys
  ' _ "$TMP/defs.sh" "$dir" 2>&1
}

# A fake home with the given claude.json body and env file body.
make_home() {
  local dir="$1" json="$2" env="$3"
  mkdir -p "$dir/.claude"
  printf '%s\n' "$env" > "$dir/.claude/.env"
  printf '%s\n' "$json" > "$dir/claude.json"
}

baked_key() {
  jq -r --arg k "$2" --arg v "$3" '.mcpServers[$k].env[$v] // "ABSENT"' "$1/claude.json"
}
disabled_flag() {
  jq -r --arg k "$2" '.mcpServers[$k].disabled // "ABSENT"' "$1/claude.json"
}

ENVFILE='FIRECRAWL_API_KEY=fc-realkey
GITHUB_PERSONAL_ACCESS_TOKEN=ghp_realtoken
N8N_JWT=jwt-realtoken'

# ── 1 + 2: stale key replaced; disabled cleared only where the registry says ──
H="$TMP/h1"
make_home "$H" '{"mcpServers":{
  "firecrawl-mcp":{"type":"stdio","command":"npx","args":["-y","firecrawl-mcp"],
                   "env":{"FIRECRAWL_API_KEY":"PLACEHOLDER"},"disabled":true},
  "github":{"command":"npx","args":["-y","@modelcontextprotocol/server-github"],
            "env":{"GITHUB_PERSONAL_ACCESS_TOKEN":"PLACEHOLDER"},"disabled":true},
  "context7":{"type":"stdio","command":"npx","args":["-y","@upstash/context7-mcp"],"env":{}}
}}' "$ENVFILE"

out=$(run_sync "$H")

got=$(baked_key "$H" firecrawl-mcp FIRECRAWL_API_KEY)
[ "$got" = "fc-realkey" ] \
  && ok "PLACEHOLDER replaced by the ~/.claude/.env key" \
  || ko "PLACEHOLDER replaced by the ~/.claude/.env key" "got '$got'"

got=$(disabled_flag "$H" firecrawl-mcp)
[ "$got" = "ABSENT" ] \
  && ok "firecrawl re-enabled (registry does not disable it by default)" \
  || ko "firecrawl re-enabled (registry does not disable it by default)" "disabled=$got"

got=$(baked_key "$H" github GITHUB_PERSONAL_ACCESS_TOKEN)
[ "$got" = "ghp_realtoken" ] \
  && ok "opt-in integration still gets its key synced" \
  || ko "opt-in integration still gets its key synced" "got '$got'"

got=$(disabled_flag "$H" github)
[ "$got" = "true" ] \
  && ok "github stays disabled (opt-in regardless of key)" \
  || ko "github stays disabled (opt-in regardless of key)" "disabled=$got"

grep -q 'firecrawl' <<<"$out" \
  && ok "a repaired integration is reported on stdout" \
  || ko "a repaired integration is reported on stdout" "output: $out"

# ── 3: idempotence ──
out2=$(run_sync "$H")
[ -z "${out2//[[:space:]]/}" ] \
  && ok "second run is silent (converged)" \
  || ko "second run is silent (converged)" "output: $out2"

got=$(baked_key "$H" firecrawl-mcp FIRECRAWL_API_KEY)
[ "$got" = "fc-realkey" ] \
  && ok "second run leaves the key intact" \
  || ko "second run leaves the key intact" "got '$got'"

# ── 4: an unconfigured integration is never created ──
H="$TMP/h2"
make_home "$H" '{"mcpServers":{
  "context7":{"type":"stdio","command":"npx","args":["-y","@upstash/context7-mcp"],"env":{}}
}}' "$ENVFILE"
run_sync "$H" >/dev/null
got=$(jq -r '.mcpServers | has("firecrawl-mcp")' "$H/claude.json")
[ "$got" = "false" ] \
  && ok "an integration absent from claude.json is not created" \
  || ko "an integration absent from claude.json is not created" "has=$got"

# ── 5: header-carried secrets are left alone ──
H="$TMP/h3"
make_home "$H" '{"mcpServers":{
  "n8n-mcp":{"type":"http","url":"https://n8n.example/mcp-server/http",
             "headers":{"Authorization":"Bearer jwt-oldtoken"}}
}}' "$ENVFILE"
before=$(jq -cS '.mcpServers["n8n-mcp"]' "$H/claude.json")
run_sync "$H" >/dev/null
after=$(jq -cS '.mcpServers["n8n-mcp"]' "$H/claude.json")
[ "$before" = "$after" ] \
  && ok "http/sse server with a header secret is untouched" \
  || ko "http/sse server with a header secret is untouched" "before=$before after=$after"

# ── 6: a stdio server whose env block lacks the key gets it filled ──
# Registry rows that once needed no key (morphllm-fast-apply) were installed
# with "env":{}. Treating "no baked value" as "header-carried secret" left
# them keyless forever: `setup.sh tokens` saved the key and this sync skipped it.
H="$TMP/h6"
make_home "$H" '{"mcpServers":{
  "morphllm-fast-apply":{"type":"stdio","command":"npx","args":["-y","@morphllm/morphmcp"],"env":{}}
}}' 'MORPH_API_KEY=sk-morphkey'
run_sync "$H" >/dev/null
got=$(baked_key "$H" morphllm-fast-apply MORPH_API_KEY)
[ "$got" = "sk-morphkey" ] \
  && ok "empty env block on a stdio server gets the env-file key" \
  || ko "empty env block on a stdio server gets the env-file key" "got '$got'"

# ── env_file_key: quoting and export forms the env file actually contains ──
H="$TMP/h4"
make_home "$H" '{"mcpServers":{}}' 'PLAIN=abc
QUOTED="d e f"
SINGLE='"'"'ghi'"'"'
export EXPORTED=jkl'
for probe in "PLAIN abc" "SINGLE ghi" "EXPORTED jkl" "MISSING "; do
  set -- $probe
  var="$1"; want="${2:-}"
  got=$(bash -c 'set -uo pipefail; source "$1"; CLAUDE_DIR="$2/.claude"; env_file_key "$3"' \
        _ "$TMP/defs.sh" "$H" "$var")
  [ "$got" = "$want" ] \
    && ok "env_file_key reads $var" \
    || ko "env_file_key reads $var" "want '$want', got '$got'"
done

# ── 7: cmd_add consumes an existing env-file key without prompting ──
H="$TMP/h5"
make_home "$H" '{"mcpServers":{}}' 'FIRECRAWL_API_KEY=fc-existing'
out=$(cd "$ROOT" && bash -c '
  set -uo pipefail
  source "$1"
  CLAUDE_DIR="$2/.claude"
  CLAUDE_JSON="$2/claude.json"
  cmd_add firecrawl </dev/null
' _ "$TMP/defs.sh" "$H" 2>&1)

got=$(baked_key "$H" firecrawl-mcp FIRECRAWL_API_KEY)
[ "$got" = "fc-existing" ] \
  && ok "cmd_add uses an existing ~/.claude/.env key" \
  || ko "cmd_add uses an existing ~/.claude/.env key" "got '$got'"

if grep -q 'FIRECRAWL_API_KEY (required)' <<<"$out"; then
  ko "cmd_add skips the key prompt when ~/.claude/.env is configured" "output: $out"
else
  ok "cmd_add skips the key prompt when ~/.claude/.env is configured"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
