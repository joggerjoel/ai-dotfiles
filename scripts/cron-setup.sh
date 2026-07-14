#!/bin/bash
# cron-setup.sh — install the daily Claude Code marketplace-refresh cron job.
#
# Idempotent: re-running updates the entry in place (never duplicates it).
# Portable: run this on any new build after the dotfiles symlinks are in place.
#
#   install / update:   ./scripts/cron-setup.sh
#   custom time (24h):  CRON_HOUR=3 CRON_MIN=30 ./scripts/cron-setup.sh
#   different tz:       CRON_TZ=America/Los_Angeles ./scripts/cron-setup.sh
#   remove:             ./scripts/cron-setup.sh --remove
#   preview only:       ./scripts/cron-setup.sh --dry-run
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }

# ── Config (override via env) ────────────────────────────────────
CRON_HOUR="${CRON_HOUR:-2}"          # "around 2am"
CRON_MIN="${CRON_MIN:-10}"           # :10 to avoid colliding with other 2am jobs
CRON_TZ="${CRON_TZ:-America/New_York}"
SCRIPT="$HOME/.claude/scripts/marketplace-auto-update.sh"
MARKER="# claude-marketplace-refresh"   # unique tag → find/replace/remove this line

CRON_LINE="${CRON_MIN} ${CRON_HOUR} * * * TZ=${CRON_TZ} ${SCRIPT} ${MARKER}"

# ── Preconditions ────────────────────────────────────────────────
command -v crontab &>/dev/null || { warn "crontab not found — install cron first."; exit 1; }

case "${1:-}" in
  --remove)
    if crontab -l 2>/dev/null | grep -qF "$MARKER"; then
      crontab -l 2>/dev/null | grep -vF "$MARKER" | crontab -
      ok "Removed the marketplace-refresh cron job."
    else
      skip "No marketplace-refresh cron job to remove."
    fi
    exit 0
    ;;
  --dry-run)
    echo -e "${BOLD}Would install:${RESET}\n  $CRON_LINE"
    exit 0
    ;;
  "" ) : ;;  # install/update
  * ) warn "Unknown arg: $1 (use --remove or --dry-run)"; exit 1 ;;
esac

# The target script should exist (via the dotfiles symlink farm).
[ -x "$SCRIPT" ] || warn "Target not executable/found: $SCRIPT (link the dotfiles first?)"

# ── Install / update (idempotent) ────────────────────────────────
# Strip any prior marker line, then append the current one, then reload.
{ crontab -l 2>/dev/null | grep -vF "$MARKER"; echo "$CRON_LINE"; } | crontab -

echo -e "${BOLD}Claude marketplace refresh scheduled${RESET}"
ok "Daily at ${CRON_HOUR}:$(printf '%02d' "$CRON_MIN") ${CRON_TZ}"
echo -e "  ${DIM}line:  $CRON_LINE${RESET}"
echo -e "  ${DIM}log:   ~/.claude/.changelog/marketplace-update.log${RESET}"
echo -e "  ${DIM}check: crontab -l | grep marketplace${RESET}"
echo -e "  ${DIM}undo:  ./scripts/cron-setup.sh --remove${RESET}"
