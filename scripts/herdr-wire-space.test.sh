#!/usr/bin/env bash
# Tests for herdr-wire-space.sh command construction. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a hook.
#
# --print-command exits before any herdr or ssh call, so these tests need no
# stubs and never touch the fleet.

HERE=$(cd "$(dirname "$0")" && pwd)
W="$HERE/herdr-wire-space.sh"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

eq() {  # <description> <expected> <actual>
  [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"
}

# --- local space, fallback policy -------------------------------------------

got=$(bash "$W" macstudio --print-command claude)
eq "local claude -> bare program with fallback" \
   'claude; exec $SHELL -l' "$got"

got=$(bash "$W" macstudio --print-command cursor)
eq "local cursor -> aliased to agent" \
   'agent; exec $SHELL -l' "$got"

# The orphan fix: bare `tmux` created a new session on every run.
got=$(bash "$W" macstudio --print-command tmux)
eq "local tmux -> attach-or-create the herdr scratch session" \
   'tmux new-session -A -s herdr; exec $SHELL -l' "$got"

# --- remote space ------------------------------------------------------------

got=$(bash "$W" aorus8 aorus8 --print-command tmux)
eq "remote tmux -> scratch session through a login shell" \
   "ssh -t aorus8 'bash -lc '\\''tmux new-session -A -s herdr; exec \$SHELL -l'\\'''" "$got"

got=$(bash "$W" aorus8 aorus8 --policy bare --print-command claude)
eq "remote claude, bare policy -> no fallback shell" \
   "ssh -t aorus8 'bash -lc '\\''claude'\\'''" "$got"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
