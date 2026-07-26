#!/bin/bash
# preflight.sh — verify that configured assets actually work.
#
# Deliberately NOT `set -e`: probes are expected to fail, and the script must
# continue and report rather than abort on the first broken asset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/integrations.sh
source "$DOTFILES_DIR/lib/integrations.sh"

# Every path is overridable so tests never read the real $HOME.
CLAUDE_JSON="${PREFLIGHT_CLAUDE_JSON:-$HOME/.claude.json}"
SETTINGS_JSON="${PREFLIGHT_SETTINGS_JSON:-$HOME/.claude/settings.json}"
ENV_FILE="${PREFLIGHT_ENV_FILE:-$HOME/.claude/.env}"
SKILLS_DIR="${PREFLIGHT_SKILLS_DIR:-$DOTFILES_DIR/skills}"
SMOKE_DIR="${PREFLIGHT_SMOKE_DIR:-$DOTFILES_DIR/tests/smoke}"
MCP_TIMEOUT="${PREFLIGHT_MCP_TIMEOUT:-180}"

# class|name|verdict|detail|containable
FINDINGS=()

CHECKER_BROKEN=0
CHECKER_REASON=""
MCP_TIMED_OUT=0

add_finding() {
  FINDINGS+=("$1|$2|$3|$4|$5")
}

# Count findings matching a verdict.
count_verdict() {
  local want="$1" n=0 f
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ "$(cut -d'|' -f3 <<<"$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# Probe every MCP server with a single `claude mcp list`. One invocation covers
# all servers in ~90s; per-server probing would cost ~90s each.
probe_mcp() {
  local out rc line name detail
  local seen_names=""

  if ! command -v claude >/dev/null 2>&1; then
    CHECKER_BROKEN=1
    CHECKER_REASON="claude CLI not found on PATH"
    return
  fi

  out=$(timeout "$MCP_TIMEOUT" claude mcp list 2>&1)
  rc=$?

  # 124 is `timeout` killing the child. Every server becomes UNKNOWN — never
  # FAIL. Auto-quarantining a whole toolchain on a network blip is the worst
  # outcome this script can produce.
  if [ "$rc" -eq 124 ]; then
    MCP_TIMED_OUT=1
    local key
    while IFS= read -r key; do
      [ -n "$key" ] && add_finding mcp "$key" unknown "handshake timed out after ${MCP_TIMEOUT}s" no
    done < <(jq -r '.mcpServers // {} | keys[]' "$CLAUDE_JSON" 2>/dev/null)
    return
  fi

  while IFS= read -r line; do
    case "$line" in
      *"✔ Connected"*)
        name="${line%%: *}"
        add_finding mcp "$name" pass "connected" no
        seen_names="$seen_names|$name|"
        ;;
      *"Needs authentication"*)
        name="${line%%: *}"
        add_finding mcp "$name" unknown "needs authentication" no
        seen_names="$seen_names|$name|"
        ;;
      *"✘ Failed to connect"*)
        name="${line%%: *}"
        detail="${line#*✘ }"
        add_finding mcp "$name" fail "$detail" yes
        seen_names="$seen_names|$name|"
        ;;
      *) continue ;;
    esac
  done <<<"$out"

  # Cross-reference against configured servers: any key present in
  # $CLAUDE_JSON that produced no finding above was silently absent from
  # `claude mcp list` output (or emitted a status line none of the case arms
  # recognize). That's still an observable gap, not a clean bill of health —
  # report it as `unknown` (never `fail`: we don't know it's broken, only
  # that we couldn't observe it) so it can't be auto-quarantined.
  local cfg_key
  while IFS= read -r cfg_key; do
    [ -n "$cfg_key" ] || continue
    case "$seen_names" in
      *"|$cfg_key|"*) continue ;;
    esac
    add_finding mcp "$cfg_key" unknown "configured but absent from claude mcp list output" no
  done < <(jq -r '.mcpServers // {} | keys[]' "$CLAUDE_JSON" 2>/dev/null)
}

main() {
  probe_mcp

  if [ "$CHECKER_BROKEN" -eq 1 ]; then
    echo "preflight could not run: $CHECKER_REASON" >&2
    exit 2
  fi

  if [ "$MCP_TIMED_OUT" -eq 1 ]; then
    echo "MCP handshake timed out after ${MCP_TIMEOUT}s — all servers reported unknown"
  fi

  local f class name verdict detail
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r class name verdict detail _ <<<"$f"
    case "$verdict" in
      pass)    echo "  ✔ $class $name" ;;
      fail)    echo "  ✘ $class $name — $detail" ;;
      unknown) echo "  ! $class $name — $detail (unknown)" ;;
    esac
  done

  local fails
  fails=$(count_verdict fail)
  if [ "$fails" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
