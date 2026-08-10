#!/usr/bin/env bash
# Build a herdr space per fleet host holding its live tmux sessions.
#
# Unlike herdr-layout.sh, these spaces are DISCOVERED, not declared: a static
# list would drift from the fleet silently. The cost is that they cannot be
# rebuilt from version control — re-run `apply` after a restart.
#
# Usage:
#   herdr-tmux.sh [status|apply] [--dry-run] [--policy bare|fallback|reconnect]
#                                [--config <layout.conf>]
#
# --dry-run here differs from herdr-layout.sh: spaces and tabs are still
# created, only the final delegation to herdr-wire-space.sh (the part that
# actually attaches panes) is skipped.
#
# Rationale: references/herdr-tmux-spaces.md

set -euo pipefail

CONFIG="${HERDR_LAYOUT:-$HOME/.config/herdr/layout.conf}"
# HERE, DRY, and POLICY are plumbing for `apply` mode: HERE locates
# herdr-wire-space.sh to delegate wiring to, DRY skips that delegation, and
# POLICY is passed through to it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="status"
DRY=""
POLICY="fallback"

# Internal entry point used by the tests; parsed before the normal arg loop.
if [ "${1:-}" = _sessions ]; then
  MODE_SESSIONS=1; shift
else
  MODE_SESSIONS=""
fi

while [ $# -gt 0 ]; do
  case "$1" in
    status|apply) ACTION="$1"; shift ;;
    --dry-run)    DRY=1; shift ;;
    --policy)     POLICY="$2"; shift 2 ;;
    --config)     CONFIG="$2"; shift 2 ;;
    -h|--help)    sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            ARG_HOST="${ARG_HOST:-$1}"; shift ;;
  esac
done

# --- session discovery -------------------------------------------------------

# A session earns a tab unless its name is pure digits (debris from the old
# bare-`tmux` wiring) or is the `herdr` scratch session, which already has a
# tab in the host's main space.
qualifies() {
  [ -n "$1" ] || return 1
  [ "$1" != herdr ] || return 1
  case "$1" in
    *[!0-9]*) return 0 ;;
    *)        return 1 ;;
  esac
}

# Emits "<name>\t<attached|detached>" per qualifying session. Exit 255 from ssh
# (unreachable) propagates as an empty result plus a non-zero return.
live_sessions() {  # <host>
  local out
  # `tmux ls` exits 1 when the host is reachable but no tmux server is
  # running at all — that is not the same as ssh failing. `|| true` inside
  # the remote command folds that case into an empty, successful result so
  # only a genuine ssh failure (bad host, auth, timeout) trips the `|| return 1`.
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$1" \
        'bash -lc "tmux ls 2>/dev/null || true"' 2>/dev/null)" || return 1
  # The `|| true` matters as much as the trailing `return 0`: the loop's exit
  # status is the last `qualifies` test, so a trailing non-qualifying session
  # makes this pipeline fail — and under `set -e` a failing pipeline statement
  # exits the function immediately, before `return 0` is ever reached. Without
  # `|| true` here, that explicit `return 0` is dead code.
  printf '%s\n' "$out" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    local name state
    name="${line%%:*}"
    case "$line" in *"(attached)"*) state=attached ;; *) state=detached ;; esac
    qualifies "$name" && printf '%s\t%s\n' "$name" "$state"
  done || true
  # Reachability is already decided by the ssh guard above.
  return 0
}

if [ -n "$MODE_SESSIONS" ]; then
  live_sessions "${ARG_HOST:?usage: herdr-tmux.sh _sessions <host>}"
  exit $?
fi

# --- hosts from layout.conf --------------------------------------------------

[ -f "$CONFIG" ] || { echo "no layout config at $CONFIG" >&2; exit 1; }

HOSTS=()
while read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$line" ] || continue
  case "$line" in TABS=*) continue ;; esac
  # shellcheck disable=SC2206
  parts=($line)
  host="${parts[1]:-local}"
  [ "$host" = local ] || HOSTS+=("$host")
done < "$CONFIG"

[ ${#HOSTS[@]} -gt 0 ] || { echo "no remote hosts in $CONFIG" >&2; exit 1; }

# --- status ------------------------------------------------------------------

if [ "$ACTION" = status ]; then
  printf '%-10s %s\n' HOST SESSIONS
  for host in "${HOSTS[@]}"; do
    # Same reasoning as live_sessions(): a reachable host with no tmux server
    # running exits 1 on `tmux ls`, which is not "unreachable". `|| true`
    # folds that into an empty, successful result.
    if ! raw="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
                'bash -lc "tmux ls 2>/dev/null || true"' 2>/dev/null)"; then
      printf '%-10s unreachable\n' "$host"
      continue
    fi
    named=0 numeric=0 unattached=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      name="${line%%:*}"
      if qualifies "$name"; then
        named=$((named + 1))
      else
        [ "$name" = herdr ] || numeric=$((numeric + 1))
      fi
      case "$line" in *"(attached)"*) ;; *) unattached=$((unattached + 1)) ;; esac
    done <<<"$raw"

    if [ "$named" -eq 0 ]; then
      printf '%-10s skipped — 0 named, %d numeric\n' "$host" "$numeric"
    else
      printf '%-10s %d named, %d numeric (%d unattached)\n' \
        "$host" "$named" "$numeric" "$unattached"
    fi
  done
  exit 0
fi

# --- apply -------------------------------------------------------------------

ws_id_for() {  # <label>
  herdr workspace list | python3 -c "
import json,sys
label=sys.argv[1]
for w in json.load(sys.stdin)['result']['workspaces']:
    if w['label']==label:
        print(w['workspace_id']); break
" "$1"
}

ws_tabs_for() {  # <workspace-id>
  herdr tab list | python3 -c "
import json,sys
ws=sys.argv[1]
for t in json.load(sys.stdin)['result']['tabs']:
    if t['workspace_id']==ws:
        print(t['label'])
" "$1"
}

for host in "${HOSTS[@]}"; do
  if ! sessions="$(live_sessions "$host")"; then
    echo "host '$host': unreachable — skipped" >&2
    continue
  fi

  names=()
  while IFS=$'\t' read -r name _state; do
    [ -n "$name" ] && names+=("$name")
  done <<<"$sessions"

  if [ ${#names[@]} -eq 0 ]; then
    echo "host '$host': no qualifying sessions — skipped"
    continue
  fi

  label="${host}-tmux"
  ws="$(ws_id_for "$label")"

  if [ -z "$ws" ]; then
    echo "space '$label': creating"
    first="${names[0]}"
    ws="$(herdr workspace create --label "$label" | python3 -c "
import json,sys; print(json.load(sys.stdin)['result']['workspace']['workspace_id'])")"
    # A new workspace arrives with one tab labelled '1'; the first session takes
    # it over rather than leaving a stray.
    herdr tab rename "${ws}:t1" "$first" >/dev/null
    echo "  + $first (renamed from the initial tab)"
    have="$first"
  else
    echo "space '$label' ($ws): present"
    have="$(ws_tabs_for "$ws" | tr '\n' ',')"
  fi

  for name in "${names[@]}"; do
    if printf '%s' ",$have," | grep -qF ",$name,"; then
      continue
    fi
    echo "  + $name"
    herdr tab create --workspace "$ws" --label "$name" >/dev/null
    have="$have,$name"
  done

  if [ -z "$DRY" ]; then
    "$HERE/herdr-wire-space.sh" "$label" "$host" --attach-tmux --policy "$POLICY" || true
  fi
done

echo "done.${DRY:+ (dry run — spaces built, nothing wired)}"
