#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# backup-prune.sh — retention policy for backup/YYYYMMDD_HHMMSS/.
#
# Keeps:
#   • every snapshot from the last 7 days (full recent granularity), and
#   • the first (earliest) snapshot of each calendar month  — long-term
#     monthly anchors so you can always go back a month at a time.
# Everything else is deleted.
#
# Safe to run from cron. Pass --dry-run to preview without deleting.
# ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKUP_ROOT="$DOTFILES_DIR/backup"
RETAIN_DAYS=7

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
keep_msg()  { echo -e "  ${GREEN}keep${RESET}   $1 ${DIM}($2)${RESET}"; }
prune_msg() { echo -e "  ${YELLOW}prune${RESET}  $1"; }

DRY_RUN="no"
[ "${1:-}" = "--dry-run" ] && DRY_RUN="yes"

[ -d "$BACKUP_ROOT" ] || { echo "No backup directory ($BACKUP_ROOT) — nothing to prune."; exit 0; }

# Cutoff = today minus RETAIN_DAYS, as YYYYMMDD (GNU date vs BSD/macOS date).
if date -v-1d &>/dev/null 2>&1; then
  CUTOFF="$(date -v-${RETAIN_DAYS}d +%Y%m%d)"   # BSD / macOS
else
  CUTOFF="$(date -d "-${RETAIN_DAYS} days" +%Y%m%d)"  # GNU / Linux
fi

# Snapshot names sort lexically == chronologically, so the earliest name in a
# month is that month's "first" snapshot.
declare -A MONTH_FIRST
for d in "$BACKUP_ROOT"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  [[ "$name" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue
  ym="${name:0:6}"
  if [ -z "${MONTH_FIRST[$ym]:-}" ] || [[ "$name" < "${MONTH_FIRST[$ym]}" ]]; then
    MONTH_FIRST[$ym]="$name"
  fi
done

echo -e "${BOLD}Pruning backups${RESET} ${DIM}(keep < ${RETAIN_DAYS}d + first-of-month; cutoff ${CUTOFF})${RESET}"

kept=0; pruned=0
for d in "$BACKUP_ROOT"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  [[ "$name" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue
  date_part="${name:0:8}"
  ym="${name:0:6}"

  if [ "$date_part" -ge "$CUTOFF" ]; then
    keep_msg "$name" "within ${RETAIN_DAYS}d"; kept=$((kept+1))
  elif [ "${MONTH_FIRST[$ym]}" = "$name" ]; then
    keep_msg "$name" "first of ${ym}"; kept=$((kept+1))
  else
    prune_msg "$name"; pruned=$((pruned+1))
    [ "$DRY_RUN" = "no" ] && rm -rf "$d"
  fi
done

echo -e "  ${DIM}kept ${kept}, pruned ${pruned}$([ "$DRY_RUN" = "yes" ] && echo " (dry run — nothing deleted)")${RESET}"
