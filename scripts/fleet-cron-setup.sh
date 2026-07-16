#!/bin/bash
# fleet-cron-setup.sh — schedule the daily unattended FLEET update.
#
# Control node only: the cron entry runs fleet-auto-update.sh here, which
# fans out ansible-ai/update.yml to every host. Individual targets need
# nothing — they're updated by the play, not by their own schedules.
#
#   install / update:   ./scripts/fleet-cron-setup.sh
#   custom time (24h):  CRON_HOUR=7 CRON_MIN=0 ./scripts/fleet-cron-setup.sh
#   remove:             ./scripts/fleet-cron-setup.sh --remove
#   preview only:       ./scripts/fleet-cron-setup.sh --dry-run
#
# Caveats: cron doesn't fire while a Mac sleeps (missed runs are skipped,
# the next one catches up — updates are idempotent), and unattended SSH
# needs your key loadable without a prompt (Keychain-backed keys work).
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }

CRON_HOUR="${CRON_HOUR:-6}"
CRON_MIN="${CRON_MIN:-15}"
CRON_TZ="${CRON_TZ:-America/New_York}"
SCRIPT="$HOME/.claude/scripts/fleet-auto-update.sh"
MARKER="# claude-fleet-update"

CRON_LINE="${CRON_MIN} ${CRON_HOUR} * * * TZ=${CRON_TZ} ${SCRIPT} ${MARKER}"

command -v crontab &>/dev/null || { warn "crontab not found — install cron first."; exit 1; }

case "${1:-}" in
  --remove)
    if crontab -l 2>/dev/null | grep -qF "$MARKER"; then
      crontab -l 2>/dev/null | grep -vF "$MARKER" | crontab -
      ok "Removed the fleet-update cron job."
    else
      skip "No fleet-update cron job to remove."
    fi
    exit 0
    ;;
  --dry-run)
    echo -e "${BOLD}Would install:${RESET}\n  $CRON_LINE"
    exit 0
    ;;
  "" ) : ;;
  * ) warn "Unknown arg: $1 (use --remove or --dry-run)"; exit 1 ;;
esac

[ -x "$SCRIPT" ] || warn "Target not executable/found: $SCRIPT (run ./setup.sh update to link scripts first)"
[ -f "$(dirname "$(readlink -f "$SCRIPT" 2>/dev/null || echo "$SCRIPT")")/../ansible-ai/inventory.local.yml" ] \
  || warn "No inventory.local.yml — this doesn't look like the control node."

{ crontab -l 2>/dev/null | grep -vF "$MARKER"; echo "$CRON_LINE"; } | crontab -

echo -e "${BOLD}Daily fleet update scheduled (control node)${RESET}"
ok "Daily at ${CRON_HOUR}:$(printf '%02d' "$CRON_MIN") ${CRON_TZ}"
echo -e "  ${DIM}line:  $CRON_LINE${RESET}"
echo -e "  ${DIM}log:   ~/.claude/.changelog/fleet-update.log${RESET}"
echo -e "  ${DIM}undo:  ./scripts/fleet-cron-setup.sh --remove${RESET}"
