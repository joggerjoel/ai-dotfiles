#!/usr/bin/env bash
# Tests for agenttrail-hook.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# The wrapper exists because five unguarded `node .../agenttrail.mjs hook`
# entries threw MODULE_NOT_FOUND on every tool call when the 3rdparty checkout
# was absent. These tests pin both halves of the contract: silent, valid
# degradation when it is missing, and complete transparency when it is present.
#
# Both the binary path and the breadcrumb stamp are overridable, so nothing
# here touches the real checkout or the real ~/.claude/hooks/.logs.

HERE=$(cd "$(dirname "$0")" && pwd)
G="$HERE/agenttrail-hook.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/agenttrail-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

STAMP=$TMP/stamp
MISSING=$TMP/nope/agenttrail.mjs
EVENT='{"hook_event_name":"PreToolUse","tool_name":"Bash"}'

run_missing() {  # -> stdout in $OUT, stderr in $ERR, status in $ST
  OUT=$(printf '%s' "$EVENT" \
    | AGENTTRAIL_BIN="$MISSING" AGENTTRAIL_STAMP="$STAMP" bash "$G" 2>"$TMP/err")
  ST=$?
  ERR=$(cat "$TMP/err")
}

# ── missing checkout ────────────────────────────────────────────────────────

rm -f "$STAMP"
run_missing
[ "$ST" = 0 ] && ok "exits 0 when the checkout is absent" \
  || ko "exits 0 when the checkout is absent" "got $ST"

[ "$OUT" = "{}" ] && ok "emits the no-op hook response" \
  || ko "emits the no-op hook response" "got '$OUT'"

case $ERR in
  *"not installed"*) ok "warns once when the stamp is cold" ;;
  *) ko "warns once when the stamp is cold" "stderr was '$ERR'" ;;
esac

# A stack trace is the exact symptom this wrapper removes.
case $ERR in
  *MODULE_NOT_FOUND*|*"cjs/loader"*) ko "never leaks a node stack trace" "$ERR" ;;
  *) ok "never leaks a node stack trace" ;;
esac

# Second run, stamp now fresh.
run_missing
[ -z "$ERR" ] && ok "stays silent while the stamp is fresh" \
  || ko "stays silent while the stamp is fresh" "stderr was '$ERR'"
[ "$OUT" = "{}" ] && ok "still answers {} on a suppressed run" \
  || ko "still answers {} on a suppressed run" "got '$OUT'"

# Age the stamp past a day.
touch -t "$(date -v-2d +%Y%m%d%H%M 2>/dev/null || date -d '2 days ago' +%Y%m%d%H%M)" "$STAMP"
run_missing
case $ERR in
  *"not installed"*) ok "warns again once the stamp is a day old" ;;
  *) ko "warns again once the stamp is a day old" "stderr was '$ERR'" ;;
esac

# stdin must be consumed, or the writer can take EPIPE. Prove the hook reads it
# by handing it more than a pipe buffer and checking it still exits cleanly.
BIG=$(head -c 200000 /dev/zero | tr '\0' 'x')
printf '%s' "$BIG" | AGENTTRAIL_BIN="$MISSING" AGENTTRAIL_STAMP="$STAMP" \
  bash "$G" >/dev/null 2>&1
[ $? = 0 ] && ok "drains a large stdin without failing" \
  || ko "drains a large stdin without failing"

# ── present checkout ────────────────────────────────────────────────────────

BIN=$TMP/agenttrail.mjs
printf 'unused\n' > "$BIN"
FAKEBIN=$TMP/bin
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/node" <<'FAKE'
#!/usr/bin/env bash
# Echo back what the wrapper handed us so the test can assert pass-through.
printf 'node-called:%s\n' "$*"
cat >/dev/null
exit 7
FAKE
chmod +x "$FAKEBIN/node"

OUT=$(printf '%s' "$EVENT" | PATH="$FAKEBIN:$PATH" \
  AGENTTRAIL_BIN="$BIN" AGENTTRAIL_STAMP="$STAMP" bash "$G" 2>"$TMP/err")
ST=$?

case $OUT in
  "node-called:$BIN hook") ok "execs the real hook with its argument intact" ;;
  *) ko "execs the real hook with its argument intact" "got '$OUT'" ;;
esac

# exec means the child's status IS the hook's status. An installed agenttrail
# that genuinely fails must stay visible rather than be masked by the guard.
[ "$ST" = 7 ] && ok "passes the child's exit code through untouched" \
  || ko "passes the child's exit code through untouched" "got $ST"

rm -f "$STAMP"
printf '%s' "$EVENT" | PATH="$FAKEBIN:$PATH" AGENTTRAIL_BIN="$BIN" \
  AGENTTRAIL_STAMP="$STAMP" bash "$G" >/dev/null 2>/dev/null
[ ! -f "$STAMP" ] && ok "writes no breadcrumb when the checkout is present" \
  || ko "writes no breadcrumb when the checkout is present"

# ── node itself absent ──────────────────────────────────────────────────────

# A realistic no-node PATH, not an empty one: node is installed via nvm under
# $HOME, so the system directories genuinely lack it while still providing the
# coreutils the wrapper needs. An empty PATH is not a state Claude Code creates.
OUT=$(printf '%s' "$EVENT" | PATH="/usr/bin:/bin" AGENTTRAIL_BIN="$BIN" \
  AGENTTRAIL_STAMP="$TMP/stamp2" bash "$G" 2>/dev/null)
ST=$?
[ "$ST" = 0 ] && [ "$OUT" = "{}" ] \
  && ok "degrades the same way when node is missing entirely" \
  || ko "degrades the same way when node is missing entirely" "st=$ST out='$OUT'"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
