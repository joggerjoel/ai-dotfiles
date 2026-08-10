#!/usr/bin/env bash
# Tests for herdr-tmux.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# ssh and herdr are served by stubs on PATH, so nothing here touches the fleet.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
T="$HERE/herdr-tmux.sh"
pass=0 fail=0

TMP=$(mktemp -d -t herdrtmux-test) || exit 1
trap 'rm -rf "$TMP"' EXIT

export PATH="$ROOT/tests/tmux-stubs:$PATH"
export HERDR_TMUX_FIXTURE="$TMP/fixture"
mkdir -p "$HERDR_TMUX_FIXTURE"

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

# A layout config with one local row and two remote rows.
CONF="$TMP/layout.conf"
cat > "$CONF" <<'EOF'
TABS=claude,codex,cursor,pi,tmux
macstudio   local
aorus8      aorus8
aorus5      aorus5
aorus6      aorus6
EOF

fixture() { printf '%s\n' "$2" > "$HERDR_TMUX_FIXTURE/$1.tmuxls"; }

# aorus6 is reachable but never has a fixture written for it below — it stays
# a genuinely empty file throughout, standing in for a host with no tmux
# server running at all (real `tmux ls` exits 1 there; see tests/tmux-stubs/ssh).
: > "$HERDR_TMUX_FIXTURE/aorus6.tmuxls"

# --- qualifying filter -------------------------------------------------------

fixture aorus8 '07-dice-broadcast: 1 windows (created Fri Jul 17 18:57:21 2026)
10: 1 windows (created Fri Jul 10 07:51:25 2026)
herdr: 1 windows (created Mon Aug 10 16:23:26 2026) (attached)
06-go-events-dice: 1 windows (created Fri Jul 24 09:52:57 2026) (attached)'

got=$(bash "$T" _sessions aorus8 | cut -f1 | tr '\n' ',')
eq "numeric and herdr sessions are filtered out" \
   "07-dice-broadcast,06-go-events-dice," "$got"

got=$(bash "$T" _sessions aorus8 | grep '^06-go-events-dice' | cut -f2)
eq "attached state is parsed" "attached" "$got"

got=$(bash "$T" _sessions aorus8 | grep '^07-dice-broadcast' | cut -f2)
eq "detached state is parsed" "detached" "$got"

# --- a host with only debris -------------------------------------------------

fixture aorus5 '0: 1 windows (created Mon Aug 10 16:19:04 2026)
1: 1 windows (created Mon Aug 10 16:23:27 2026) (attached)'

got=$(bash "$T" _sessions aorus5 | wc -l | tr -d ' ')
eq "a host of pure debris yields no qualifying sessions" "0" "$got"

# Exit status must not depend on whether the LAST line qualified — callers use
# a non-zero return to mean "unreachable".
bash "$T" _sessions aorus5 >/dev/null 2>&1 \
  && ok "a reachable host with no qualifying sessions still exits 0" \
  || ko "a reachable host with no qualifying sessions still exits 0" "non-zero exit"

# --- reachable host, no tmux server running ----------------------------------
# `tmux ls` itself exits 1 when there is no server at all — not the same as
# ssh failing. A host in this state must read as zero sessions, not
# "unreachable" (see tests/tmux-stubs/ssh for how the empty aorus6 fixture
# reproduces that distinction).

got=$(bash "$T" _sessions aorus6 | wc -l | tr -d ' ')
eq "a reachable host with no tmux server yields zero sessions" "0" "$got"

bash "$T" _sessions aorus6 >/dev/null 2>&1 \
  && ok "a reachable host with no tmux server still exits 0 (not unreachable)" \
  || ko "a reachable host with no tmux server still exits 0 (not unreachable)" "non-zero exit"

# --- status ------------------------------------------------------------------

out=$(bash "$T" status --config "$CONF")

case "$out" in
  *"aorus8"*"2 named"*) ok "status counts named sessions" ;;
  *) ko "status counts named sessions" "got [$out]" ;;
esac

case "$out" in
  *"aorus8"*"1 numeric"*) ok "status counts numeric sessions" ;;
  *) ko "status counts numeric sessions" "got [$out]" ;;
esac

case "$out" in
  *"aorus5"*"skipped"*) ok "a host with no qualifying sessions is skipped" ;;
  *) ko "a host with no qualifying sessions is skipped" "got [$out]" ;;
esac

case "$out" in
  *"aorus6"*"skipped — 0 named, 0 numeric"*)
    ok "a reachable host with no tmux server is skipped, not unreachable" ;;
  *)
    ko "a reachable host with no tmux server is skipped, not unreachable" "got [$out]" ;;
esac

case "$out" in
  *"aorus6"*unreachable*)
    ko "a reachable host with no tmux server must never be reported unreachable" "got [$out]" ;;
  *)
    ok "a reachable host with no tmux server must never be reported unreachable" ;;
esac

# The layout label ("macstudio") never appears in status output regardless of
# whether local rows are skipped — herdr-tmux.sh only ever prints the HOST
# column. What actually proves a local row was skipped is that no status line
# is emitted for a host named "local" (the guard-broken line would start
# "local     unreachable", per the %-10s host column).
got=$(printf '%s\n' "$out" | grep -c '^local[[:space:]]')
eq "local rows are not probed" "0" "$got"

# --- unreachable host --------------------------------------------------------

rm -f "$HERDR_TMUX_FIXTURE/aorus8.tmuxls"
out=$(bash "$T" status --config "$CONF" 2>&1)
case "$out" in
  *"aorus8"*unreachable*) ok "an unreachable host is reported, not fatal" ;;
  *) ko "an unreachable host is reported, not fatal" "got [$out]" ;;
esac

# --- apply -------------------------------------------------------------------

export HERDR_TMUX_CALLS="$TMP/calls"
export HERDR_TMUX_WS="$TMP/ws"
export HERDR_TMUX_TABS="$TMP/tabs"

reset_state() { : > "$HERDR_TMUX_CALLS"; : > "$HERDR_TMUX_WS"; : > "$HERDR_TMUX_TABS"; }

fixture aorus8 '07-dice-broadcast: 1 windows (created Fri Jul 17 18:57:21 2026)
10: 1 windows (created Fri Jul 10 07:51:25 2026)
06-go-events-dice: 1 windows (created Fri Jul 24 09:52:57 2026) (attached)'
fixture aorus5 '0: 1 windows (created Mon Aug 10 16:19:04 2026)'

reset_state
# Deliberately no `>/dev/null 2>&1` and no `|| true` on this invocation — both
# would hide a crash behind a passing grep, which is exactly how the previous
# version of "a host with no qualifying sessions gets no space" stayed green
# even after the zero-session skip block was deleted from herdr-tmux.sh.
apply_out=$(bash "$T" apply --config "$CONF" --dry-run 2>&1)
apply_status=$?

got=$(grep -c 'workspace create --label aorus8-tmux' "$HERDR_TMUX_CALLS" || true)
eq "apply creates the <host>-tmux space" "1" "$got"

got=$(grep -c 'workspace create --label aorus5-tmux' "$HERDR_TMUX_CALLS" || true)
eq "a host with no qualifying sessions makes no workspace-create call" "0" "$got"

# The positive contract: apply must actually print a skip line naming the
# host, and must exit 0 — not merely fail to have called `workspace create`
# (which a crash would also produce).
case "$apply_out" in
  *"host 'aorus5': no qualifying sessions — skipped"*)
    ok "a host with no qualifying sessions prints a skip line naming it" ;;
  *)
    ko "a host with no qualifying sessions prints a skip line naming it" "got [$apply_out]" ;;
esac

[ "$apply_status" -eq 0 ] \
  && ok "apply exits 0 when a host has no qualifying sessions" \
  || ko "apply exits 0 when a host has no qualifying sessions" "exit $apply_status"

# One tab per qualifying session: the first takes over the workspace's initial
# tab via rename, the rest are created.
got=$(grep -c 'tab rename' "$HERDR_TMUX_CALLS" || true)
eq "the initial tab is renamed rather than left stray" "1" "$got"

got=$(grep -c 'tab create' "$HERDR_TMUX_CALLS" || true)
eq "remaining sessions each get a tab" "1" "$got"

# Idempotence: with the space and both tabs already present, nothing is created.
reset_state
printf 'w7|aorus8-tmux\n' > "$HERDR_TMUX_WS"
printf 't1|w7|07-dice-broadcast\nt2|w7|06-go-events-dice\n' > "$HERDR_TMUX_TABS"
bash "$T" apply --config "$CONF" --dry-run >/dev/null 2>&1 || true

got=$(grep -c 'create' "$HERDR_TMUX_CALLS" || true)
eq "re-running apply creates nothing" "0" "$got"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
