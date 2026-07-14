#!/bin/bash
# marketplace-auto-update.sh — refresh all Claude Code plugin marketplaces.
#
# Invoked by cron once a day (see scripts/cron-setup.sh), NOT on session start.
# Safe to run by hand anytime:  ~/.claude/scripts/marketplace-auto-update.sh
# Watch what it did:            tail -f ~/.claude/.changelog/marketplace-update.log
set -uo pipefail

LOG="$HOME/.claude/.changelog/marketplace-update.log"

# cron runs with a minimal PATH — make `claude` findable. Check the usual bin
# dirs, then fall back to the nvm-installed binary (dynamic version dir).
for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do
  [ -x "$d/claude" ] && PATH="$d:$PATH"
done
if ! command -v claude &>/dev/null; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do
    [ -x "$d/claude" ] && { PATH="$d:$PATH"; break; }
  done
fi
export PATH

# Nothing to do if the CLI still isn't findable (e.g. minimal/CI shell).
command -v claude &>/dev/null || exit 0

mkdir -p "$(dirname "$LOG")"
{
  echo "── $(date '+%Y-%m-%d %H:%M:%S') marketplace update ──"
  claude plugin marketplace update
} >>"$LOG" 2>&1

exit 0
