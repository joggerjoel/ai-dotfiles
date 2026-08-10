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
EOF

fixture() { printf '%s\n' "$2" > "$HERDR_TMUX_FIXTURE/$1.tmuxls"; }

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
