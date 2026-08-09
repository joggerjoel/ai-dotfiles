#!/usr/bin/env bash
# Tests for cache-guard.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Everything runs against a throwaway state dir + policy file with an
# injected clock (CACHE_GUARD_NOW), so no real session state is touched and
# no notification ever fires (CACHE_GUARD_NOTIFY=0 except the watcher tests,
# which use CACHE_GUARD_NOTIFY_CMD to append to a file instead).

HERE=$(cd "$(dirname "$0")" && pwd)
G="$HERE/cache-guard.sh"
pass=0 fail=0

TMP=$(mktemp -d -t cacheguard-test) || exit 1
trap 'rm -rf "$TMP"' EXIT
export CACHE_GUARD_STATE_DIR="$TMP/state"
export CACHE_GUARD_POLICY_FILE="$TMP/policy"
export CACHE_GUARD_NO_WATCHER=1
export CACHE_GUARD_NOTIFY=0

NOW=1700000000
SID=sess-abc123

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

policy() { printf '%s\n' "$@" > "$CACHE_GUARD_POLICY_FILE"; }
sub_policy() { policy "profile=subscription" "mode=${1:-warn}"; } # ttl 3600/600
api_policy() { policy "profile=api" "mode=${1:-warn}"; }          # ttl 300/60

state_file() { echo "$CACHE_GUARD_STATE_DIR/$SID.state"; }
telem_file() { echo "$CACHE_GUARD_STATE_DIR/$SID.telemetry"; }
sget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1; }

seed() { # last_activity [extra key=value lines...]
  mkdir -p "$CACHE_GUARD_STATE_DIR"
  { printf 'session_id=%s\nstarted_at=%s\nlast_activity=%s\n' "$SID" "$((NOW - 9000))" "$1"
    shift; printf '%s\n' "$@"; } > "$(state_file)"
}
seed_telemetry() { # context_tokens
  mkdir -p "$CACHE_GUARD_STATE_DIR"
  printf 'context_tokens=%s\ncache_read=1000\ncache_write=0\n' "$1" > "$(telem_file)"
}
reset_state() { rm -rf "$CACHE_GUARD_STATE_DIR"; }

hook() { # event [extra jq object] → sets OUT, RC
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  OUT=$(jq -cn --arg e "$1" --arg s "$SID" --argjson x "$extra" \
    '{hook_event_name:$e, session_id:$s, transcript_path:"/tmp/t.jsonl", cwd:"/tmp"} + $x' |
    CACHE_GUARD_NOW=$NOW "$G" 2>/dev/null)
  RC=$?
}

segment() { # statusline-json → sets OUT, RC
  OUT=$(printf '%s' "$1" | CACHE_GUARD_NOW=$NOW "$G" segment 2>/dev/null)
  RC=$?
}

sl_json() { # read write total → statusline JSON (null read/write if "null")
  jq -cn --arg s "$SID" --argjson r "$1" --argjson w "$2" --argjson t "$3" \
    '{session_id:$s, model:{id:"claude-fable-5",display_name:"Fable"},
      effort:{level:"high"}, fast_mode:false,
      context_window:{total_input_tokens:$t,
        current_usage:(if $r == null then null
          else {cache_read_input_tokens:$r, cache_creation_input_tokens:$w} end)}}'
}

echo "── first session / no prior state ─────────────────────"
sub_policy; reset_state
hook SessionStart '{"source":"startup"}'
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(sget "$(state_file)" session_id)" = "$SID" ]; then
  ok "SessionStart initializes state, silent exit 0"
else ko "SessionStart initializes state" "rc=$RC out=$OUT"; fi

echo "── cache states (subscription: ttl 3600, margin 600) ──"
sub_policy
seed "$((NOW - 100))"
segment "$(sl_json 184215 12000 190000)"
case "$OUT" in *"R184k/W12k"*"warm"*) ok "warm segment shows R/W + minutes" ;; *) ko "warm segment" "got: $OUT" ;; esac

seed "$((NOW - 3300))" # inside the 600s margin
segment "$(sl_json 184215 0 190000)"
case "$OUT" in *expiring*) ok "expiring segment inside warning margin" ;; *) ko "expiring segment" "got: $OUT" ;; esac

seed "$((NOW - 4000))"
segment "$(sl_json 184215 0 190000)"
case "$OUT" in *cold*) ok "cold segment past TTL" ;; *) ko "cold segment" "got: $OUT" ;; esac

segment "$(sl_json null null 0)" # current_usage null → no completed API call
case "$OUT" in *"Cache –"*) ok "no-API-call segment renders dim placeholder" ;; *) ko "null current_usage segment" "got: $OUT" ;; esac

seed "$((NOW - 100))"
segment "$(sl_json 5000 2000 9000)"
if [ "$(sget "$(telem_file)" context_tokens)" = 9000 ] && [ "$(sget "$(telem_file)" cache_read)" = 5000 ] &&
  [ "$(sget "$(telem_file)" fast_mode)" = false ]; then # false must not read as empty
  ok "segment records telemetry to state (incl. fast_mode=false)"
else ko "segment telemetry recording" "$(cat "$(telem_file)" 2>/dev/null)"; fi

echo "── cache states (api: ttl 300, margin 60) ─────────────"
api_policy
seed "$((NOW - 100))"
segment "$(sl_json 50000 0 60000)"
case "$OUT" in *warm*) ok "5-minute profile: warm at 100s idle" ;; *) ko "api warm" "got: $OUT" ;; esac
seed "$((NOW - 400))"
segment "$(sl_json 50000 0 60000)"
case "$OUT" in *cold*) ok "5-minute profile: cold at 400s idle" ;; *) ko "api cold" "got: $OUT" ;; esac

echo "── UserPromptSubmit: warn / protect ───────────────────"
sub_policy warn
seed "$((NOW - 4000))"; seed_telemetry 5000
hook UserPromptSubmit '{"prompt":"hi"}'
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "small cold context passes silently"
else ko "small cold context" "rc=$RC out=$OUT"; fi

seed "$((NOW - 4000))"; seed_telemetry 150000
hook UserPromptSubmit '{"prompt":"hi"}'
case "$OUT" in
  *'"decision"'*) ko "large cold context in warn mode" "unexpected block: $OUT" ;;
  *systemMessage*) ok "large cold context warned, not blocked (mode=warn)" ;;
  *) ko "large cold context in warn mode" "no warning: $OUT" ;;
esac
if [ "$(sget "$(state_file)" last_activity)" = "$NOW" ]; then
  ok "warned prompt still refreshes last_activity"
else ko "warn-mode activity refresh" "last_activity=$(sget "$(state_file)" last_activity)"; fi

sub_policy protect
seed "$((NOW - 4000))"; seed_telemetry 150000
hook UserPromptSubmit '{"prompt":"hi"}'
if [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e '.decision == "block" and (.reason | length > 0)' > /dev/null 2>&1; then
  ok "large cold context blocked (mode=protect)"
else ko "protect-mode block" "rc=$RC out=$OUT"; fi
if [ "$(sget "$(state_file)" last_activity)" = "$((NOW - 4000))" ]; then
  ok "blocked prompt does not refresh last_activity"
else ko "blocked prompt activity" "last_activity=$(sget "$(state_file)" last_activity)"; fi

seed "$((NOW - 100))"; seed_telemetry 150000
hook UserPromptSubmit '{"prompt":"hi"}'
if [ -z "$OUT" ]; then ok "warm large context passes in protect mode"
else ko "warm large context in protect mode" "out=$OUT"; fi

echo "── fail open ──────────────────────────────────────────"
OUT=$(printf '{not json' | CACHE_GUARD_NOW=$NOW "$G" 2>/dev/null); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "malformed JSON fails open"
else ko "malformed JSON" "rc=$RC out=$OUT"; fi

OUT=$(printf '' | "$G" 2>/dev/null); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "empty stdin fails open"
else ko "empty stdin" "rc=$RC out=$OUT"; fi

OUT=$(jq -cn '{hook_event_name:"UserPromptSubmit", session_id:"../../etc/passwd"}' | "$G" 2>/dev/null); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "path-traversal session_id rejected, fails open"
else ko "unsafe session_id" "rc=$RC out=$OUT"; fi

# jq genuinely absent: minimal PATH of symlinks to everything BUT jq.
mkdir -p "$TMP/nojq"
for c in bash sh cat date mkdir sed mv head rm find sleep kill uname dirname readlink awk grep ln; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$TMP/nojq/$c"
done
OUT=$(jq -cn --arg s "$SID" '{hook_event_name:"UserPromptSubmit", session_id:$s}' |
  PATH="$TMP/nojq" "$G" 2>/dev/null); RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "missing jq fails open"
else ko "missing jq" "rc=$RC out=$OUT"; fi

echo "── profile=off ────────────────────────────────────────"
policy "profile=off"
seed "$((NOW - 4000))"; seed_telemetry 150000
hook UserPromptSubmit '{"prompt":"hi"}'
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "off profile: prompt hook inert"
else ko "off profile prompt" "rc=$RC out=$OUT"; fi
segment "$(sl_json 5000 0 9000)"
if [ -z "$OUT" ]; then ok "off profile: no statusline segment"
else ko "off profile segment" "out=$OUT"; fi

echo "── PostCompact resets the context estimate ────────────"
sub_policy
seed "$((NOW - 100))" "warned_at=$((NOW - 50))"; seed_telemetry 150000
hook PostCompact '{"trigger":"manual","context_before":150000,"context_after":8000}'
if [ "$(sget "$(telem_file)" context_tokens)" = 8000 ] && [ -z "$(sget "$(state_file)" warned_at)" ]; then
  ok "PostCompact resets context estimate + warning latch"
else ko "PostCompact reset" "ctx=$(sget "$(telem_file)" context_tokens) warned=$(sget "$(state_file)" warned_at)"; fi

echo "── watcher lifecycle ──────────────────────────────────"
sub_policy
# Duplicate prevention: a live watcher pid must not be replaced.
sleep 60 & FAKE_PID=$!
seed "$((NOW - 100))" "watcher_pid=$FAKE_PID" "watcher_gen=1"
CACHE_GUARD_NO_WATCHER=0 CACHE_GUARD_NOTIFY=1 CACHE_GUARD_NOTIFY_CMD=/usr/bin/true \
  hook SessionStart '{"source":"startup"}'
if [ "$(sget "$(state_file)" watcher_pid)" = "$FAKE_PID" ]; then
  ok "live watcher not duplicated"
else ko "duplicate watcher prevention" "pid=$(sget "$(state_file)" watcher_pid)"; fi
kill "$FAKE_PID" 2>/dev/null

# Stale pid: dead watcher must be replaced by a live one, generation bumped.
sleep 1 & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
seed "$((NOW - 100))" "watcher_pid=$DEAD_PID" "watcher_gen=3"
CACHE_GUARD_NO_WATCHER=0 CACHE_GUARD_NOTIFY=1 CACHE_GUARD_NOTIFY_CMD=/usr/bin/true \
  CACHE_GUARD_WATCH_INTERVAL=600 hook SessionStart '{"source":"startup"}'
NEW_PID=$(sget "$(state_file)" watcher_pid)
if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$DEAD_PID" ] && kill -0 "$NEW_PID" 2>/dev/null &&
  [ "$(sget "$(state_file)" watcher_gen)" = 4 ]; then
  ok "stale watcher pid replaced (gen bumped)"
else ko "stale pid handling" "pid=$NEW_PID gen=$(sget "$(state_file)" watcher_gen)"; fi

# SessionEnd kills the watcher and removes state.
hook SessionEnd '{"reason":"other"}'
sleep 0.3
if [ ! -f "$(state_file)" ] && [ ! -f "$(telem_file)" ] && ! kill -0 "$NEW_PID" 2>/dev/null; then
  ok "SessionEnd kills watcher and removes state"
else ko "SessionEnd cleanup" "state=$([ -f "$(state_file)" ] && echo present) watcher=$(kill -0 "$NEW_PID" 2>/dev/null && echo alive)"; fi

# Live watcher notifies exactly once on an expiring large session (real clock).
REAL_NOW=$(date +%s)
NOTIFY_LOG="$TMP/notify.log"
cat > "$TMP/notify.sh" <<'EOF'
#!/usr/bin/env bash
echo "$1" >> "${NOTIFY_LOG_FILE}"
EOF
chmod +x "$TMP/notify.sh"
seed "$((REAL_NOW - 3300))" "watcher_gen=7" # expiring for sub profile
seed_telemetry 150000
NOTIFY_LOG_FILE="$NOTIFY_LOG" CACHE_GUARD_NOTIFY=1 CACHE_GUARD_NOTIFY_CMD="$TMP/notify.sh" \
  CACHE_GUARD_WATCH_INTERVAL=1 CACHE_GUARD_NOW='' "$G" watch "$SID" 7 &
WATCHER=$!
sleep 3
LINES=$(wc -l < "$NOTIFY_LOG" 2>/dev/null | tr -d ' ')
if [ "$LINES" = 1 ] && [ -n "$(sget "$(state_file)" warned_at)" ]; then
  ok "watcher notifies exactly once, latches warned_at"
else ko "watcher single notification" "lines=${LINES:-0}"; fi
rm -f "$(state_file)"
sleep 1.5
if ! kill -0 "$WATCHER" 2>/dev/null; then ok "watcher exits when state file disappears"
else ko "watcher exit on missing state"; kill "$WATCHER" 2>/dev/null; fi

echo "── privacy: no prompt/transcript content in state ─────"
sub_policy
reset_state
MARKER="XYZZY-super-secret-prompt-text-$$"
hook SessionStart '{"source":"startup"}'
hook UserPromptSubmit "{\"prompt\":\"$MARKER\"}"
hook Stop '{"last_assistant_message":"'"$MARKER"' reply"}'
if ! grep -rq "$MARKER" "$CACHE_GUARD_STATE_DIR" 2>/dev/null; then
  ok "state dir never contains prompt or transcript text"
else ko "prompt content leaked into state"; fi

echo "───────────────────────────────────────────────────────"
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
