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

main() {
  local fails
  fails=$(count_verdict fail)
  if [ "$fails" -gt 0 ]; then
    exit 1
  fi
  exit 0
}

main "$@"
