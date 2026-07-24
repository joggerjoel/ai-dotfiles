#!/usr/bin/env bash
# setup-maintenance.sh — deterministic MAINTENANCE stage for the Claude Code
# Setup hook (fires on `claude --maintenance` via .claude/settings.json).
#
# Runs the repo's existing maintenance scripts and appends structured results
# to the setup log so the agentic layer (/maintain) can read back what happened,
# verify, and decide what needs a human. Each step is best-effort: one failure
# is logged and does not abort the rest.
#
# Log line format:
#   <iso-ts> | setup-maintenance | <step> | ok|fail | <detail>
set -uo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$HOME/.opencode/bin:$PATH"

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$HOME/.claude/logs"
LOG="$LOG_DIR/setup.log"
mkdir -p "$LOG_DIR"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "$(ts) | setup-maintenance | $1 | $2 | ${3:-}" >>"$LOG"; }

# run <step-name> <cmd...> — execute, log ok/fail with tail of output, never abort.
run() {
  local step="$1"; shift
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ $rc -eq 0 ]; then
    log "$step" ok "$(echo "$out" | tail -1 | cut -c1-160)"
  else
    log "$step" fail "rc=$rc: $(echo "$out" | tail -1 | cut -c1-160)"
  fi
  echo "setup-maintenance: $step $([ $rc -eq 0 ] && echo ok || echo FAIL)"
  return 0
}

echo "setup-maintenance: running (results → $LOG)"

# What's outdated? (report-only; agents-update.sh applies)
[ -x "$DOTFILES_DIR/scripts/check-updates.sh" ] && run check-updates "$DOTFILES_DIR/scripts/check-updates.sh"

# Prune old config backups (the repo's own retention policy).
[ -x "$DOTFILES_DIR/scripts/backup-prune.sh" ] && run backup-prune "$DOTFILES_DIR/scripts/backup-prune.sh"

# Kill orphaned subagent processes (the CLAUDE.md-documented leak).
[ -x "$DOTFILES_DIR/scripts/cleanup-subagents.sh" ] && run cleanup-subagents "$DOTFILES_DIR/scripts/cleanup-subagents.sh"

# Node-only health (macstudio): herdr server + launchd agents.
if [ -f "$HOME/Library/LaunchAgents/dev.herdr.node.plist" ]; then
  run herdr-status "$DOTFILES_DIR/scripts/herdr-node.sh" status
fi

log summary ok "maintenance pass complete"
echo "setup-maintenance: done"
