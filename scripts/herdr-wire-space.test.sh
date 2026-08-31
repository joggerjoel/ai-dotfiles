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

# --- @model[:subdir] agent labels -------------------------------------------
#
# `@` marks an agent label and unlocks a working directory. The expected paths
# keep a literal $HOME so it expands on the REMOTE side inside `bash -lc`;
# expanding it here would bake this machine's home into a fleet command.

got=$(bash "$W" aorus2:reachpro aorus2 --policy bare --print-command @claude)
eq "@claude inherits the space topic as its directory" \
   "ssh -t aorus2 'bash -lc '\\''cd \$HOME/Developer/reachpro && claude'\\'''" "$got"

got=$(bash "$W" aorus5 aorus5 --policy bare --print-command @claude)
eq "@claude in a topicless space falls back to the base dir" \
   "ssh -t aorus5 'bash -lc '\\''cd \$HOME/Developer && claude'\\'''" "$got"

got=$(bash "$W" aorus2:reachpro aorus2 --policy bare --print-command @claude:other)
eq "an explicit :subdir overrides the inherited topic" \
   "ssh -t aorus2 'bash -lc '\\''cd \$HOME/Developer/other && claude'\\'''" "$got"

# The cursor->agent alias must survive the @ prefix being stripped.
got=$(bash "$W" aorus2:reachpro aorus2 --policy bare --print-command @cursor)
eq "@cursor is still aliased to agent, and still cds" \
   "ssh -t aorus2 'bash -lc '\\''cd \$HOME/Developer/reachpro && agent'\\'''" "$got"

# Regression guard: labels without @ must behave exactly as they did before,
# even inside a space whose label now carries a topic.
got=$(bash "$W" aorus2:reachpro aorus2 --policy bare --print-command tmux)
eq "a non-agent label gets no cd, even in a topic space" \
   "ssh -t aorus2 'bash -lc '\\''tmux new-session -A -s herdr'\\'''" "$got"

got=$(bash "$W" aorus2:reachpro aorus2 --policy bare --print-command htop)
eq "an arbitrary program label is untouched by the topic" \
   "ssh -t aorus2 'bash -lc '\\''htop'\\'''" "$got"

# The cd belongs INSIDE the policy wrapper, so a fallback shell also lands in
# the project directory instead of dumping the user in $HOME.
got=$(bash "$W" aorus2:reachpro aorus2 --print-command @claude)
eq "the fallback shell inherits the project directory" \
   "ssh -t aorus2 'bash -lc '\\''cd \$HOME/Developer/reachpro && claude; exec \$SHELL -l'\\'''" "$got"

# In a tmux space the label is a session name, so @ carries no meaning and must
# not smuggle in a cd.
got=$(bash "$W" aorus8-tmux aorus8 --attach-tmux --print-command @07-dice)
case "$got" in
  *"cd \$HOME/Developer"*) ko "attach-tmux ignores @ rather than adding a cd" "got [$got]" ;;
  *"tmux attach -t"*)      ok "attach-tmux ignores @ rather than adding a cd" ;;
  *)                       ko "attach-tmux ignores @ rather than adding a cd" "got [$got]" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
