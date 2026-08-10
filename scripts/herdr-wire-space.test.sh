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

# --- attach-tmux mapping -----------------------------------------------------
# In a tmux space the tab label is a session name, not a program name.

got=$(bash "$W" aorus8-tmux aorus8 --attach-tmux --print-command 07-dice-broadcast)
eq "attach-tmux -> attach by session name" \
   "ssh -t aorus8 'bash -lc '\\''tmux attach -t '\\''\\'\\'''\\''07-dice-broadcast'\\''\\'\\'''\\''; exec \$SHELL -l'\\'''" "$got"

# The cursor alias must NOT apply — a session may legitimately be named `cursor`.
got=$(bash "$W" aorus8-tmux aorus8 --attach-tmux --print-command cursor)
case "$got" in
  *"tmux attach -t"*) ok "attach-tmux overrides the cursor alias" ;;
  *) ko "attach-tmux overrides the cursor alias" "got [$got]" ;;
esac

# Likewise the tmux scratch mapping must not hijack a session named `tmux`.
got=$(bash "$W" aorus8-tmux aorus8 --attach-tmux --print-command tmux)
case "$got" in
  *"tmux attach -t"*) ok "attach-tmux overrides the scratch-session mapping" ;;
  *) ko "attach-tmux overrides the scratch-session mapping" "got [$got]" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
