#!/bin/bash
# herdr-monitor-workspace.sh — make sure every herdr machine has a workspace
# labelled "monitor" showing the system monitors, and create it where absent.
#
# The monitor itself is NOT defined here. tmux/server-metrics.yaml (deployed to
# ~/.tmuxp/ by setup.sh) is the one definition of "the monitor": glances on the
# left, htop and top stacked on the right. This script only gives it a herdr
# home: a workspace labelled "monitor" whose root pane loads that session, or
# runs bare glances on a host where tmuxp never landed.
#
# Targets: `local` (the herdr server on this machine) plus every ENABLED saved
# SSH machine from `herdr machine list`. Pass machine labels to narrow it, e.g.
#   herdr-monitor-workspace.sh aorus4 macstudio
#
# Idempotent: a machine that already has a workspace labelled "monitor" is left
# alone and reported as current, whatever that workspace contains — a hand-made
# monitor is still the user's monitor. Nothing is ever closed or replaced.
#
# Output: one line per machine, then a summary line:
#   herdr-monitor-workspace: created=N current=N failed=N
# Exits 1 when any machine failed, 0 otherwise. A machine whose server is not
# reachable is a failure, not a skip: the recipe exists to converge the fleet,
# and an unreachable host is a host it did not converge.
#
# Callers: justfile (herdr-monitor). Tests: herdr-monitor-workspace.test.sh.

set -uo pipefail

HERDR_BIN="${HERDR_BIN:-herdr}"
MONITOR_LABEL="${HERDR_MONITOR_LABEL:-monitor}"
# One line on purpose: `pane run` submits it to the pane's shell as typed input,
# and macOS rejects a submission longer than the tty's canonical line limit.
# The session is loaded by PATH, not by name: setup.sh deploys to ~/.tmuxp/,
# but which directory tmuxp searches depends on the release (1.74 from uv reads
# ~/.tmuxp/, 1.9 from apt reads ~/.config/tmuxp/), so `tmuxp load
# server-metrics` is "config not found" on part of the fleet.
MONITOR_CMD='if command -v tmuxp >/dev/null 2>&1 && [ -f "$HOME/.tmuxp/server-metrics.yaml" ]; then tmuxp load -y "$HOME/.tmuxp/server-metrics.yaml"; else glances; fi'
# glances and htop both print a CPU gauge within a second of starting; a shell
# that printed "command not found" instead never will. Milliseconds.
MONITOR_READY_TIMEOUT="${HERDR_MONITOR_READY_TIMEOUT:-20000}"

if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; DIM=""; RESET=""
fi
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
skip() { printf '  %s○ %s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }

if ! command -v "$HERDR_BIN" >/dev/null 2>&1; then
  skip "herdr not installed — nothing to converge"
  echo "herdr-monitor-workspace: created=0 current=0 failed=0"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required to read herdr's JSON replies"
  exit 1
fi

# herdr <machine-prefix...> <command...>. The local server is addressed with no
# prefix; a saved machine with --machine <label>, which herdr forwards over SSH.
hd() {
  local machine=$1; shift
  if [ "$machine" = "local" ]; then
    "$HERDR_BIN" "$@"
  else
    "$HERDR_BIN" --machine "$machine" "$@"
  fi
}

# Extract one field from a herdr JSON reply by a dotted path under .result.
json_field() {
  python3 -c '
import json, sys
try:
    node = json.load(sys.stdin)["result"]
    for key in sys.argv[1].split("."):
        node = node[key]
    print(node)
except Exception:
    sys.exit(1)
' "$1"
}

# Print the workspace_id of the workspace with the monitor label, if any.
find_monitor() {
  python3 -c '
import json, sys
try:
    for ws in json.load(sys.stdin)["result"]["workspaces"]:
        if ws.get("label") == sys.argv[1]:
            print(ws["workspace_id"]); break
except Exception:
    sys.exit(1)
' "$MONITOR_LABEL"
}

# Columns: id label target session enabled|disabled. Plain output, not --json:
# it needs no parser and is what the user already reads.
enabled_machines() {
  "$HERDR_BIN" machine list 2>/dev/null | awk -F'\t' '$5 == "enabled" { print $2 }'
}

created=0 current=0 failed=0

converge() {
  local machine=$1 listing wid created_json pane_id
  if ! listing=$(hd "$machine" workspace list 2>&1); then
    fail "$machine: herdr server unreachable — ${listing##*$'\n'}"
    failed=$((failed + 1)); return
  fi
  if wid=$(printf '%s' "$listing" | find_monitor) && [ -n "$wid" ]; then
    ok "$machine: \"$MONITOR_LABEL\" workspace present ($wid)"
    current=$((current + 1)); return
  fi

  # --no-focus: converging the fleet must not yank the user's view on any
  # machine. --cwd '~' and not $HOME: herdr expands it on the TARGET, so a Mac
  # control node does not hand a Linux host /Users/<you>. Omitting it would
  # inherit whichever pane happens to be focused there; the monitor belongs to
  # the host, not to a repo.
  if ! created_json=$(hd "$machine" workspace create --cwd '~' --label "$MONITOR_LABEL" --no-focus 2>&1); then
    fail "$machine: workspace create failed — ${created_json##*$'\n'}"
    failed=$((failed + 1)); return
  fi
  if ! wid=$(printf '%s' "$created_json" | json_field workspace.workspace_id) \
     || ! pane_id=$(printf '%s' "$created_json" | json_field root_pane.pane_id); then
    fail "$machine: unexpected create reply — $created_json"
    failed=$((failed + 1)); return
  fi

  if ! hd "$machine" pane run "$pane_id" "$MONITOR_CMD" >/dev/null 2>&1; then
    fail "$machine: created $wid but could not start the monitor in $pane_id"
    failed=$((failed + 1)); return
  fi
  # `pane run` only acknowledges that the text was queued. Prove the monitor
  # drew something before calling this done.
  if hd "$machine" pane wait-output "$pane_id" --match CPU --timeout "$MONITOR_READY_TIMEOUT" >/dev/null 2>&1; then
    ok "$machine: created \"$MONITOR_LABEL\" workspace ($wid), monitor running"
  else
    warn "$machine: created \"$MONITOR_LABEL\" workspace ($wid) but no metrics within ${MONITOR_READY_TIMEOUT}ms — inspect: herdr $([ "$machine" = local ] || printf -- '--machine %s ' "$machine")pane read $pane_id"
  fi
  created=$((created + 1))
}

if [ $# -gt 0 ]; then
  targets=("$@")
else
  targets=(local)
  while IFS= read -r label; do
    [ -n "$label" ] && targets+=("$label")
  done < <(enabled_machines)
fi

for machine in "${targets[@]}"; do
  converge "$machine"
done

echo "herdr-monitor-workspace: created=$created current=$current failed=$failed"
[ "$failed" -eq 0 ]
