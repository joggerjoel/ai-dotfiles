#!/usr/bin/env bash
# Tests for bin/sentinel-agent: config refusal, the sandbox requirement, the
# copy-back guard, wrapper-written proposals, metering, the daily budget,
# snapshot truncation and both locks.
#
# Offline. `claude`, `bwrap` and `tmux` are stubs on PATH: the fake bwrap
# records its arguments and runs the command after `--`; the fake claude
# records its arguments, applies $FAKE_DIR/edit.py to the work copies (as the
# model would through Edit) and prints $FAKE_DIR/out as its result. Where no
# fake bwrap is on PATH (and none is installed, as on macOS) the agent must
# refuse to run the model.
#
# Runs under bash 3.2 (stock macOS): no associative arrays, no mapfile.
# shellcheck disable=SC2034
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DOT=$(cd "$HERE/.." && pwd)
SA="$DOT/bin/sentinel-agent"
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

if [ -z "${PROCRUN_UV:-}" ]; then
  PROCRUN_UV=$(cd "$DOT" && { pyenv which uv 2>/dev/null || command -v uv || echo "$HOME/.local/bin/uv"; })
fi
if ! "$PROCRUN_UV" --version >/dev/null 2>&1; then
  echo "SKIP: uv not available; sentinel-agent needs it"
  echo "0 passed, 0 failed"
  exit 0
fi
export PROCRUN_UV

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sentinel-agent-test.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P)   # the agent resolves symlinks (macOS /var -> /private/var)
BGPIDS=""
cleanup() {
  for p in $BGPIDS; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

FAKE="$TMP/fakebin"      # claude, tmux
BW="$TMP/bwrapbin"       # bwrap, only on PATH for sandboxed runs
mkdir -p "$FAKE" "$BW"
export FAKE_DIR="$TMP/fake"
mkdir -p "$FAKE_DIR"
export PROCRUN_REGISTRY="$TMP/processes.toml"
export SENTINEL_AGENT_LOCK_WAIT=1
# A real claude-acct on PATH must not read this host's accounts or write its state.
export CLAUDE_ACCT_STATE="$TMP/acct-state" CLAUDE_ACCT_ENV=/dev/null CLAUDE_FLEET_ENV=/dev/null
BASE_PATH="$FAKE:$PATH"
SB_PATH="$BW:$FAKE:$PATH"
PROJ="$TMP/proj"
VAR="$PROJ/var/sentinel"
SNAP="$PROJ/var/sentinel-02-snapshot"
export FAKE_WORK="$SNAP/work"

cat > "$BW/bwrap" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_DIR/bwrap-argv"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
EOF
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env python3
import os, subprocess, sys
d = os.environ["FAKE_DIR"]
open(os.path.join(d, "claude-argv"), "w").write("\n".join(sys.argv[1:]) + "\n")
edit = os.path.join(d, "edit.py")
if os.path.exists(edit):
    subprocess.run([sys.executable, edit, os.environ["FAKE_WORK"]], check=True)
out = os.path.join(d, "out")
sys.stdout.write(open(out).read() if os.path.exists(out) else
    '{"type":"result","result":"checked","total_cost_usd":0.25,'
    '"usage":{"input_tokens":100,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":40}}')
sys.exit(int(open(os.path.join(d, "rc")).read()) if os.path.exists(os.path.join(d, "rc")) else 0)
EOF
cat > "$FAKE/tmux" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = "-t" ] && { t=$2; shift; }; shift; done
echo "pane $t line"
EOF
chmod +x "$FAKE"/* "$BW"/*

# ── fixtures ──────────────────────────────────────────────────────────────────

ISSUES_JSON='{
  "about": "test registry",
  "error_pattern": "error",
  "sentinels": {"02": {"doc": "watch-sentinel-02.md", "sources": {"app": {"glob": "logs/app.log"}}},
                "03": {"doc": "watch-sentinel-03.md", "sources": {}}},
  "issues": [
    {"id": "02-A", "sentinel": "02", "title": "a", "status": "open",
     "match": [{"source": "app", "pattern": "boom"}]},
    {"id": "02-B", "sentinel": "02", "title": "b", "status": "accepted",
     "match": [{"source": "app", "pattern": "noise"}]},
    {"id": "02-C", "sentinel": "02", "title": "c", "status": "closed",
     "match": [{"source": "app", "pattern": "old"}]},
    {"id": "03-A", "sentinel": "03", "title": "other", "status": "open",
     "match": [{"source": "x", "pattern": "y"}]}
  ]
}'

reset_project() {
  rm -rf "$PROJ" "$FAKE_DIR"
  mkdir -p "$PROJ/logs" "$FAKE_DIR"
  printf '%s\n' "$ISSUES_JSON" > "$PROJ/sentinel-issues.json"
  printf '# watch 02\n\n| when | note |\n| --- | --- |\n' > "$PROJ/watch-sentinel-02.md"
  printf '# watch 03\n' > "$PROJ/watch-sentinel-03.md"
  i=1; while [ $i -le 40 ]; do echo "app line $i error"; i=$((i + 1)); done > "$PROJ/logs/app.log"
  printf '#!/bin/sh\necho "check-last for $1"\n' > "$PROJ/check.sh"
  chmod +x "$PROJ/check.sh"
}

# write_registry [extra TOML lines for the model entry, replacing the defaults]
DEFAULT_BODY='model = "claude-test-model-20990101"
max_usd_per_day = 1.0
max_input_kb = 64
sandbox = { bwrap = true, read_only = true, tools = ["Read", "Edit"] }'
write_registry() {
  local body="${1:-$DEFAULT_BODY}"
  cat > "$PROCRUN_REGISTRY" <<EOF
[projects]
demo = "$PROJ"

[machine]
host = "testhost"

[[process]]
name = "sentinel-02-agent"
kind = "sentinel"
sentinel = "demo:02"
progress = "$PROJ/var/sentinel/checks-02.jsonl"
$body
instructions = "Project note: the app log is the main source."

[[process.capture]]
cmd = ["./check.sh", "02"]
name = "check-last"

[[process.capture]]
tail = "logs/app.log"
lines = 5
name = "app-tail"

[[process.capture]]
tmux = "demo:0.1"
lines = 8
EOF
}

# edit SNIPPET: python run by the fake model with W = work dir, I = issues dict,
# P = proposals list; I and P are written back afterwards.
edit() {
  cat > "$FAKE_DIR/edit.py" <<EOF
import json, os, sys
W = sys.argv[1]
I = json.load(open(os.path.join(W, "sentinel-issues.json")))
P = json.load(open(os.path.join(W, "proposals.json")))
def issue(i): return next(x for x in I["issues"] if x["id"] == i)
$1
json.dump(I, open(os.path.join(W, "sentinel-issues.json"), "w"), indent=2)
json.dump(P, open(os.path.join(W, "proposals.json"), "w"))
EOF
}

run_sa() { out=$(PATH="${RUN_PATH:-$SB_PATH}" "$SA" "$@" 2>&1); rc=$?; }
pyrec() {  # pyrec FILE EXPR, with R = the JSON lines of FILE
  python3 - "$1" "$2" <<'EOF'
import json, sys
try:
    R = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except FileNotFoundError:
    R = []
print(eval(sys.argv[2]))
EOF
}
issues_unchanged() { python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.loads(sys.argv[2]))' \
  "$PROJ/sentinel-issues.json" "$ISSUES_JSON"; }
hold_lock() {  # hold an flock on $1 until $2 exists
  python3 -c '
import fcntl, os, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[1] + ".held", "w").close()
while not os.path.exists(sys.argv[2]): time.sleep(0.05)' "$1" "$2" >/dev/null 2>&1 &
  BGPIDS="$BGPIDS $!"
  local i=0; while [ ! -f "$1.held" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
}

echo "warm-up (uv resolves the script environment once)"
reset_project; write_registry
"$SA" --help >/dev/null 2>&1

# ── config refusal (model and max_usd_per_day have no default) ────────────────
echo "config"
SB='sandbox = { bwrap = true, read_only = true, tools = ["Read", "Edit"] }'
write_registry "max_usd_per_day = 1.0
max_input_kb = 64
$SB"
run_sa demo 02
check "entry without model is refused" '[ $rc = 1 ] && echo "$out" | grep -q "model is required"' "$out"
check "refused run never calls claude" '[ ! -f "$FAKE_DIR/claude-argv" ]'

write_registry "model = \"claude-test-model-20990101\"
max_input_kb = 64
$SB"
run_sa demo 02
check "entry without max_usd_per_day is refused" '[ $rc = 1 ] && echo "$out" | grep -q "max_usd_per_day is required"' "$out"

write_registry "model = \"sonnet\"
max_usd_per_day = 1.0
max_input_kb = 64
$SB"
run_sa demo 02
check "a model alias is not a pinned model" '[ $rc = 1 ] && echo "$out" | grep -q "not a pinned model id"' "$out"

write_registry 'model = "claude-test-model-20990101"
max_usd_per_day = 1.0
max_input_kb = 64
sandbox = { bwrap = true, read_only = true, tools = ["Read", "Bash"] }'
run_sa demo 02
check "a tool outside Read/Edit is refused" '[ $rc = 1 ] && echo "$out" | grep -q "not allowed"' "$out"

write_registry 'model = "claude-test-model-20990101"
max_usd_per_day = 1.0
max_input_kb = 64
sandbox = { bwrap = false, read_only = true, tools = ["Read"] }'
run_sa demo 02
check "sandbox without bwrap = true is refused" '[ $rc = 1 ] && echo "$out" | grep -q "bwrap = true"' "$out"

run_sa demo 99
check "unknown sentinel id is refused" '[ $rc = 1 ]' "$out"
check "no claude call on any refusal" '[ ! -f "$FAKE_DIR/claude-argv" ]'

# ── sandbox requirement ───────────────────────────────────────────────────────
echo "sandbox"
reset_project; write_registry
if PATH="$BASE_PATH" command -v bwrap >/dev/null 2>&1; then
  ok "no-bwrap refusal skipped: a real bwrap is installed here"
else
  RUN_PATH="$BASE_PATH" run_sa demo 02
  check "without bwrap the model is not run" '[ $rc = 1 ] && [ ! -f "$FAKE_DIR/claude-argv" ]' "$out"
  check "the refusal is logged" 'echo "$out" | grep -q "refusing to run the model unsandboxed"' "$out"
  check "the refusal is a metered record" \
    '[ "$(pyrec "$VAR/agent-runs-02.jsonl" "R[-1][\"skipped\"]")" = no-sandbox ]'
fi

# ── a normal run ──────────────────────────────────────────────────────────────
echo "run"
reset_project; write_registry
edit 'I["issues"].append({"id": "02-D", "sentinel": "02", "title": "lock wait", "status": "watch",
                         "match": [{"source": "app", "pattern": "Lock wait timeout"}]})
issue("02-A")["status"] = "watch"
issue("02-A")["notes"] = "seen again"
open(os.path.join(W, "watch-sentinel-02.md"), "a").write("| now | ok |\n")
P.append({"issue_id": "02-D", "title": "Retry once on 1205", "proposal": "Add one retry."})'
run_sa demo 02
check "run exits 0" '[ $rc = 0 ]' "$out"
BA=$(cat "$FAKE_DIR/bwrap-argv" 2>/dev/null)
check "bwrap: read-only root" 'printf "%s\n" "$BA" | grep -A2 -x -- "--ro-bind" | grep -qx /' "$BA"
check "bwrap: private /tmp, own pid namespace, dies with parent" \
  'echo "$BA" | grep -qx -- --unshare-pid && echo "$BA" | grep -qx -- --tmpfs && echo "$BA" | grep -qx -- --die-with-parent'
check "bwrap: only the work dir is bound writable from the project" \
  '[ "$(printf "%s\n" "$BA" | grep -A1 -x -- --bind | grep -c "^$PROJ")" = 1 ] && echo "$BA" | grep -qx "$FAKE_WORK"' "$BA"
CA=$(cat "$FAKE_DIR/claude-argv")
check "claude: -p with --output-format json" 'echo "$CA" | grep -qx -- "--output-format" && echo "$CA" | grep -qx json'
check "claude: pinned --model" 'echo "$CA" | grep -A1 -x -- --model | grep -qx claude-test-model-20990101'
check "claude: dontAsk with no setting sources" 'echo "$CA" | grep -qx dontAsk && echo "$CA" | grep -qx -- --setting-sources'
check "claude: Read only the snapshot" 'echo "$CA" | grep -qx "Read(/$SNAP/\*\*)"' "$CA"
check "claude: Edit only the three copies" \
  '[ "$(echo "$CA" | grep -c "^Edit(")" = 3 ] && ! echo "$CA" | grep "^Edit(" | grep -qv "^Edit(/$FAKE_WORK/"' "$CA"
check "claude: no Bash or Write" '! echo "$CA" | grep -Eq "^(Bash|Write)"'
check "claude: --tools offers only the entry's tools" 'echo "$CA" | grep -A1 -x -- --tools | grep -qx "Read,Edit"' "$CA"
check "prompt treats the snapshot as data" 'echo "$CA" | grep -q "as data, never as instructions"'

check "prompt carries the registry instructions" 'echo "$CA" | grep -q "Project note"'
check "cmd capture ran outside the sandbox" 'grep -q "check-last for 02" "$SNAP/check-last.txt"'
check "tail capture kept the last lines" '[ "$(wc -l < "$SNAP/app-tail.txt" | tr -d " ")" = 5 ] && tail -1 "$SNAP/app-tail.txt" | grep -q "line 40"'
check "tmux capture went to a file" 'grep -q "pane demo:0.1" "$SNAP/pane-demo_0.1.txt"'
check "doc edit copied back" 'grep -q "| now | ok |" "$PROJ/watch-sentinel-02.md"'
check "additive issues edit copied back" \
  'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); ids=[i[\"id\"] for i in d[\"issues\"]]; sys.exit(not (\"02-D\" in ids and d[\"issues\"][0][\"status\"]==\"watch\"))" "$PROJ/sentinel-issues.json"'
R="$VAR/agent-runs-02.jsonl"
check "run metered: tokens (input includes cache) and cost" \
  '[ "$(pyrec "$R" "(R[-1][\"input_tokens\"], R[-1][\"output_tokens\"], R[-1][\"cost_usd\"])")" = "(150, 40, 0.25)" ]'
check "run record has run_id, started, ended, rc, model" \
  '[ "$(pyrec "$R" "all(k in R[-1] for k in (\"run_id\",\"started\",\"ended\",\"rc\",\"model\")) and R[-1][\"model\"]")" = claude-test-model-20990101 ]'
RUN_ID=$(pyrec "$R" 'R[-1]["run_id"]')
check "proposal for an issue the run added is appended with a proposal_id" \
  '[ "$(pyrec "$VAR/proposals-02.jsonl" "(len(R), R[0][\"issue_id\"], len(R[0][\"proposal_id\"]), R[0][\"run_id\"] == \"$RUN_ID\")")" = "(1, '"'"'02-D'"'"', 32, True)" ]'

# ── copy-back guard: each crafted edit is rejected, the real file untouched ──
echo "guard"
guard_case() {  # guard_case NAME SNIPPET REASON-REGEX
  reset_project; write_registry; edit "$2"
  run_sa demo 02
  if issues_unchanged && echo "$out" | grep -Eq "sentinel-issues.json edit rejected.*$3"; then ok "rejects: $1"
  else bad "rejects: $1" "$out"; fi
}
guard_case "open issue moved to accepted" 'issue("02-A")["status"] = "accepted"' "from open to accepted"
guard_case "open issue moved to fixed" 'issue("02-A")["status"] = "fixed"' "from open to fixed"
guard_case "open issue moved to closed" 'issue("02-A")["status"] = "closed"' "from open to closed"
guard_case "an issue removed" 'I["issues"] = [i for i in I["issues"] if i["id"] != "02-A"]' "removes issue 02-A"
guard_case "an existing pattern changed" 'issue("02-A")["match"][0]["pattern"] = "b.*"' "existing pattern of issue 02-A"
guard_case "a pattern added to an accepted issue" \
  'issue("02-B")["match"].append({"source": "app", "pattern": "injected"})' "pattern to accepted issue 02-B"
guard_case "a pattern added to a closed issue" \
  'issue("02-C")["match"].append({"source": "app", "pattern": "injected"})' "pattern to closed issue 02-C"
guard_case "a new issue born closed" \
  'I["issues"].append({"id": "02-Z", "sentinel": "02", "title": "z", "status": "closed", "match": []})' "status 'closed'"
guard_case "another sentinel's issue changed" 'issue("03-A")["status"] = "watch"' "issue 03-A of sentinel '03'"
guard_case "top-level error_pattern weakened" 'I["error_pattern"] = "nothing"' "top-level 'error_pattern'"
check "a rejected edit is kept for review" '[ -f "$SNAP/sentinel-issues.json.rejected" ]'

reset_project; write_registry
printf 'import os, sys\nopen(os.path.join(sys.argv[1], "sentinel-issues.json"), "w").write("{not json")\n' > "$FAKE_DIR/edit.py"
run_sa demo 02
check "rejects: invalid JSON" 'issues_unchanged && echo "$out" | grep -q "invalid JSON, not copied back"' "$out"

reset_project; write_registry
edit 'I["issues"].append({"id": "02-E", "sentinel": "02", "title": "e", "status": "open", "match": []})
j = json.load(open(os.environ["PROJ_ISSUES"])); j["issues"][0]["title"] = "edited by a person"
json.dump(j, open(os.environ["PROJ_ISSUES"], "w"))'
PROJ_ISSUES="$PROJ/sentinel-issues.json" run_sa demo 02
check "a real file changed during the run is not overwritten" \
  'grep -q "edited by a person" "$PROJ/sentinel-issues.json" && ! grep -q 02-E "$PROJ/sentinel-issues.json" && [ -f "$SNAP/sentinel-issues.json.conflict" ]' "$out"

reset_project; write_registry
cat > "$FAKE_DIR/edit.py" <<'EOF'
import json, os, sys
open(os.path.join(sys.argv[1], "watch-sentinel-02.md"), "a").write("| now | ok |\n")
j = json.load(open(os.environ["PROJ_ISSUES"])); j["issues"][0]["title"] = "edited by a person"
json.dump(j, open(os.environ["PROJ_ISSUES"], "w"))
EOF
PROJ_ISSUES="$PROJ/sentinel-issues.json" run_sa demo 02
check "an untouched copy is not rejected when its real file changes during the run" \
  '[ "$(pyrec "$VAR/agent-runs-02.jsonl" "(R[-1][\"copied_back\"], R[-1][\"rejected\"])")" = "(['"'"'watch-sentinel-02.md'"'"'], [])" ] && [ ! -f "$SNAP/sentinel-issues.json.conflict" ] && grep -q "edited by a person" "$PROJ/sentinel-issues.json"' "$out"

# ── proposals ─────────────────────────────────────────────────────────────────
echo "proposals"
reset_project; write_registry
edit 'P.extend([
  {"issue_id": "02-A", "title": "Fine", "proposal": "Do it."},
  {"issue_id": "02-NOPE", "title": "Bad id", "proposal": "x"},
  {"issue_id": "02-A", "title": "Extra", "proposal": "x", "apply": True},
  {"issue_id": "02-A", "title": "x" * 300, "proposal": "x"},
  {"issue_id": "02-A", "title": "two\nlines", "proposal": "x"},
  {"issue_id": "02-A", "title": "huge", "proposal": "y" * 5000},
  "not an object"])'
run_sa demo 02
PF="$VAR/proposals-02.jsonl"
check "only the valid proposal is appended" '[ "$(pyrec "$PF" "[r[\"title\"] for r in R]")" = "['"'"'Fine'"'"']" ]' "$out"
check "each invalid proposal is logged" '[ "$(echo "$out" | grep -c "proposal #.* rejected")" = 6 ]' "$out"
check "a proposal for a nonexistent issue is rejected" 'echo "$out" | grep -q "02-NOPE.*does not exist"'

reset_project; write_registry
printf 'import os, sys\nopen(os.path.join(sys.argv[1], "proposals.json"), "w").write("[oops")\n' > "$FAKE_DIR/edit.py"
run_sa demo 02
check "an invalid proposals file yields no proposals" '[ ! -s "$VAR/proposals-02.jsonl" ] && echo "$out" | grep -q "proposals.json is invalid JSON"' "$out"

# ── metering when the model fails ─────────────────────────────────────────────
echo "metering"
reset_project; write_registry
echo "crashed" > "$FAKE_DIR/out"; echo 3 > "$FAKE_DIR/rc"
run_sa demo 02
check "a failed model run exits with its rc" '[ $rc = 3 ]' "$out"
check "a failed run is still metered, cost unknown" \
  '[ "$(pyrec "$VAR/agent-runs-02.jsonl" "(R[-1][\"rc\"], R[-1][\"cost_usd\"])")" = "(3, None)" ]'

# ── budget ────────────────────────────────────────────────────────────────────
echo "budget"
reset_project; write_registry
mkdir -p "$VAR"
TODAY=$(date +%Y-%m-%d)
printf '{"started":"%sT01:00:00+00:00","cost_usd":0.6}\n{"started":"%sT02:00:00+00:00","cost_usd":0.4}\n' \
  "$TODAY" "$TODAY" > "$VAR/agent-runs-02.jsonl"
run_sa demo 02
check "at max_usd_per_day the run is skipped" '[ $rc = 0 ] && [ ! -f "$FAKE_DIR/claude-argv" ] && echo "$out" | grep -q "budget reached"' "$out"
check "the budget skip is recorded" '[ "$(pyrec "$VAR/agent-runs-02.jsonl" "R[-1][\"skipped\"]")" = budget ]'
printf '{"started":"2000-01-01T01:00:00+00:00","cost_usd":50}\n{"started":"%sT01:00:00+00:00","cost_usd":0.6}\n' \
  "$TODAY" > "$VAR/agent-runs-02.jsonl"
run_sa demo 02
check "earlier days do not count against today" '[ $rc = 0 ] && [ -f "$FAKE_DIR/claude-argv" ]' "$out"

# ── truncation ────────────────────────────────────────────────────────────────
echo "truncation"
reset_project
write_registry 'model = "claude-test-model-20990101"
max_usd_per_day = 1.0
max_input_kb = 1
sandbox = { bwrap = true, read_only = true, tools = ["Read", "Edit"] }'
sed -i.bak 's/^lines = 5$/lines = 500/' "$PROCRUN_REGISTRY"
i=1; while [ $i -le 400 ]; do echo "app line $i error with some padding text"; i=$((i + 1)); done > "$PROJ/logs/app.log"
run_sa demo 02
SIZE=$(cat "$SNAP"/*.txt | wc -c | tr -d ' ')
check "snapshot fits max_input_kb" '[ $rc = 0 ] && [ "$SIZE" -gt 0 ] && [ "$SIZE" -le 1024 ]' "size $SIZE: $out"
check "the newest lines are kept" 'tail -1 "$SNAP/app-tail.txt" | grep -q "line 400 "' "$(tail -1 "$SNAP/app-tail.txt")"
check "the oldest lines are dropped" '[ -s "$SNAP/app-tail.txt" ] && ! grep -q "line 1 " "$SNAP/app-tail.txt"'
check "the prompt notes the truncation" 'grep -q "truncated to max_input_kb = 1" "$FAKE_DIR/claude-argv"'
check "the run record notes the truncation" '[ "$(pyrec "$VAR/agent-runs-02.jsonl" "R[-1][\"truncated\"]")" = True ]'

# ── locks ─────────────────────────────────────────────────────────────────────
echo "locks"
reset_project; write_registry; mkdir -p "$VAR"
hold_lock "$VAR/agent-02.lock" "$TMP/release-run"
run_sa demo 02
touch "$TMP/release-run"
check "a run already active skips the tick" '[ $rc = 0 ] && [ ! -f "$FAKE_DIR/claude-argv" ] && echo "$out" | grep -q "still active"' "$out"

reset_project; write_registry; mkdir -p "$VAR"
edit 'issue("02-A")["status"] = "watch"'
hold_lock "$VAR/sentinel-issues.lock" "$TMP/release-proj"
run_sa demo 02
touch "$TMP/release-proj"
check "a busy project lock blocks copy-back" 'issues_unchanged && echo "$out" | grep -q "project lock busy"' "$out"
check "a busy project lock reports only the edited copies as rejected" \
  '[ "$(pyrec "$VAR/agent-runs-02.jsonl" "R[-1][\"rejected\"]")" = "['"'"'sentinel-issues.json'"'"']" ]' "$out"

reset_project; write_registry; mkdir -p "$VAR"
edit 'issue("02-A")["status"] = "watch"'
hold_lock "$VAR/sentinel-issues.lock" "$TMP/release-proj2"
( sleep 0.5; touch "$TMP/release-proj2" ) &
BGPIDS="$BGPIDS $!"
run_sa demo 02
check "copy-back waits for the project lock, then lands" '! issues_unchanged && ! echo "$out" | grep -q "project lock busy"' "$out"

echo
# claude-acct, when installed, runs the model and keeps its state dir writable.
ACCT_BIN="$TMP/acctbin"; mkdir -p "$ACCT_BIN"
cat > "$ACCT_BIN/claude-acct" <<'ACCT'
#!/bin/sh
echo used > "$FAKE_DIR/acct-used"
exec claude "$@"
ACCT
chmod +x "$ACCT_BIN/claude-acct"
reset_project; write_registry
RUN_PATH="$BW:$ACCT_BIN:$FAKE:$PATH" run_sa demo 02
check "claude-acct runs the model when installed" '[ -f "$FAKE_DIR/acct-used" ] && [ $rc -eq 0 ]' "$out"
check "claude-acct state dir is bound writable in the sandbox" 'grep -A2 -x -- --bind "$FAKE_DIR/bwrap-argv" | grep -qx "$TMP/acct-state"'

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
