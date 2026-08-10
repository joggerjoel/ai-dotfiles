#!/usr/bin/env bash
# Wire every tab of a herdr space to its program. The tab's label IS the program,
# with one alias: the `cursor` tab runs `agent` (cursor-agent).
#
# herdr's API (tab.create / workspace.create) accepts only cwd/env/label/focus —
# there is no "command" field, so a new tab always spawns a plain login shell.
# Execution is a separate step against the live pane, which is why this script
# exists and why nothing here needs a herdr restart.
#
# Usage: herdr-wire-space.sh <space-label> [ssh-host] [--policy bare|fallback|reconnect]
#   local space:  herdr-wire-space.sh macstudio
#   remote space: herdr-wire-space.sh aorus4 aorus4
#   dry run:      DRY_RUN=1 herdr-wire-space.sh aorus4 aorus4

set -euo pipefail

SPACE_LABEL=""
SSH_HOST=""
POLICY="fallback"
PRINT_COMMAND=""
ATTACH_TMUX=""

while [ $# -gt 0 ]; do
  case "$1" in
    --policy) POLICY="$2"; shift 2 ;;
    --print-command) PRINT_COMMAND="$2"; shift 2 ;;
    --attach-tmux) ATTACH_TMUX=1; shift ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *) if [ -z "$SPACE_LABEL" ]; then SPACE_LABEL="$1"; else SSH_HOST="$1"; fi; shift ;;
  esac
done

[ -n "$SPACE_LABEL" ] || { echo "usage: herdr-wire-space.sh <space-label> [ssh-host] [--policy P]" >&2; exit 2; }

case "$POLICY" in bare|fallback|reconnect) ;; *) echo "bad policy: $POLICY" >&2; exit 2 ;; esac

# --- tab label -> program ---------------------------------------------------

program_for_tab() {
  # In a tmux space the label IS a session name, so no alias applies — a
  # session may legitimately be called `cursor` or `tmux`.
  if [ -n "$ATTACH_TMUX" ]; then
    printf 'tmux attach -t %s' "$(sq "$1")"
    return
  fi
  case "$1" in
    cursor) echo "agent" ;;   # `agent` and `cursor-agent` are the same binary
    tmux)   echo "tmux new-session -A -s herdr" ;;  # attach-or-create; bare
                                                    # `tmux` spawned a new
                                                    # session on every wiring
    *)      echo "$1" ;;      # claude, codex, pi run under their own name
  esac
}

# --- build the command a pane should run ------------------------------------
#
# A remote command MUST go through a login shell. A non-interactive `ssh host cmd`
# gets a truncated PATH: `command -v codex` fails on every aorus box that way, but
# succeeds under `bash -lc`. Skipping this produces "command not found" in panes
# that are actually configured correctly.

sq() {  # single-quote a string for safe embedding in a shell command line
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

command_for_tab() {
  local prog; prog="$(program_for_tab "$1")"

  if [ -z "$SSH_HOST" ]; then                      # local space
    case "$POLICY" in
      bare)      echo "$prog" ;;
      fallback)  echo "$prog; exec \$SHELL -l" ;;
      reconnect) echo "until $prog; do sleep 5; done" ;;
    esac
    return
  fi

  local remote                                     # remote space
  case "$POLICY" in
    bare)      remote="$prog" ;;
    fallback)  remote="$prog; exec \$SHELL -l" ;;
    reconnect) remote="until $prog; do sleep 5; done" ;;
  esac

  local inner; inner="bash -lc $(sq "$remote")"
  if [ "$POLICY" = reconnect ]; then
    echo "until ssh -t $SSH_HOST $(sq "$inner"); do sleep 5; done"
  else
    echo "ssh -t $SSH_HOST $(sq "$inner")"
  fi
}

# Print one tab's command and exit. No API call, no ssh — this is the seam the
# tests drive, and a quick way to see what a pane would actually be sent.
if [ -n "$PRINT_COMMAND" ]; then
  command_for_tab "$PRINT_COMMAND"
  exit 0
fi

# --- resolve the space, then its tabs ---------------------------------------

WS="$(herdr workspace list | python3 -c "
import json,sys
label=sys.argv[1]
for w in json.load(sys.stdin)['result']['workspaces']:
    if w['label']==label:
        print(w['workspace_id']); break
else:
    sys.exit('no space labeled %r' % label)
" "$SPACE_LABEL")"

# --- refuse to wire a host that isn't reachable -----------------------------
# Firing ssh at an unreachable host leaves every pane on a timeout, which looks
# identical to a misconfigured space. Fail loudly instead.

if [ -n "$SSH_HOST" ] && [ -z "${DRY_RUN:-}" ]; then
  if ! ssh -o BatchMode=yes -o ConnectTimeout=6 "$SSH_HOST" true 2>/dev/null; then
    echo "error: $SSH_HOST is not reachable over ssh — not wiring '$SPACE_LABEL'." >&2
    exit 1
  fi
fi

echo "space '$SPACE_LABEL' ($WS) -> ${SSH_HOST:-local}  [policy: $POLICY]${DRY_RUN:+  (dry run)}"

# Emits "<tab-label> <pane-id> <busy|free>". A pane is busy when herdr has already
# detected an agent in it — sending text there would type into a running program.
herdr pane list | python3 -c "
import json,sys,subprocess
ws=sys.argv[1]
tabs={t['tab_id']:t['label'] for t in json.loads(subprocess.run(['herdr','tab','list'],capture_output=True,text=True).stdout)['result']['tabs']}
for p in json.load(sys.stdin)['result']['panes']:
    if p['workspace_id']==ws:
        busy = bool(p.get('agent')) or p.get('agent_status') not in (None,'unknown')
        print(tabs.get(p['tab_id'],'?'), p['pane_id'], 'busy' if busy else 'free')
" "$WS" | while read -r tab_label pane_id state; do
  # Never wire the pane this script is running from — that injects into our own stdin.
  if [ "$pane_id" = "${HERDR_PANE_ID:-}" ]; then
    echo "  $tab_label ($pane_id): SKIP — this is the pane running this script"
    continue
  fi
  if [ "$state" = busy ] && [ -z "${FORCE:-}" ]; then
    echo "  $tab_label ($pane_id): SKIP — agent already running (FORCE=1 to override)"
    continue
  fi
  cmd="$(command_for_tab "$tab_label")"
  echo "  $tab_label ($pane_id): $cmd"
  [ -n "${DRY_RUN:-}" ] || herdr pane run "$pane_id" "$cmd" >/dev/null
done

echo "done."
