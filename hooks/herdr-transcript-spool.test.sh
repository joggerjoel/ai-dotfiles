#!/usr/bin/env bash
# Tests for herdr-transcript-spool.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Everything runs against a throwaway HERDR_MASTER_ROOT with a frozen clock
# (HERDR_SPOOL_NOW) and a throwaway KITCHEN_STATE_DIR, so neither a real supervisor
# spool nor a real Kitchen is ever touched. The Kitchen cases talk to a one-shot
# loopback listener that writes the request it received to a file.

HERE=$(cd "$(dirname "$0")" && pwd)
G="$HERE/herdr-transcript-spool.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdrspool-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HERDR_MASTER_ROOT="$TMP/state"
export HERDR_SPOOL_NOW=2026-09-15T12:00:00Z
export KITCHEN_STATE_DIR="$TMP/agent-office"
KITCHEN_TOKEN=hook-token-01

SID=sess-abc123
TRANSCRIPT=$TMP/projects/session-1.jsonl
AGENT=$TMP/projects/subagents/agent-7.jsonl
# The hook resolves the working directory before hashing it, so it has to exist.
CWD=$TMP/tree
mkdir -p "$CWD"

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

spool() { echo "$HERDR_MASTER_ROOT/transcript-spool.jsonl"; }
reset_spool() { rm -rf "$HERDR_MASTER_ROOT"; }
lines() { wc -l < "$(spool)" 2>/dev/null | tr -d ' '; }

payload() { # event [extra jq object]
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  jq -cn --arg e "$1" --arg s "$SID" --arg t "$TRANSCRIPT" --arg c "$CWD" --argjson x "$extra" \
    '{hook_event_name:$e, session_id:$s, transcript_path:$t, cwd:$c} + $x'
}

run() { # raw-stdin → sets OUT, RC
  OUT=$(printf '%s' "$1" | "$G" 2>/dev/null)
  RC=$?
}

resolved() { (cd "$1" 2>/dev/null && pwd -P); }

marker_file() { # cwd → the path herdr_master/kitchen.py would write
  local digest
  digest=$(printf '%s' "$(resolved "$1")" | shasum -a 256 | cut -d' ' -f1)
  echo "$HERDR_MASTER_ROOT/role-markers/$digest.json"
}

write_marker() { # role [cwd]
  local path
  path=$(marker_file "${2:-$CWD}")
  mkdir -p "$(dirname "$path")"
  jq -cn --arg r "$1" \
    '{role:$r, workflow_id:"herdr", unit_id:"unit-1", attempt:1,
      written_at:"2026-09-15T12:00:00+00:00"}' > "$path"
}

start_kitchen() { # → sets KITCHEN_LOG; writes server.json once the port is known
  KITCHEN_LOG="$TMP/kitchen-requests.$RANDOM.jsonl"
  : > "$KITCHEN_LOG"
  local port_file="$TMP/kitchen-port.$RANDOM"
  python3 - "$KITCHEN_LOG" "$port_file" <<'PY' &
import http.server, json, sys

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode()
        with open(sys.argv[1], "a") as out:
            out.write(json.dumps({
                "authorization": self.headers.get("Authorization", ""),
                "body": json.loads(body)}) + "\n")
            out.flush()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"accepted":true}')

    def log_message(self, *_):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[2], "w") as out:
    out.write(str(server.server_address[1]))
server.serve_forever()
PY
  KITCHEN_PID=$!
  local waited=0
  while [ ! -s "$port_file" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$port_file" ] || return 1
  mkdir -p "$KITCHEN_STATE_DIR"
  jq -cn --argjson p "$(cat "$port_file")" --arg t "$KITCHEN_TOKEN" \
    '{port:$p, hookToken:$t, pid:1}' > "$KITCHEN_STATE_DIR/server.json"
}

stop_kitchen() {
  [ -n "${KITCHEN_PID:-}" ] && kill "$KITCHEN_PID" 2>/dev/null
  wait "${KITCHEN_PID:-}" 2>/dev/null
  KITCHEN_PID=""
  rm -rf "$KITCHEN_STATE_DIR"
}

requests() { wc -l < "$KITCHEN_LOG" 2>/dev/null | tr -d ' '; }

await_requests() { # count → 0 once the listener logged that many requests
  local waited=0
  while [ "$(requests)" != "$1" ] && [ "$waited" -lt 30 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(requests)" = "$1" ]
}

write_crew() { # dir workflow-id role-id...
  local dir="$1" workflow="$2"
  shift 2
  mkdir -p "$dir/.office"
  jq -cn --arg w "$workflow" \
    '{version:1, kitchens:[], deliverables:[],
      workflow:{id:$w, title:"Test workflow",
                roles:[$ARGS.positional[] | {id:., title:., components:[]}]}}' \
    --args "$@" > "$dir/.office/kitchen.json"
}

kinds() { jq -r '.body.kind' "$KITCHEN_LOG" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
field() { jq -r "$1" "$KITCHEN_LOG" 2>/dev/null | sed -n "${2}p"; }

echo "── a Stop event spools one closed line ────────────────"
reset_spool
run "$(payload Stop)"
GOT=$(tail -n1 "$(spool)" 2>/dev/null)
WANT=$(jq -cn --arg n "$HERDR_SPOOL_NOW" --arg s "$SID" --arg t "$TRANSCRIPT" --arg c "$CWD" \
  '{recorded_at:$n, hook_event_name:"Stop", session_id:$s, transcript_path:$t, cwd:$c,
    agent_transcript_path:null}')
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$GOT" = "$WANT" ]; then
  ok "Stop appends the expected line, silent exit 0"
else ko "Stop appends expected line" "rc=$RC out=$OUT got=$GOT"; fi

echo "── SubagentStop carries the agent transcript ──────────"
reset_spool
run "$(payload SubagentStop "$(jq -cn --arg a "$AGENT" '{agent_transcript_path:$a}')")"
GOT=$(jq -r '.agent_transcript_path' "$(spool)" 2>/dev/null)
EVENT=$(jq -r '.hook_event_name' "$(spool)" 2>/dev/null)
if [ "$RC" = 0 ] && [ "$GOT" = "$AGENT" ] && [ "$EVENT" = SubagentStop ]; then
  ok "SubagentStop records agent_transcript_path"
else ko "SubagentStop agent transcript" "rc=$RC got=$GOT event=$EVENT"; fi

echo "── the spool is append-only ───────────────────────────"
reset_spool
run "$(payload SessionStart '{"source":"startup"}')"
run "$(payload Stop)"
if [ "$RC" = 0 ] && [ "$(lines)" = 2 ] && [ -z "$OUT" ]; then
  ok "two events append two lines"
else ko "append-only spool" "lines=$(lines)"; fi

echo "── fail-open: nothing usable, nothing written ─────────"
reset_spool
run '{not json at all'
if [ "$RC" = 0 ] && [ ! -f "$(spool)" ]; then ok "malformed JSON exits 0 and writes nothing"
else ko "malformed JSON" "rc=$RC lines=$(lines)"; fi

reset_spool
run ''
if [ "$RC" = 0 ] && [ ! -f "$(spool)" ]; then ok "empty stdin exits 0 and writes nothing"
else ko "empty stdin" "rc=$RC lines=$(lines)"; fi

reset_spool
run "$(jq -cn --arg s "$SID" --arg t "$TRANSCRIPT" \
  '{hook_event_name:"Stop", session_id:$s, transcript_path:$t}')"
if [ "$RC" = 0 ] && [ ! -f "$(spool)" ]; then ok "a payload missing cwd exits 0 and writes nothing"
else ko "missing cwd" "rc=$RC lines=$(lines)"; fi

reset_spool
run "$(jq -cn --arg c "$CWD" '{hook_event_name:"Stop", session_id:"", transcript_path:"", cwd:$c}')"
if [ "$RC" = 0 ] && [ ! -f "$(spool)" ]; then ok "blank identity fields exit 0 and write nothing"
else ko "blank identity fields" "rc=$RC lines=$(lines)"; fi

echo "── fail-open: no jq, unwritable root ──────────────────"
reset_spool
STDIN_JSON=$(payload Stop)
# A PATH the hook can still run from, holding every command it uses except jq.
NOJQ=$TMP/nojq
mkdir -p "$NOJQ"
for tool in bash cat date mkdir; do ln -sf "$(command -v "$tool")" "$NOJQ/$tool"; done
OUT=$(printf '%s' "$STDIN_JSON" | PATH="$NOJQ" "$G" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -f "$(spool)" ]; then ok "a missing jq exits 0 silently"
else ko "missing jq" "rc=$RC out=$OUT"; fi

BLOCKED=$TMP/blocked
mkdir -p "$BLOCKED"
: > "$BLOCKED/state"
OUT=$(printf '%s' "$STDIN_JSON" | HERDR_MASTER_ROOT="$BLOCKED/state" "$G" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "an unwritable spool root exits 0 silently"
else ko "unwritable spool root" "rc=$RC out=$OUT"; fi

echo "── privacy: no prompt or transcript text in the spool ─"
reset_spool
MARKER="XYZZY-super-secret-prompt-text-$$"
run "$(payload Stop "$(jq -cn --arg m "$MARKER" '{prompt:$m, last_assistant_message:$m}')")"
if [ "$(lines)" = 1 ] && ! grep -q "$MARKER" "$(spool)" 2>/dev/null; then
  ok "spool never contains prompt or message text"
else ko "prompt content leaked into the spool"; fi

echo "── kitchen role binding on SessionStart ───────────────"
reset_spool
write_marker worker
if start_kitchen; then
  run "$(payload SessionStart '{"source":"startup"}')"
  if await_requests 2; then
    WANT_START=$(jq -cS -n --arg s "$SID" --arg c "$CWD" \
      '{provider:"claude", sessionId:$s, cwd:$c, id:("herdr-session:"+$s),
        kind:"session-start"}')
    WANT_ROLE=$(jq -cS -n --arg s "$SID" --arg c "$CWD" \
      '{provider:"claude", sessionId:$s, cwd:$c, id:("herdr-role:"+$s),
        kind:"role", roleId:"worker", workflowId:"herdr"}')
    GOT_START=$(jq -cS '.body' "$KITCHEN_LOG" | sed -n 1p)
    GOT_ROLE=$(jq -cS '.body' "$KITCHEN_LOG" | sed -n 2p)
    if [ "$(kinds)" = "session-start role" ]; then
      ok "SessionStart opens the session before binding the role"
    else ko "SessionStart event order" "got: $(kinds)"; fi
    if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$GOT_START" = "$WANT_START" ] \
      && [ "$GOT_ROLE" = "$WANT_ROLE" ]; then
      ok "both SessionStart bodies are exactly as the Kitchen expects"
    else ko "SessionStart bodies" "start=$GOT_START role=$GOT_ROLE"; fi
    if [ "$(field '.authorization' 1)" = "Bearer $KITCHEN_TOKEN" ] \
      && [ "$(field '.authorization' 2)" = "Bearer $KITCHEN_TOKEN" ]; then
      ok "every request carries the bearer token"
    else ko "bearer token missing" "got: $(field '.authorization' 1)"; fi
  else ko "SessionStart posts two requests" "got $(requests)"; fi
  if [ "$(lines)" = 1 ]; then ok "the role binding does not disturb the spool append"
  else ko "spool append alongside role binding" "lines=$(lines)"; fi
  stop_kitchen
else
  ko "kitchen listener did not start"
  stop_kitchen
fi

echo "── Stop ends the turn, SubagentStop does not ──────────"
reset_spool
write_marker worker
if start_kitchen; then
  run "$(payload Stop)"
  if await_requests 2; then
    WANT_STOP=$(jq -cS -n --arg s "$SID" --arg c "$CWD" \
      '{provider:"claude", sessionId:$s, cwd:$c, id:("herdr-role:"+$s+":stop"),
        kind:"role", roleId:"worker", workflowId:"herdr"}')
    WANT_TURN=$(jq -cS -n --arg s "$SID" --arg c "$CWD" --arg n "$HERDR_SPOOL_NOW" \
      '{provider:"claude", sessionId:$s, cwd:$c,
        id:("herdr-turn-end:"+$s+":"+$n), kind:"turn-end"}')
    if [ "$RC" = 0 ] && [ "$(kinds)" = "role turn-end" ] \
      && [ "$(jq -cS '.body' "$KITCHEN_LOG" | sed -n 1p)" = "$WANT_STOP" ] \
      && [ "$(jq -cS '.body' "$KITCHEN_LOG" | sed -n 2p)" = "$WANT_TURN" ]; then
      ok "Stop re-posts the role and then ends the turn"
    else ko "Stop events" "kinds=$(kinds) bodies=$(jq -cS '.body' "$KITCHEN_LOG" | tr '\n' ' ')"; fi
  else ko "Stop posts two requests" "got $(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the Stop case"; stop_kitchen; fi

reset_spool
write_marker worker
if start_kitchen; then
  OUT=$(printf '%s' "$(payload Stop)" | HERDR_SPOOL_NOW=2026-09-15T12:00:00Z "$G" 2>/dev/null)
  OUT=$(printf '%s' "$(payload Stop)" | HERDR_SPOOL_NOW=2026-09-15T12:05:00Z "$G" 2>/dev/null)
  RC=$?
  if await_requests 4; then
    TURN_IDS=$(jq -r 'select(.body.kind == "turn-end") | .body.id' "$KITCHEN_LOG" \
      | sort -u | wc -l | tr -d ' ')
    if [ "$RC" = 0 ] && [ "$TURN_IDS" = 2 ]; then
      ok "two turns end under two distinct ids"
    else ko "turn-end ids must be fresh" "distinct=$TURN_IDS"; fi
  else ko "two Stops post four requests" "got $(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the two-turn case"; stop_kitchen; fi

reset_spool
if start_kitchen; then
  run "$(payload Stop)"
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ] && [ "$(lines)" = 1 ]; then
    ok "an unbound session gets no turn-end, only its spool line"
  else ko "unbound Stop must post nothing" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the unbound Stop case"; stop_kitchen; fi

reset_spool
if start_kitchen; then
  run "$(payload SessionEnd '{"reason":"clear"}')"
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ] && [ "$(lines)" = 1 ]; then
    ok "an unbound session is never closed either"
  else ko "unbound SessionEnd must post nothing" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the unbound SessionEnd case"; stop_kitchen; fi

echo "── SessionEnd closes the session ──────────────────────"
reset_spool
write_marker worker
if start_kitchen; then
  run "$(payload SessionEnd '{"reason":"clear"}')"
  if await_requests 1; then
    WANT_END=$(jq -cS -n --arg s "$SID" --arg c "$CWD" \
      '{provider:"claude", sessionId:$s, cwd:$c,
        id:("herdr-session-end:"+$s), kind:"session-end"}')
    if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(kinds)" = "session-end" ] \
      && [ "$(jq -cS '.body' "$KITCHEN_LOG")" = "$WANT_END" ]; then
      ok "SessionEnd posts exactly one session-end and no role"
    else ko "SessionEnd event" "kinds=$(kinds) body=$(jq -cS '.body' "$KITCHEN_LOG")"; fi
  else ko "SessionEnd posts one request" "got $(requests)"; fi
  if [ "$(lines)" = 1 ]; then ok "SessionEnd still appends its spool line"
  else ko "SessionEnd spool append" "lines=$(lines)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the SessionEnd case"; stop_kitchen; fi

reset_spool
write_marker worker
rm -rf "$KITCHEN_STATE_DIR"
run "$(payload SessionEnd '{"reason":"clear"}')"
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(lines)" = 1 ]; then
  ok "SessionEnd with no registered kitchen exits 0 and still spools"
else ko "SessionEnd without kitchen" "rc=$RC out=$OUT lines=$(lines)"; fi

reset_spool
write_marker worker
if start_kitchen; then
  run "$(payload SubagentStop "$(jq -cn --arg a "$AGENT" '{agent_transcript_path:$a}')")"
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ] && [ "$(lines)" = 1 ]; then
    ok "SubagentStop spools but never binds a role"
  else ko "SubagentStop must post nothing" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the SubagentStop case"; stop_kitchen; fi

echo "── kitchen role binding stays silent without a pair ───"
reset_spool
if start_kitchen; then
  run "$(payload SessionStart '{"source":"startup"}')"
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ]; then
    ok "no marker means no request at all"
  else ko "no marker means no request" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the no-marker case"; stop_kitchen; fi

reset_spool
write_marker worker
rm -rf "$KITCHEN_STATE_DIR"
run "$(payload SessionStart '{"source":"startup"}')"
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(lines)" = 1 ]; then
  ok "a marker with no registered kitchen exits 0 and still spools"
else ko "marker without kitchen" "rc=$RC out=$OUT lines=$(lines)"; fi

reset_spool
write_marker worker
if start_kitchen; then
  run "$(payload SessionStart '{"source":"startup"}' | jq -c --arg c "$TMP/gone" '.cwd=$c')"
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ]; then
    ok "an unresolvable working directory binds nothing and exits 0"
  else ko "unresolvable cwd" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the missing-cwd case"; stop_kitchen; fi

echo "── default station when herdr has no role for a session ─"
DEFAULT_ROOT=$TMP/default
DEFAULT_CWD=$DEFAULT_ROOT/work
mkdir -p "$DEFAULT_CWD"

default_run() { # extra-env-assignment... → runs SessionStart from DEFAULT_CWD
  reset_spool
  OUT=$(printf '%s' "$(payload SessionStart '{"source":"startup"}' \
    | jq -c --arg c "$DEFAULT_CWD" '.cwd=$c')" | env "$@" "$G" 2>/dev/null)
  RC=$?
}

write_crew "$DEFAULT_ROOT" herdr supervisor verifier worker
if start_kitchen; then
  default_run IGNORED=1
  if await_requests 2 && [ "$(kinds)" = "session-start role" ] \
    && [ "$(field '.body.roleId' 2)" = supervisor ] \
    && [ "$(field '.body.workflowId' 2)" = herdr ] \
    && [ "$(field '.body.cwd' 2)" = "$DEFAULT_CWD" ]; then
    ok "an unbound session binds to the default supervisor station"
  else ko "default station binding" "kinds=$(kinds) role=$(field '.body.roleId' 2)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the default station"; stop_kitchen; fi

if start_kitchen; then
  default_run HERDR_DEFAULT_KITCHEN_ROLE=worker
  if await_requests 2 && [ "$(field '.body.roleId' 2)" = worker ]; then
    ok "HERDR_DEFAULT_KITCHEN_ROLE picks a declared role"
  else ko "configured default role" "role=$(field '.body.roleId' 2)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the configured role"; stop_kitchen; fi

if start_kitchen; then
  default_run HERDR_DEFAULT_KITCHEN_ROLE=architect
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ]; then
    ok "a default role the crew file does not declare binds nothing"
  else ko "undeclared default role" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the undeclared role"; stop_kitchen; fi

write_crew "$DEFAULT_ROOT" project supervisor
if start_kitchen; then
  default_run IGNORED=1
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ]; then
    ok "a crew file for another workflow is never bound into"
  else ko "foreign workflow must not bind" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the foreign workflow"; stop_kitchen; fi

rm -rf "$DEFAULT_ROOT/.office"
NESTED=$DEFAULT_ROOT/one/two
mkdir -p "$NESTED"
write_crew "$DEFAULT_ROOT" herdr supervisor
if start_kitchen; then
  reset_spool
  run "$(payload SessionStart '{"source":"startup"}' | jq -c --arg c "$NESTED" '.cwd=$c')"
  if await_requests 2 && [ "$(field '.body.roleId' 2)" = supervisor ]; then
    ok "a crew file two directories up still binds"
  else ko "ancestor crew file" "requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the ancestor crew file"; stop_kitchen; fi

if start_kitchen; then
  # reset_spool would delete the marker, so seed it after the reset, not before.
  reset_spool
  write_marker verifier "$DEFAULT_CWD"
  OUT=$(printf '%s' "$(payload SessionStart '{"source":"startup"}' \
    | jq -c --arg c "$DEFAULT_CWD" '.cwd=$c')" | "$G" 2>/dev/null)
  RC=$?
  if await_requests 2 && [ "$(field '.body.roleId' 2)" = verifier ]; then
    ok "a marker still wins over the default station"
  else ko "marker precedence" "role=$(field '.body.roleId' 2)"; fi
  rm -f "$(marker_file "$DEFAULT_CWD")"
  stop_kitchen
else ko "kitchen listener did not start for the marker precedence case"; stop_kitchen; fi

rm -rf "$DEFAULT_ROOT/.office"
if start_kitchen; then
  default_run IGNORED=1
  sleep 0.5
  if [ "$RC" = 0 ] && [ "$(requests)" = 0 ]; then
    ok "no crew file anywhere above the session binds nothing"
  else ko "absent crew file" "rc=$RC requests=$(requests)"; fi
  stop_kitchen
else ko "kitchen listener did not start for the absent crew file"; stop_kitchen; fi

echo "── kitchen role binding never leaks the token ─────────"
# A racy ps snapshot would not prove this, so pin the mechanism instead: the header
# must come from a curl config file, never from an argument.
# shellcheck disable=SC2016  # these are literal source lines to find, not expansions
if grep -q 'curl --config "$CONFIG"' "$G" \
  && ! grep -Eq 'curl .*(-H|--header) "Authorization' "$G" \
  && grep -q 'chmod 600 "$CONFIG"' "$G"; then
  ok "the bearer token is passed by 0600 config file, not on the command line"
else ko "bearer token handling" "the hook must not put Authorization on curl's argv"; fi

echo "── the hook and kitchen.py agree on the marker path ───"
HERDR_KITCHEN=$HOME/Developer/herdr-orchestrator/herdr_master/kitchen.py
py_marker() { # root cwd → what kitchen.py would write
  python3 -c '
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
import kitchen
print(kitchen.marker_path(sys.argv[2], sys.argv[3]))' "$HERDR_KITCHEN" "$1" "$2" 2>/dev/null
}
if [ -f "$HERDR_KITCHEN" ]; then
  reset_spool
  # A symlink to the worktree is the case that matters: herdr may record the real path
  # while Claude Code reports the link, or the reverse.
  LINK=$TMP/link-to-tree
  rm -f "$LINK"
  ln -s "$CWD" "$LINK"
  PY_PATH=$(py_marker "$HERDR_MASTER_ROOT" "$LINK")
  # Compare the hashed basename, which is the contract the two implementations share.
  # The directory prefix may differ by a POSIX-equivalent double slash from TMPDIR.
  if [ -n "$PY_PATH" ] && [ "$(basename "$PY_PATH")" = "$(basename "$(marker_file "$CWD")")" ]; then
    ok "a symlinked directory hashes to the same name in both implementations"
  else ko "marker path disagreement" "shell=$(marker_file "$CWD") python=$PY_PATH"; fi
  if [ "$(basename "$(py_marker "$HERDR_MASTER_ROOT" "$CWD")")" = "$(basename "$PY_PATH")" ]; then
    ok "kitchen.py resolves the link and the target to one marker"
  else ko "kitchen.py did not resolve the symlink"; fi
  write_marker worker
  if [ -f "$PY_PATH" ]; then ok "the hook and kitchen.py resolve to the same marker file"
  else ko "marker file disagreement" "python path does not see the shell-written marker"; fi
  if start_kitchen; then
    run "$(payload SessionStart '{"source":"startup"}' | jq -c --arg c "$LINK" '.cwd=$c')"
    if await_requests 2 && [ "$(field '.body.roleId' 2)" = worker ]; then
      ok "a session reported under the symlink still finds the marker"
    else ko "symlinked session binding" "requests=$(requests)"; fi
    stop_kitchen
  else ko "kitchen listener did not start for the symlink case"; stop_kitchen; fi
else
  echo "  SKIP  kitchen.py not present; marker path cross-check skipped"
fi

echo "───────────────────────────────────────────────────────"
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
