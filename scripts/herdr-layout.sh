#!/usr/bin/env bash
# Declare a herdr space/tab layout in a file and apply it to the running session.
#
# herdr persists structure in ~/.config/herdr/session.json, but that file is
# runtime state — pane ids, terminal ids, scroll offsets — not something to hand
# edit or version. This script is the versionable half: the layout you want,
# applied idempotently to whatever the session currently has.
#
# It only ever ADDS. Spaces and tabs that exist are left alone, and nothing is
# ever closed, so re-running after manual tinkering is safe and a scratch space
# is never swept up.
#
# Usage:
#   herdr-layout.sh [apply] [--dry-run] [--wire] [--policy bare|fallback|reconnect]
#   herdr-layout.sh status
#
# Config: $HERDR_LAYOUT, else ~/.config/herdr/layout.conf
# It lives outside this repo on purpose — host names are private, and this repo
# is public. See examples/herdr-layout.example.conf.

set -euo pipefail

CONFIG="${HERDR_LAYOUT:-$HOME/.config/herdr/layout.conf}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="apply"
DRY=""
WIRE=""
POLICY="fallback"

while [ $# -gt 0 ]; do
  case "$1" in
    apply|status) ACTION="$1"; shift ;;
    --dry-run)    DRY=1; shift ;;
    --wire)       WIRE=1; shift ;;
    --policy)     POLICY="$2"; shift 2 ;;
    --config)     CONFIG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -f "$CONFIG" ] || {
  echo "no layout config at $CONFIG" >&2
  echo "copy examples/herdr-layout.example.conf there and edit it." >&2
  exit 1
}

command -v herdr >/dev/null || { echo "herdr not on PATH" >&2; exit 1; }
herdr workspace list >/dev/null 2>&1 || { echo "herdr server not reachable" >&2; exit 1; }

# --- parse config -----------------------------------------------------------
# TABS=a,b,c            default tab list for every space below it
# <label> <host|local> [tabs]   one space; tabs override the default

DEFAULT_TABS="@claude,@codex,@cursor,@pi,tmux"
SPACES=()   # "label|host|tabs"

while read -r line || [ -n "$line" ]; do
  line="${line%%#*}"                                  # strip comments
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$line" ] || continue
  case "$line" in
    TABS=*) DEFAULT_TABS="${line#TABS=}"; continue ;;
  esac
  # shellcheck disable=SC2206
  parts=($line)
  label="${parts[0]}"
  host="${parts[1]:-local}"
  tabs="${parts[2]:-$DEFAULT_TABS}"
  SPACES+=("${label}|${host}|${tabs}")
done < "$CONFIG"

[ ${#SPACES[@]} -gt 0 ] || { echo "no spaces declared in $CONFIG" >&2; exit 1; }

# --- read live state once ---------------------------------------------------
# Emits "<workspace-label>|<workspace-id>|<tab-label,tab-label,...>" per space.

live_state() {
  herdr workspace list | python3 -c "
import json,sys,subprocess
from collections import defaultdict
tabs=defaultdict(list)
for t in json.loads(subprocess.run(['herdr','tab','list'],capture_output=True,text=True).stdout)['result']['tabs']:
    tabs[t['workspace_id']].append(t['label'])
for w in json.load(sys.stdin)['result']['workspaces']:
    print('%s|%s|%s' % (w['label'], w['workspace_id'], ','.join(tabs[w['workspace_id']])))
"
}

ws_id_for()   { printf '%s\n' "$LIVE" | awk -F'|' -v l="$1" '$1==l {print $2; exit}'; }
ws_tabs_for() { printf '%s\n' "$LIVE" | awk -F'|' -v l="$1" '$1==l {print $3; exit}'; }

# Compare a space's live tabs against the declared set. Extra tabs are NOT a
# defect: apply only ever adds, so a space that has picked up an ad-hoc tab is
# still satisfied. Only missing tabs, or declared tabs sitting in the wrong
# relative order, are worth reporting.
compare_tabs() {  # <label> <have-csv> <want-csv>
  python3 -c "
import sys
label, have, want = sys.argv[1], sys.argv[2].split(','), sys.argv[3].split(',')
have = [t for t in have if t]
missing = [t for t in want if t not in have]
extra   = [t for t in have if t not in want]
order   = [t for t in have if t in want] != [t for t in want if t in have]
state = 'MISSING' if missing else ('ORDER' if order else 'ok')
print('%-14s %-10s %s' % (label, state, ','.join(have)))
if missing: print('%-14s %-10s missing: %s' % ('', '', ','.join(missing)))
if order:   print('%-14s %-10s want order: %s' % ('', '', ','.join(want)))
if extra:   print('%-14s %-10s extra (left alone): %s' % ('', '', ','.join(extra)))
" "$1" "$2" "$3"
}

LIVE="$(live_state)"

# --- status -----------------------------------------------------------------

if [ "$ACTION" = status ]; then
  printf '%-14s %-10s %s\n' SPACE STATE TABS
  for entry in "${SPACES[@]}"; do
    IFS='|' read -r label host want <<<"$entry"
    ws="$(ws_id_for "$label")"
    if [ -z "$ws" ]; then
      printf '%-14s %-10s %s\n' "$label" "MISSING" "$want"
      continue
    fi
    have="$(ws_tabs_for "$label")"
    compare_tabs "$label" "$have" "$want"
  done
  # Spaces that exist but are not declared — reported, never touched.
  while IFS='|' read -r label _ _; do
    for entry in "${SPACES[@]}"; do
      [ "${entry%%|*}" = "$label" ] && continue 2
    done
    printf '%-14s %-10s (not in config — left alone)\n' "$label" "extra"
  done <<<"$LIVE"
  exit 0
fi

# --- apply ------------------------------------------------------------------

for entry in "${SPACES[@]}"; do
  IFS='|' read -r label host want <<<"$entry"
  ws="$(ws_id_for "$label")"

  if [ -z "$ws" ]; then
    echo "space '$label': creating"
    # A new workspace arrives with one tab labelled '1'; the first declared tab
    # takes it over rather than leaving a stray.
    first="${want%%,*}"
    if [ -n "$DRY" ]; then
      ws="(dry)"
    else
      ws="$(herdr workspace create --label "$label" | python3 -c "
import json,sys; print(json.load(sys.stdin)['result']['workspace']['workspace_id'])")"
      herdr tab rename "${ws}:t1" "$first" >/dev/null
    fi
    echo "  + $first (renamed from the initial tab)"
    have="$first"
  else
    have="$(ws_tabs_for "$label")"
    echo "space '$label' ($ws): present"
  fi

  IFS=',' read -ra want_arr <<<"$want"
  for tab in "${want_arr[@]}"; do
    if printf '%s' ",$have," | grep -q ",$tab,"; then
      continue
    fi
    echo "  + $tab"
    [ -n "$DRY" ] || herdr tab create --workspace "$ws" --label "$tab" >/dev/null
  done

  # Order can drift, and herdr's CLI exposes no tab.move, so this reports
  # rather than pretends to fix. A restart rebuilds tabs from session.json.
  if [ -z "$DRY" ]; then
    now="$(live_state | awk -F'|' -v l="$label" '$1==l {print $3; exit}')"
    compare_tabs "  $label" "$now" "$want" | grep -vE '^\s+\S+\s+ok\s' || true
  fi

  if [ -n "$WIRE" ]; then
    wire_args=("$label")
    [ "$host" = local ] || wire_args+=("$host")
    if [ -n "$DRY" ]; then
      DRY_RUN=1 "$HERE/herdr-wire-space.sh" "${wire_args[@]}" --policy "$POLICY" || true
    else
      "$HERE/herdr-wire-space.sh" "${wire_args[@]}" --policy "$POLICY" || true
    fi
  fi
done

echo "done.${DRY:+ (dry run — nothing changed)}"
