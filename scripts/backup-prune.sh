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

echo -e "${BOLD}Pruning backups${RESET} ${DIM}(keep < ${RETAIN_DAYS}d + first-of-month; cutoff ${CUTOFF})${RESET}"

# Snapshot names sort lexically == chronologically and glob expansion is
# sorted, so the first name seen for a month is that month's first snapshot.
# (Plain variable, not an associative array — macOS /bin/bash is 3.2.)
prev_ym=""
kept=0; pruned=0
for d in "$BACKUP_ROOT"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  [[ "$name" =~ ^[0-9]{8}_[0-9]{6}$ ]] || continue
  date_part="${name:0:8}"
  ym="${name:0:6}"

  month_first="no"
  if [ "$ym" != "$prev_ym" ]; then
    month_first="yes"
    prev_ym="$ym"
  fi

  if [ "$date_part" -ge "$CUTOFF" ]; then
    keep_msg "$name" "within ${RETAIN_DAYS}d"; kept=$((kept+1))
  elif [ "$month_first" = "yes" ]; then
    keep_msg "$name" "first of ${ym}"; kept=$((kept+1))
  else
    prune_msg "$name"; pruned=$((pruned+1))
    [ "$DRY_RUN" = "no" ] && rm -rf "$d"
  fi
done

echo -e "  ${DIM}kept ${kept}, pruned ${pruned}$([ "$DRY_RUN" = "yes" ] && echo " (dry run — nothing deleted)")${RESET}"

# ~/.claude/.backups accumulates per-update config snapshots on every machine
# and nothing else prunes it. Age-based: keep 60 days; never the CHANGELOG.
CLAUDE_BACKUPS="$HOME/.claude/.backups"
if [ -d "$CLAUDE_BACKUPS" ]; then
  stale=$(find "$CLAUDE_BACKUPS" -mindepth 1 -maxdepth 1 -mtime +60 ! -name 'CHANGELOG.md' | wc -l | tr -d ' ')
  if [ "$stale" -gt 0 ] && [ "$DRY_RUN" = "no" ]; then
    find "$CLAUDE_BACKUPS" -mindepth 1 -maxdepth 1 -mtime +60 ! -name 'CHANGELOG.md' -exec rm -rf {} +
  fi
  echo -e "  ${DIM}~/.claude/.backups: ${stale} entries older than 60d$([ "$DRY_RUN" = "yes" ] && echo " (dry run — kept)")${RESET}"
fi
