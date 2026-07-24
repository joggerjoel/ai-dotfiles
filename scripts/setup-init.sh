#!/usr/bin/env bash
# setup-init.sh — deterministic INIT stage for the Claude Code Setup hook
# (fires on `claude --init` / `--init-only` via .claude/settings.json).
#
# Verifies the machine's tool floor and appends structured results to the
# setup log so the agentic layer (/install) can read back what happened and
# fix or explain the gaps. Installs NOTHING itself — installation belongs to
# setup.sh / ansible; this stage is a fast, honest census.
#
# Log line format (one per check, greppable):
#   <iso-ts> | setup-init | <tool> | ok|missing | <detail>
set -uo pipefail

# PATH hardening — hooks run in non-login shells (the fleet-proven fix).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.opencode/bin:$PATH"

LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/setup.log"
mkdir -p "$LOG_DIR"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) | setup-init | $1 | $2 | ${3:-}" >>"$LOG"; }

echo "setup-init: verifying tool floor (results → $LOG)"
missing=0

# Required floor: the workforce cannot run without these.
for tool in git jq curl node claude just; do
  if command -v "$tool" >/dev/null 2>&1; then
    log "$tool" ok "$(command -v "$tool")"
  else
    log "$tool" missing "install via setup.sh (ensure_${tool}) or ansible provision-ai.yml"
    echo "setup-init: MISSING required tool: $tool"
    missing=$((missing + 1))
  fi
done

# Optional harnesses/backends: absence is a warning, not a failure.
for tool in codex pi grok opencode gh bun uv herdr tmux; do
  if command -v "$tool" >/dev/null 2>&1; then
    log "$tool" ok "$(command -v "$tool")"
  else
    log "$tool" missing "optional — agents-update.sh or setup.sh installs it"
  fi
done

# Repo health: dotfiles checkout present and current-ish.
DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if git -C "$DOTFILES_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  log dotfiles ok "$(git -C "$DOTFILES_DIR" rev-parse --short HEAD) ($(git -C "$DOTFILES_DIR" status --porcelain | wc -l | tr -d ' ') dirty files)"
else
  log dotfiles missing "not a git checkout: $DOTFILES_DIR"
fi

log summary "$([ "$missing" -eq 0 ] && echo ok || echo missing)" "$missing required tool(s) absent"
echo "setup-init: done ($missing required tool(s) missing)"
exit "$([ "$missing" -eq 0 ] && echo 0 || echo 1)"
