#!/bin/bash
# cass-cron-setup.sh — keep this host's cass index fresh on a schedule.
#
# PER-HOST, unlike fleet-cron-setup.sh. cass keeps a per-machine archive with
# no shared index, so every host that runs cass needs its own entry; there is
# nothing for a control node to fan out.
#
# Why a schedule at all: cass reports `status: unhealthy` once new agent
# sessions have landed since the last index — which on an active host is
# constantly. Search keeps working while stale, so this is about keeping
# results complete and triage trustworthy, not about repairing a fault.
#
#   install / update:   ./scripts/cass-cron-setup.sh
#   custom interval:    CRON_EVERY_HOURS=6 ./scripts/cass-cron-setup.sh
#   custom minute/tz:   CRON_MIN=40 CRON_TZ=America/Los_Angeles ./scripts/cass-cron-setup.sh
#   remove:             ./scripts/cass-cron-setup.sh --remove
#   preview only:       ./scripts/cass-cron-setup.sh --dry-run
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }

# ── Config (override via env) ────────────────────────────────────
# Every 2 hours by default: a measured incremental pass is ~90s on a node
# carrying ~93k conversations and effectively instant on a worker, so this is
# roughly a 2% duty cycle on the busiest machine. :25 keeps it clear of the
# 2:10 marketplace job.
CRON_EVERY_HOURS="${CRON_EVERY_HOURS:-2}"
CRON_MIN="${CRON_MIN:-25}"
CRON_TZ="${CRON_TZ:-America/New_York}"
LOG="$HOME/.cass-index.log"
MARKER="# cass-index-refresh"   # unique tag → find/replace/remove this line

# ── Preconditions ────────────────────────────────────────────────
command -v crontab &>/dev/null || { warn "crontab not found — install cron first."; exit 1; }

# Gate on cass RUNNING, not merely existing: the prebuilt Linux asset needs
# glibc >= 2.39 and installs cleanly on older hosts before failing on every
# call. Scheduling a dead binary would just fill the log with the same error
# every couple of hours.
if ! cass --version &>/dev/null; then
  warn "cass is not runnable here — nothing to schedule."
  command -v cass &>/dev/null && warn "  (a cass binary exists but will not run: $(cass --version 2>&1 | head -1))"
  exit 1
fi

# cron gets a minimal PATH that will not include ~/.local/bin or Homebrew, so
# bake the resolved absolute path into the entry rather than hoping.
CASS_BIN="$(command -v cass)"

CRON_LINE="${CRON_MIN} */${CRON_EVERY_HOURS} * * * TZ=${CRON_TZ} ${CASS_BIN} index --json --no-progress-events >> ${LOG} 2>&1 ${MARKER}"

case "${1:-}" in
  --remove)
    if crontab -l 2>/dev/null | grep -qF "$MARKER"; then
      crontab -l 2>/dev/null | grep -vF "$MARKER" | crontab -
      ok "Removed the cass index refresh cron job."
    else
      skip "No cass index refresh cron job to remove."
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

# ── Install / update (idempotent) ────────────────────────────────
# Strip any prior marker line, then append the current one.
{ crontab -l 2>/dev/null | grep -vF "$MARKER"; echo "$CRON_LINE"; } | crontab -

echo -e "${BOLD}cass index refresh scheduled${RESET}"
ok "Every ${CRON_EVERY_HOURS}h at :$(printf '%02d' "$CRON_MIN") ${CRON_TZ}"
echo -e "  ${DIM}cass:  $CASS_BIN ($($CASS_BIN --version 2>/dev/null))${RESET}"
echo -e "  ${DIM}line:  $CRON_LINE${RESET}"
echo -e "  ${DIM}log:   $LOG${RESET}"
echo -e "  ${DIM}check: crontab -l | grep cass${RESET}"
echo -e "  ${DIM}undo:  ./scripts/cass-cron-setup.sh --remove${RESET}"
