#!/bin/bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────
# fleet-auto-update.sh — unattended fleet update, for cron on the
# CONTROL NODE only (the machine that holds inventory.local.yml).
#
# Runs ansible-ai/update.yml: every host — servers AND this machine —
# pulls origin/main and re-applies its saved profile. Nothing is
# pushed from here; hosts converge on whatever is already on GitHub.
#
# Install the schedule with:  ./scripts/fleet-cron-setup.sh
# Watch it:                   tail -f ~/.claude/.changelog/fleet-update.log
# ─────────────────────────────────────────────────────────────────

LOG="$HOME/.claude/.changelog/fleet-update.log"
LOCK="$HOME/.claude/.fleet-update.lock"

# cron's PATH is bare; ansible lives in brew/pip/user dirs. pyenv's shim dir is
# included because a pyenv-managed ansible is invisible otherwise: the guard
# below then reported "not on PATH" and aborted every night, which is how the
# fleet drifted 16 commits behind while the cron logged a run each morning.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.pyenv/shims:$PATH"

# A pyenv shim resolves through `pyenv version`, which needs PYENV_ROOT when
# HOME-relative discovery has not run. Harmless when pyenv is absent.
[ -d "$HOME/.pyenv" ] && export PYENV_ROOT="$HOME/.pyenv"

# Resolve the repo through the ~/.claude/scripts symlink.
SELF="$0"
command -v readlink >/dev/null 2>&1 && SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
REPO="$(cd "$(dirname "$SELF")/.." && pwd)"

mkdir -p "$(dirname "$LOG")"

# Keep the log bounded (same pattern as marketplace-auto-update.sh).
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 4000 ]; then
  tail -n 2000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# Single-flight with a stale-lock TTL (>2h = a dead run; fleet plays
# take minutes, not hours).
if [ -d "$LOCK" ]; then
  find "$LOCK" -maxdepth 0 -mmin +120 -exec rmdir {} \; 2>/dev/null || true
fi
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "[$(date '+%F %T')] skipped — another fleet update is running" >>"$LOG"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

{
  echo "───────────────────────────────────────────────"
  echo "[$(date '+%F %T')] fleet update starting (repo: $REPO)"
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    # Print the PATH searched. Without it this line reads identically whether
    # ansible is uninstalled or merely installed somewhere this script does not
    # look, and the second case aborted nightly for weeks while the log kept
    # showing a run.
    echo "ansible-playbook not on PATH — aborting. PATH=$PATH"
    exit 1
  fi
  if [ ! -f "$REPO/ansible-ai/inventory.local.yml" ]; then
    echo "no inventory.local.yml — this machine isn't the control node, aborting"
    exit 1
  fi
  cd "$REPO/ansible-ai" || exit 1
  ansible-playbook update.yml
  echo "[$(date '+%F %T')] fleet update finished (rc=$?)"
} >>"$LOG" 2>&1
