#!/usr/bin/env bash
# Tests for bin/procrun: the cron wrapper, `procrun check`, `procrun validate`,
# `procrun watch-check`, `procrun export`, the registry template and the ~/.local/bin install.
#
# Real processes, real files, no network beyond uv's first fetch of croniter.
# crontab, docker, systemctl, tmux and the mailer are stubs on PATH, so the
# live crontab and services are never read. Linux-only identity sources
# (/proc, boot_id) have macOS equivalents in procrun, so every case runs on
# both; flock(1) is used when installed and replaced by Python's fcntl.flock
# (the same flock(2) call) where it is not, as on stock macOS.
#
# Runs under bash 3.2 (stock macOS): no associative arrays, no mapfile.
#
# Several variables are read only inside the single-quoted conditions that
# check() evals, where shellcheck cannot see them.
# shellcheck disable=SC2034
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DOT=$(cd "$HERE/.." && pwd)
PR="$DOT/bin/procrun"
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

# A working uv. A pyenv shim can exist yet fail outside a directory whose
# .python-version provides uv, so ask pyenv for the real binary from the repo.
if [ -z "${PROCRUN_UV:-}" ]; then
  PROCRUN_UV=$(cd "$DOT" && { pyenv which uv 2>/dev/null || command -v uv || echo "$HOME/.local/bin/uv"; })
fi
if ! "$PROCRUN_UV" --version >/dev/null 2>&1; then
  echo "SKIP: uv not available; procrun needs it"
  echo "0 passed, 0 failed"
  exit 0
fi
export PROCRUN_UV

TMP=$(mktemp -d "${TMPDIR:-/tmp}/procrun-test.XXXXXX") || exit 1
BGPIDS=""
cleanup() {
  for p in $BGPIDS; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT

FAKE="$TMP/fakebin"
mkdir -p "$FAKE"
export PATH="$FAKE:$PATH"
export PROCRUN_STATE_DIR="$TMP/state"
export PROCRUN_REGISTRY="$TMP/processes.toml"
export FAKE_DIR="$TMP/fake"
mkdir -p "$FAKE_DIR"
MAILLOG="$TMP/mail.log"
# Unique program names for presence patterns: a fixed string such as
# "sleep 6666" also matches the command line of whatever shell launched us.
TOKEN="$$$RANDOM"

cat > "$FAKE/crontab" <<'EOF'
#!/bin/sh
[ "$1" = "-l" ] && [ -f "$FAKE_DIR/crontab" ] && exec cat "$FAKE_DIR/crontab"
exit 1
EOF
# docker inspect -f <fmt> <name>: prints $FAKE_DIR/docker-<name>
cat > "$FAKE/docker" <<'EOF'
#!/bin/sh
for last; do :; done
[ -f "$FAKE_DIR/docker-$last" ] && exec cat "$FAKE_DIR/docker-$last"
exit 1
EOF
# systemctl show ... <unit>: prints $FAKE_DIR/systemd-<unit>
cat > "$FAKE/systemctl" <<'EOF'
#!/bin/sh
for last; do :; done
f="$FAKE_DIR/systemd-$last"
[ -f "$f" ] || exit 1
case "$*" in *--value*) sed -n 's/^LoadState=//p' "$f" ;; *) cat "$f" ;; esac
EOF
# tmux display-message -p -t <target> <fmt>: prints $FAKE_DIR/tmux-<target>
cat > "$FAKE/tmux" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do [ "$1" = "-t" ] && { t=$2; shift; }; shift; done
[ -f "$FAKE_DIR/tmux-$t" ] && exec cat "$FAKE_DIR/tmux-$t"
exit 1
EOF
cat > "$FAKE/mailer" <<'EOF'
#!/bin/sh
[ -f "$FAKE_DIR/mail-fails" ] && exit 1
{ echo "SUBJECT: $1"; cat; echo "--"; } >> "$MAILLOG"
EOF
chmod +x "$FAKE"/*
export MAILLOG

# Python over records: pyrec FILE EXPR, with R = the list of JSON lines.
pyrec() {
  python3 - "$1" "$2" <<'EOF'
import json, sys
try:
    R = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
except FileNotFoundError:
    R = []
print(eval(sys.argv[2]))
EOF
}
state_status() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["processes"].get(sys.argv[2],{}).get("status"))' \
    "$PROCRUN_STATE_DIR/check-state.json" "$1"
}
# state_set NAME KEY PYVALUE: edit one field of a process in check-state.json
state_set() {
  python3 - "$PROCRUN_STATE_DIR/check-state.json" "$1" "$2" "$3" <<'EOF'
import json, sys, time
p, name, key, val = sys.argv[1:]
s = json.load(open(p))
s["processes"].setdefault(name, {})[key] = eval(val, {"now": time.time()})
json.dump(s, open(p, "w"))
EOF
}
wait_for() {  # wait_for SECONDS COMMAND
  local i=0 n=$(($1 * 10))
  while [ $i -lt $n ]; do eval "$2" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
mail_count() { grep -c '^SUBJECT:' "$MAILLOG" 2>/dev/null || echo 0; }
reset_state() { rm -rf "$PROCRUN_STATE_DIR" "$MAILLOG"; }

# Hold an exclusive flock(2) on $1 until $2 appears, the way an unwrapped
# `flock -n LOCK cmd` job does. Prints the holder pid. The holder's output goes
# to /dev/null: inheriting the $(...) pipe would make the caller wait for it.
hold_lock() {
  if command -v flock >/dev/null 2>&1; then
    flock -n "$1" sh -c 'touch "$1.held"; while [ ! -f "$2" ]; do sleep 0.1; done' _ "$1" "$2" >/dev/null 2>&1 &
  else
    python3 -c '
import fcntl, os, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[1] + ".held", "w").close()
while not os.path.exists(sys.argv[2]): time.sleep(0.1)' "$1" "$2" >/dev/null 2>&1 &
  fi
  echo $!
}
# Exit 0 when a non-blocking flock on $1 would succeed (flock -n semantics).
try_lock() {
  if command -v flock >/dev/null 2>&1; then flock -n "$1" true
  else python3 -c '
import fcntl, sys
f = open(sys.argv[1], "a")
try: fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit(1)' "$1"
  fi
}

cd "$TMP" || exit 1

# A long-lived process started well before any procrun run below, so its start
# time differs from theirs even where ps reports whole seconds (macOS).
sleep 600 & live=$!
BGPIDS="$BGPIDS $live"

echo "warm-up (uv resolves croniter once)"
if ! "$PR" --help >/dev/null 2>"$TMP/warm.err"; then
  bad "procrun --help runs" "$(cat "$TMP/warm.err")"
  echo "$pass passed, $fail failed"; exit 1
fi
ok "procrun --help runs"

# ── 1.1 / 1.2: the run wrapper ───────────────────────────────────────────────
echo "run wrapper"

cat > "$TMP/interleave.sh" <<'EOF'
#!/bin/sh
printf 'out 1\n'; printf 'err 1\n' >&2; printf 'out 2 partial'; printf ' err 2\n' >&2
printf '\nout 3\n'; printf 'err 3\n' >&2
echo "env $PROCRUN_PROC $PROCRUN_RUN_ID"
exit 3
EOF
chmod +x "$TMP/interleave.sh"
cat > "$PROCRUN_REGISTRY" <<EOF
[machine]
host = "testhost"
mailer = "mailer"
[[process]]
name = "job"
kind = "cron"
schedule = "* * * * *"
log = "$TMP/job.log"
EOF
printf 'before\n' > "$TMP/shell.log"; printf 'before\n' > "$TMP/job.log"
( PROCRUN_PROC=job PROCRUN_RUN_ID=X "$TMP/interleave.sh" >> "$TMP/shell.log" 2>&1 )
"$PR" job -- "$TMP/interleave.sh"; rc=$?
REC="$PROCRUN_STATE_DIR/job.jsonl"
RUNID=$(pyrec "$REC" 'R[-1]["run_id"]')
sed "s/env job X/env job $RUNID/" "$TMP/shell.log" > "$TMP/shell.expected"
check "log content and order match '>> file 2>&1'" 'cmp -s "$TMP/shell.expected" "$TMP/job.log"' \
  "$(diff "$TMP/shell.expected" "$TMP/job.log")"
check "child exit code is procrun's exit code" '[ "$rc" = 3 ]' "rc=$rc"
check "PROCRUN_RUN_ID and PROCRUN_PROC reach the child" 'grep -q "^env job [0-9a-f]\{32\}$" "$TMP/job.log"'
check "start then end, same run_id" \
  '[ "$(pyrec "$REC" "[r[\"event\"] for r in R] == [\"start\",\"end\"] and R[0][\"run_id\"] == R[1][\"run_id\"]")" = True ]'
check "start records pid, pid start time and boot ID" \
  '[ "$(pyrec "$REC" "all(R[0].get(k) for k in (\"v\",\"ts\",\"host\",\"proc\",\"pid\",\"pid_start\",\"boot_id\"))")" = True ]' \
  "$(head -1 "$REC")"
grown=$(( $(wc -c < "$TMP/job.log") - 7 ))
check "end records exit, reason, duration and log_bytes (growth)" \
  '[ "$(pyrec "$REC" "(R[1][\"exit\"], R[1][\"reason\"], isinstance(R[1][\"duration_ms\"], int), R[1][\"log_bytes\"])")" = "(3, '"'"'exit'"'"', True, $grown)" ]' \
  "$(tail -1 "$REC")"
check "host comes from [machine] host" '[ "$(pyrec "$REC" "R[0][\"host\"]")" = testhost ]'

"$PR" job -- "$TMP/does-not-exist"; rc=$?
check "missing command: exit 127, end record, message in the log" \
  '[ "$rc" = 127 ] && [ "$(pyrec "$REC" "R[-1][\"exit\"]")" = 127 ] && grep -q "does-not-exist" "$TMP/job.log"'

out=$("$PR" nosuch -- sh -c 'echo ran-unmanaged' 2>&1); rc=$?
check "unknown name still runs the command (validate reports it)" \
  '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q ran-unmanaged && printf "%s" "$out" | grep -q "no registry entry"'

# Output continues if procrun is killed.
cat > "$TMP/ticker.sh" <<'EOF'
#!/bin/sh
i=0; while [ $i -lt 10 ]; do echo "tick $i"; i=$((i + 1)); sleep 0.2; done
EOF
chmod +x "$TMP/ticker.sh"
cat > "$PROCRUN_REGISTRY" <<EOF
[machine]
mailer = "mailer"
[[process]]
name = "tick"
kind = "cron"
schedule = "* * * * *"
max_silence = "1h"
log = "$TMP/tick.log"
EOF
reset_state
"$PR" tick -- "$TMP/ticker.sh" &
BGPIDS="$BGPIDS $!"
TREC="$PROCRUN_STATE_DIR/tick.jsonl"
wait_for 10 '[ -s "$TREC" ] && grep -q "tick 0" "$TMP/tick.log"'
kill -9 "$(pyrec "$TREC" 'R[0]["pid"]')" 2>/dev/null
wait_for 6 'grep -q "tick 9" "$TMP/tick.log"'
check "output continues to the log after procrun is SIGKILLed" 'grep -q "tick 9" "$TMP/tick.log"'
"$PR" check
check "a killed procrun (start, no end) shows as orphaned" '[ "$(state_status tick)" = orphaned ]'

# Timeout: child and grandchildren die, procrun and the cron shell do not.
cat > "$TMP/spawner.sh" <<'EOF'
#!/bin/sh
sleep 60 & echo $! >> "$1"
sh -c 'sleep 60 & echo $! >> "$1"; wait' _ "$1" &
echo $! >> "$1"
echo $$ >> "$1"
wait
EOF
chmod +x "$TMP/spawner.sh"
cat > "$PROCRUN_REGISTRY" <<EOF
[[process]]
name = "slow"
kind = "cron"
schedule = "* * * * *"
timeout = "1s"
log = "$TMP/slow.log"
EOF
: > "$TMP/pids"
t0=$(date +%s)
sh -c '"$1" slow -- "$2" "$3"; echo "shell alive rc=$?" >> "$4"' _ "$PR" "$TMP/spawner.sh" "$TMP/pids" "$TMP/shell.marker"
t1=$(date +%s)
SREC="$PROCRUN_STATE_DIR/slow.jsonl"
check "timeout: procrun writes end with reason timeout" '[ "$(pyrec "$SREC" "R[-1][\"reason\"]")" = timeout ]'
check "timeout: the cron shell survives and sees exit 124" 'grep -q "shell alive rc=124" "$TMP/shell.marker"'
alive=""
for p in $(cat "$TMP/pids"); do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
check "timeout: child and every grandchild are gone" '[ -z "$alive" ] && [ "$(wc -l < "$TMP/pids")" -ge 4 ]' \
  "alive:$alive pids:$(tr '\n' ' ' < "$TMP/pids")"
check "timeout: SIGTERM path finishes well inside the kill grace" '[ $((t1 - t0)) -lt 8 ]' "took $((t1 - t0))s"

cat > "$TMP/stubborn.sh" <<'EOF'
#!/bin/sh
trap '' TERM
sleep 60
EOF
chmod +x "$TMP/stubborn.sh"
PROCRUN_KILL_GRACE=1 "$PR" slow -- "$TMP/stubborn.sh"
check "timeout: a group that ignores SIGTERM gets SIGKILL after the grace" \
  '[ "$(pyrec "$SREC" "(R[-1][\"reason\"], R[-1].get(\"signal\"))")" = "('"'"'timeout'"'"', 9)" ]' "$(tail -1 "$SREC")"

# Overlap skip, against an unwrapped `flock -n` job and the other way round.
LOCK="$TMP/job.lock"
cat > "$PROCRUN_REGISTRY" <<EOF
[machine]
mailer = "mailer"
[[process]]
name = "locked"
kind = "cron"
schedule = "* * * * *"
overlap = "skip"
lock = "$LOCK"
log = "$TMP/locked.log"
criticality = "high"
EOF
reset_state
holder=$(hold_lock "$LOCK" "$TMP/release")
BGPIDS="$BGPIDS $holder"
wait_for 5 '[ -f "$LOCK.held" ]'
LREC="$PROCRUN_STATE_DIR/locked.jsonl"
"$PR" locked -- sh -c 'echo SHOULD-NOT-RUN'; rc=$?
check "skip: a lock held by 'flock -n' makes procrun skip" \
  '[ "$rc" = 0 ] && [ "$(pyrec "$LREC" "[r[\"event\"] for r in R]")" = "['"'"'skipped'"'"']" ] && ! grep -q SHOULD-NOT-RUN "$TMP/locked.log" 2>/dev/null'
"$PR" check  # baseline
"$PR" locked -- true; "$PR" locked -- true
"$PR" check
check "three consecutive skips report blocked, and mail" \
  '[ "$(state_status locked)" = blocked ] && grep -q "locked: blocked" "$MAILLOG"'
touch "$TMP/release"
wait_for 5 '! kill -0 "$holder" 2>/dev/null'
"$PR" locked -- sleep 2 & lp=$!
BGPIDS="$BGPIDS $lp"
wait_for 5 '[ "$(pyrec "$LREC" "R[-1][\"event\"]")" = start ]'
check "skip: while procrun runs, an unwrapped 'flock -n' on the same lock fails" '! try_lock "$LOCK"'
wait "$lp"
check "skip: the lock is free again after the run" 'try_lock "$LOCK"'

# A reused pid does not hide an orphan.
cat > "$PROCRUN_REGISTRY" <<EOF
[machine]
mailer = "mailer"
[[process]]
name = "reuse"
kind = "cron"
schedule = "* * * * *"
max_silence = "1h"
EOF
reset_state
"$PR" reuse -- sleep 3 &
BGPIDS="$BGPIDS $!"
RREC="$PROCRUN_STATE_DIR/reuse.jsonl"
wait_for 10 '[ -s "$RREC" ]'
"$PR" check
check "a running procrun is not orphaned" '[ "$(state_status reuse)" = ok ]'
python3 - "$RREC" "$live" <<'EOF'
import json, sys
p, pid = sys.argv[1], int(sys.argv[2])
r = json.loads(open(p).readline())
r.update(run_id="f" * 32, pid=pid)  # same pid as a live process, recorded start time differs
open(p, "a").write(json.dumps(r) + "\n")
EOF
"$PR" check
check "a start whose pid is alive but started at another time is orphaned" '[ "$(state_status reuse)" = orphaned ]'
wait_for 6 '[ "$(pyrec "$RREC" "sum(r[\"event\"] == \"end\" for r in R)")" = 1 ]'
python3 - "$RREC" "$live" <<'EOF'
import json, os, subprocess, sys
p, pid = sys.argv[1], int(sys.argv[2])
R = [json.loads(l) for l in open(p)]
# The live process's real start time, read the way procrun reads it, so only
# the boot ID differs.
if os.path.exists(f"/proc/{pid}/stat"):
    st = open(f"/proc/{pid}/stat").read()
    start = st[st.rindex(")") + 2:].split()[19]
else:
    start = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True,
                           env={**os.environ, "LC_ALL": "C"}).stdout.strip()
r = dict(R[0])
r.update(run_id="e" * 32, ts=R[-1]["ts"][:-6] + "9" + R[-1]["ts"][-6:], pid=pid, pid_start=start,
         boot_id="0" * 32)
open(p, "a").write(json.dumps(r) + "\n")
EOF
"$PR" check
check "a start from another boot is orphaned" '[ "$(state_status reuse)" = orphaned ]'

# ── 1.3: procrun check ───────────────────────────────────────────────────────
echo "check"
mkdir -p "$TMP/proj/var/sentinel" "$TMP/logs"
cat > "$TMP/registry-check.toml" <<EOF
[projects]
proj = "$TMP/proj"
[machine]
host = "h1"
mailer = "mailer"
[[process]]
name = "c-fail"
kind = "cron"
schedule = "* * * * *"
max_silence = "1h"
progress = "$TMP/logs/c-fail.log"
criticality = "high"
[[process]]
name = "c-missed"
kind = "cron"
schedule = "* * * * *"
max_silence = "1m"
criticality = "low"
[[process]]
name = "c-pending"
kind = "cron"
schedule = "* * * * *"
max_silence = "1m"
migration = "pending"
match = "pending-job"
progress = "$TMP/logs/pending.log"
[[process]]
name = "s-02"
kind = "sentinel"
sentinel = "proj:02"
progress = "$TMP/proj/var/sentinel/checks-02.jsonl"
max_silence = "45m"
[[process]]
name = "box"
kind = "container"
container = "box"
progress = "$TMP/logs/box.log"
max_silence = "45m"
[[process]]
name = "unit"
kind = "systemd"
unit = "u.service"
[[process]]
name = "pane"
kind = "tmux-pane"
target = "s:0.1"
pattern = "pane-prog-${TOKEN}[.]sh"
[[process]]
name = "daemon"
kind = "daemon"
pattern = "daemon-prog-${TOKEN}[.]sh"
EOF
cp "$TMP/registry-check.toml" "$PROCRUN_REGISTRY"
reset_state
: > "$FAKE_DIR/crontab"
touch "$TMP/logs/c-fail.log" "$TMP/logs/pending.log" "$TMP/logs/box.log" "$TMP/proj/var/sentinel/checks-02.jsonl"
printf 'true 0\n' > "$FAKE_DIR/docker-box"
printf 'ActiveState=active\nNRestarts=0\nLoadState=loaded\n' > "$FAKE_DIR/systemd-u.service"
printf 'while :; do sleep 1; done\n' > "$TMP/pane-prog-$TOKEN.sh"
cp "$TMP/pane-prog-$TOKEN.sh" "$TMP/daemon-prog-$TOKEN.sh"
sh -c 'sh "$1" & wait' _ "$TMP/pane-prog-$TOKEN.sh" & pane=$!
sh "$TMP/daemon-prog-$TOKEN.sh" & daemon=$!
BGPIDS="$BGPIDS $pane $daemon"
echo "$pane" > "$FAKE_DIR/tmux-s:0.1"
wait_for 5 'ps -A -o args= | grep -q "^sh .*pane-prog-$TOKEN"'
"$PR" c-fail -- false
"$PR" check
check "first run: baseline, no mail even with a failed job" '[ ! -s "$MAILLOG" ] && [ "$(state_status c-fail)" = failed ]'
check "first run: check-state.json written" '[ -f "$PROCRUN_STATE_DIR/check-state.json" ]'
for n in s-02 box unit pane daemon c-pending c-missed; do
  check "first run: $n is ok" '[ "$(state_status $n)" = ok ]' "status=$(state_status $n)"
done
lines=$(wc -l < "$PROCRUN_STATE_DIR/status.jsonl")
touch -t 200001010000 "$PROCRUN_STATE_DIR/check-state.json"
"$PR" check
check "status.jsonl is written on transitions only" '[ "$(wc -l < "$PROCRUN_STATE_DIR/status.jsonl")" = "$lines" ]'
check "check-state.json is touched every run" '[ -n "$(find "$PROCRUN_STATE_DIR/check-state.json" -newer "$TMP/logs/box.log")" ]'
check "an unchanged status does not mail again" '[ ! -s "$MAILLOG" ]' "$(cat "$MAILLOG" 2>/dev/null)"

"$PR" c-fail -- true
"$PR" check
"$PR" c-fail -- sh -c 'exit 5'
"$PR" check
check "transition into failed mails once, with the exit code" \
  '[ "$(mail_count)" = 1 ] && grep -q "c-fail: failed - failed (exit 5)" "$MAILLOG"'
"$PR" check
check "no repeat mail inside the reminder interval" '[ "$(mail_count)" = 1 ]'
state_set c-fail last_mail 'now - 3601'
"$PR" check
check "high criticality reminds after 1 h" '[ "$(mail_count)" = 2 ] && grep -q "(reminder)" "$MAILLOG"'

state_set c-missed first_seen 'now - 3600'
state_set c-pending first_seen 'now - 3600'
"$PR" check
check "missed: a due time passed (plus max_silence) with no start" '[ "$(state_status c-missed)" = missed ]'
check "pending cron entries get no run checks" '[ "$(state_status c-pending)" = ok ]'
"$PR" c-missed -- true
"$PR" check
check "missed clears at the first check after a start" '[ "$(state_status c-missed)" = ok ]'

touch -t 200001010000 "$TMP/proj/var/sentinel/checks-02.jsonl" "$TMP/logs/pending.log"
"$PR" check
check "stalled: sentinel progress older than max_silence" '[ "$(state_status s-02)" = stalled ]'
check "stalled: pending cron entry still gets progress checks" '[ "$(state_status c-pending)" = stalled ]'
touch "$TMP/proj/var/sentinel/checks-02.jsonl" "$TMP/logs/pending.log"

touch -t 200001010000 "$TMP/logs/c-fail.log"
"$PR" check
check "precedence: failed beats stalled" '[ "$(state_status c-fail)" = failed ]'
touch "$TMP/logs/c-fail.log"

printf 'false 0\n' > "$FAKE_DIR/docker-box"
touch -t 200001010000 "$TMP/logs/box.log"
"$PR" check
check "down: stopped container (down beats stalled)" '[ "$(state_status box)" = down ]'
printf 'true 0\n' > "$FAKE_DIR/docker-box"; touch "$TMP/logs/box.log"
"$PR" check
printf 'true 1\n' > "$FAKE_DIR/docker-box"
"$PR" check
check "down: a container restart alerts" '[ "$(state_status box)" = down ]'
"$PR" check
check "down from a restart lasts one check (baseline moved)" '[ "$(state_status box)" = ok ]'

printf 'ActiveState=failed\nNRestarts=0\nLoadState=loaded\n' > "$FAKE_DIR/systemd-u.service"
"$PR" check
check "down: inactive systemd unit" '[ "$(state_status unit)" = down ]'

kill "$(ps -A -o pid=,ppid=,args= | awk -v p="$pane" '$2 == p && $3 == "sh" {print $1}')" 2>/dev/null
wait_for 5 '! ps -A -o args= | grep -q "^sh .*pane-prog-$TOKEN"'
"$PR" check
check "tmux: a pane whose shell survives but program is gone is down" '[ "$(state_status pane)" = down ]'
kill "$daemon" 2>/dev/null; wait "$daemon" 2>/dev/null
"$PR" check
check "daemon: no process matching the pattern is down" '[ "$(state_status daemon)" = down ]'

"$PR" c-fail -- true
"$PR" check
: > "$MAILLOG"; touch "$FAKE_DIR/mail-fails"
"$PR" c-fail -- sh -c 'exit 6'
"$PR" check
rm -f "$FAKE_DIR/mail-fails"
"$PR" check
check "a failed mail is retried at the next check" 'grep -q "c-fail: failed - failed (exit 6)" "$MAILLOG"'

# Rotation: a record file over 10 MB moves to .1, and records there still count.
python3 - "$PROCRUN_STATE_DIR/c-fail.jsonl" <<'EOF'
import sys
line = '{"v":1,"event":"note","pad":"' + "x" * 1000 + '"}\n'
with open(sys.argv[1], "a") as f:
    for _ in range(10600):
        f.write(line)
EOF
"$PR" c-fail -- sh -c 'exit 7'
"$PR" check
check "rotation: a record file over 10 MB is renamed to .jsonl.1" \
  '[ -f "$PROCRUN_STATE_DIR/c-fail.jsonl.1" ] && [ ! -f "$PROCRUN_STATE_DIR/c-fail.jsonl" ]'
check "rotation: the rotated generation is still read" \
  'python3 -c "import json,sys; s=json.load(open(sys.argv[1])); sys.exit(s[\"processes\"][\"c-fail\"][\"detail\"] != \"failed (exit 7)\")" "$PROCRUN_STATE_DIR/check-state.json"'

# ── 1.6: procrun validate ────────────────────────────────────────────────────
echo "validate"
cat > "$PROCRUN_REGISTRY" <<EOF
[projects]
dice = "$TMP/dice"
[machine]
mailer = "mailer"
[[process]]
name = "notify"
kind = "cron"
schedule = "*/15 * * * *"
[[process]]
name = "old"
kind = "cron"
schedule = "0 * * * *"
migration = "pending"
match = "old-job.sh"
[[process]]
name = "sentinel-02"
kind = "sentinel"
sentinel = "dice:02"
progress = "$TMP/dice/var/sentinel/checks-02.jsonl"
doc = "watch-sentinel-02.md"
EOF
cat > "$FAKE_DIR/crontab" <<EOF
DICE=$TMP/dice
*/15 * * * * cd \$DICE && $PR notify -- ./notify.sh
0 * * * * cd \$DICE && ./old-job.sh >> logs/old.log 2>&1
*/5 * * * * cd \$DICE && ./dice-health-alert.sh checklog sentinel-02 watch-sentinel-02.md 45
*/5 * * * * $PR check
EOF
out=$("$PR" validate 2>&1); rc=$?
check "validate: a consistent registry passes" '[ "$rc" = 0 ] && ! printf "%s" "$out" | grep -q FAIL' "$out"

cp "$FAKE_DIR/crontab" "$TMP/crontab.good"
printf '*/10 * * * * %s ghost -- ./ghost.sh\n' "$PR" >> "$FAKE_DIR/crontab"
out=$("$PR" validate 2>&1); rc=$?
check "validate fails on a procrun launcher with no entry" \
  '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "FAIL: crontab runs procrun '"'"'ghost'"'"'"' "$out"

sed 's#^\*/15 \* \* \* \* cd#*/20 * * * * cd#' "$TMP/crontab.good" > "$FAKE_DIR/crontab"
out=$("$PR" validate 2>&1); rc=$?
check "validate fails on a schedule mismatch" \
  '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "notify.*differs from crontab"' "$out"

sed 's#watch-sentinel-02.md#watch-sentinel.md#' "$TMP/crontab.good" > "$FAKE_DIR/crontab"
out=$("$PR" validate 2>&1); rc=$?
check "validate fails on the old watch-sentinel.md checklog target" \
  '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "checklog sentinel-02 reads watch-sentinel.md"' "$out"

grep -v old-job "$TMP/crontab.good" > "$FAKE_DIR/crontab"
printf '30 2 * * * ./unknown.sh\n' >> "$FAKE_DIR/crontab"
out=$("$PR" validate 2>&1); rc=$?
check "validate fails on a pending entry whose crontab line is gone" \
  'printf "%s" "$out" | grep -q "FAIL: process '"'"'old'"'"': no crontab line found"' "$out"
check "validate warns on a line neither wrapped nor pending" \
  'printf "%s" "$out" | grep -q "WARN: crontab line neither wrapped nor pending: 30 2"' "$out"

cp "$TMP/crontab.good" "$FAKE_DIR/crontab"
sed 's#checks-02.jsonl#checks-03.jsonl#' "$PROCRUN_REGISTRY" > "$TMP/r2.toml"
out=$(PROCRUN_REGISTRY="$TMP/r2.toml" "$PR" validate 2>&1); rc=$?
check "validate fails on a sentinel progress that is not its checks file" \
  '[ "$rc" = 1 ] && printf "%s" "$out" | grep -q "progress must be checks-02.jsonl"' "$out"

: > "$MAILLOG"
reset_state
"$PR" check  # baseline
printf '[[process]]\nname = "loose"\nkind = "cron"\nschedule = "nonsense"\n' >> "$PROCRUN_REGISTRY"
touch -t 203001010000 "$PROCRUN_REGISTRY"
"$PR" check; rc=$?
check "check runs validate when the registry changed, mails, and still completes" \
  '[ "$rc" = 0 ] && grep -q "registry validation failed" "$MAILLOG" && grep -q "not a valid cron expression" "$MAILLOG" && [ "$(state_status notify)" != None ]'
before=$(mail_count)
"$PR" validate --mail >/dev/null; rc=$?
check "validate --mail mails failures and exits 1 (daily cron)" '[ "$rc" = 1 ] && [ "$(mail_count)" = $((before + 1)) ]'

# The shipped template validates on a machine that matches it.
TH="$TMP/home"
mkdir -p "$TH/.config/procrun"
cp "$DOT/examples/processes.example.toml" "$TH/.config/procrun/processes.toml"
cat > "$FAKE_DIR/crontab" <<'EOF'
*/15 * * * * cd ~/Documents/Projects/clubs/dice && ~/.local/bin/procrun dice-onsale-notify -- ./run-notify-dice-onsale-upcoming.sh
* * * * * cd ~/Documents/Projects/clubs/dice && flock -n /tmp/dice-api-breaker.lock node dice-api-breaker.js >> logs/x.log 2>&1
*/5 * * * * ~/.local/bin/procrun check
EOF
printf 'true 0\n' > "$FAKE_DIR/docker-9router"
printf 'LoadState=loaded\n' > "$FAKE_DIR/systemd-mysql.service"
echo 1 > "$FAKE_DIR/tmux-dice:0.3"
out=$(HOME="$TH" PROCRUN_REGISTRY='' PROCRUN_STATE_DIR="$TH/state" "$PR" validate 2>&1); rc=$?
check "examples/processes.example.toml validates cleanly" '[ "$rc" = 0 ] && [ "$out" = ok ]' "$out"

# ── watch-check ──────────────────────────────────────────────────────────────
echo "watch-check"
cp "$TMP/registry-check.toml" "$PROCRUN_REGISTRY"
reset_state
"$PR" check
"$PR" watch-check; rc=$?
check "watch-check is quiet while check-state.json is fresh" '[ "$rc" = 0 ] && [ ! -s "$MAILLOG" ]'
touch -t 200001010000 "$PROCRUN_STATE_DIR/check-state.json"
"$PR" watch-check 2>/dev/null; rc=$?
check "watch-check mails when check-state.json is older than 15 min" '[ "$rc" = 1 ] && grep -q "checker down" "$MAILLOG"'
"$PR" watch-check 2>/dev/null
check "watch-check mails at most once an hour" '[ "$(mail_count)" = 1 ]'

# ── 4.7: model sentinel sandbox ──────────────────────────────────────────────
echo "validate: model sentinel sandbox"
cat > "$TMP/r-model.toml" <<EOF
[projects]
dice = "$TMP/dice"
[[process]]
name = "s02-agent"
kind = "sentinel"
sentinel = "dice:02"
progress = "$TMP/dice/var/sentinel/checks-02.jsonl"
model = "pinned-model"
SANDBOX
EOF
model_validate() {  # model_validate SANDBOX-LINE: prints validate's output
  sed "s#^SANDBOX\$#$1#" "$TMP/r-model.toml" > "$TMP/r-model-1.toml"
  PROCRUN_REGISTRY="$TMP/r-model-1.toml" "$PR" validate 2>&1
}
out=$(model_validate 'sandbox = { bwrap = true, read_only = true, tools = ["Read", "Grep"] }')
check "validate passes a model sentinel with bwrap, read_only and a tools list" \
  '! printf "%s" "$out" | grep -q "sandbox"' "$out"
out=$(model_validate 'sandbox = { read_only = true, tools = ["Read"] }')
check "validate fails a model sentinel whose sandbox lacks bwrap" \
  'printf "%s" "$out" | grep -q "FAIL: .*sandbox lacks bwrap = true$"' "$out"
out=$(model_validate 'sandbox = { bwrap = true, read_only = false, tools = ["Read"] }')
check "validate fails a model sentinel whose sandbox is not read_only" \
  'printf "%s" "$out" | grep -q "FAIL: .*sandbox lacks read_only = true$"' "$out"
out=$(model_validate 'sandbox = { bwrap = true, read_only = true }')
check "validate fails a model sentinel whose sandbox has no tools list" \
  'printf "%s" "$out" | grep -q "FAIL: .*sandbox lacks a tools list$"' "$out"
out=$(model_validate 'sandbox = { bwrap = true, read_only = true, tools = "Read" }')
check "validate fails a model sentinel whose tools is not a list" \
  'printf "%s" "$out" | grep -q "FAIL: .*sandbox lacks a tools list$"' "$out"
out=$(model_validate '')
check "validate fails a model sentinel with no sandbox at all" \
  'printf "%s" "$out" | grep -q "FAIL: .*sandbox lacks bwrap = true, read_only = true, a tools list"' "$out"
out=$(model_validate 'sandbox = { bwrap = true, read_only = true, tools = [] }')
check "validate fails a model sentinel with an empty tools list" \
  'printf "%s" "$out" | grep -q "FAIL: .*sandbox lacks a tools list$"' "$out"

# ── 3.1 / 3.2: procrun export ────────────────────────────────────────────────
echo "export"
EX="$TMP/export"
mkdir -p "$EX/dice/var/sentinel" "$EX/logs"
cat > "$EX/processes.toml" <<EOF
[projects]
dice = "$EX/dice"
[machine]
host = "exporthost"
mounts = ["/", "$EX"]
[[process]]
name = "job"
kind = "cron"
schedule = "* * * * *"
log = "$EX/logs/job.log"
criticality = "high"
[[process]]
name = "calm"
kind = "cron"
schedule = "* * * * *"
log = "$EX/logs/calm.log"
[[process]]
name = "sentinel-02"
kind = "sentinel"
sentinel = "dice:02"
progress = "$EX/dice/var/sentinel/checks-02.jsonl"
EOF
cat > "$EX/dice/sentinel-issues.json" <<'EOF'
{"issues": [
  {"id": "02-A", "sentinel": "02", "status": "open", "title": "Proxy stalls", "match": [{"re": "secret-pattern"}]},
  {"id": "02-B", "sentinel": "02", "status": "closed", "title": "mail ops@example.com about it"},
  {"id": "03-A", "sentinel": "03", "status": "open", "title": "another sentinel"}
]}
EOF
ES="$EX/state"
mkdir -p "$ES"
printf '{"v":1,"last_run":%s,"processes":{"job":{"status":"failed","detail":"failed (exit 3)","since":1},"calm":{"status":"ok"}}}\n' \
  "$(python3 -c 'import time; print(time.time() - 60)')" > "$ES/check-state.json"
{
  for i in $(seq 1 80); do echo "job log line $i"; done
  echo "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"
  echo "anthropic sk-ant-api03-abcdefghijklmnopqrstuvwxyz"
  echo "aws AKIAABCDEFGHIJKLMNOP"
  echo "db password=hunter2hunter2"
  echo "Authorization: Bearer abc.def.ghi"
  echo "reported by someone@example.org"
  echo "-----BEGIN OPENSSH PRIVATE KEY-----"
  echo "b3BlbnNzaC1rZXktdjEAAAAA"
  echo "-----END OPENSSH PRIVATE KEY-----"
} > "$EX/logs/job.log"
echo "calm log line" > "$EX/logs/calm.log"
for i in 1 2 3; do printf '{"v":1,"proc":"job","event":"start","n":%s}\n' "$i"; done > "$ES/job.jsonl"
printf '{"check":1}\n' > "$EX/dice/var/sentinel/checks-02.jsonl"
printf '{"proposal_id":"p1"}\n' > "$EX/dice/var/sentinel/proposals-02.jsonl"
printf '{"run_id":"r1","cost_usd":0.1}\n' > "$EX/dice/var/sentinel/agent-runs-02.jsonl"
printf '{"proc":"job","to":"failed"}\n{"proc":"calm","to":"ok"}\n' > "$ES/status.jsonl"

# export_req JSON OUT: run export with JSON on stdin, output in OUT, rc in $rc
export_req() {
  printf '%s' "$1" | PROCRUN_REGISTRY="$EX/processes.toml" PROCRUN_STATE_DIR="$ES" "$PR" export > "$2" 2>"$2.err"
  rc=$?
}
# pyj FILE EXPR: Python over one JSON document J (streams by index: S[i])
pyj() {
  python3 - "$1" "$2" <<'EOF'
import json, sys
J = json.load(open(sys.argv[1]))
S = J.get("streams", [])
print(eval(sys.argv[2]))
EOF
}
if stat --version >/dev/null 2>&1; then snapshot() { find "$EX" -exec stat -c '%n %s %Y %i' {} + | sort; }
else snapshot() { find "$EX" -exec stat -f '%N %z %m %i' {} + | sort; }; fi
snapshot > "$TMP/ex-before"

export_req '[{"stream":"runs","key":"job"},{"stream":"status","key":"job"},{"stream":"checks","key":"dice:02"},{"stream":"proposals","key":"dice:02"},{"stream":"agent_runs","key":"dice:02"}]' "$TMP/ex1.json"
check "export answers a valid request with exit 0" '[ "$rc" = 0 ]' "$(cat "$TMP/ex1.json.err")"
check "export: runs returns the process's record lines" \
  '[ "$(pyj "$TMP/ex1.json" "[json.loads(l)[\"n\"] for l in S[0][\"lines\"]]")" = "[1, 2, 3]" ]'
check "export: status returns only the named process's transitions" \
  '[ "$(pyj "$TMP/ex1.json" "S[1][\"lines\"]")" = "['"'"'{\"proc\":\"job\",\"to\":\"failed\"}'"'"']" ]'
check "export: checks, proposals and agent_runs resolve from the sentinel's directory" \
  '[ "$(pyj "$TMP/ex1.json" "[len(s[\"lines\"]) for s in S[2:5]]")" = "[1, 1, 1]" ]'
check "export: check-state.json last-run time is returned" \
  '[ "$(pyj "$TMP/ex1.json" "J[\"check\"][\"last_run\"] is not None and 50 <= J[\"check\"][\"age_s\"] <= 600")" = True ]'
check "export: sentinel issue statuses carry id, status and title only, per sentinel" \
  '[ "$(pyj "$TMP/ex1.json" "J[\"sentinels\"]")" = "[{'"'"'key'"'"': '"'"'dice:02'"'"', '"'"'issues'"'"': [{'"'"'id'"'"': '"'"'02-A'"'"', '"'"'status'"'"': '"'"'open'"'"', '"'"'title'"'"': '"'"'Proxy stalls'"'"'}, {'"'"'id'"'"': '"'"'02-B'"'"', '"'"'status'"'"': '"'"'closed'"'"', '"'"'title'"'"': '"'"'mail [REDACTED:email] about it'"'"'}]}]" ]' \
  "$(pyj "$TMP/ex1.json" "J[\"sentinels\"]")"
check "export: df for every registry mount" \
  '[ "$(pyj "$TMP/ex1.json" "[d[\"total\"] > 0 and d[\"free\"] >= 0 for d in J[\"disk\"]]")" = "[True, True]" ]'
check "export: a non-ok process gets the last 50 lines of its log (a key block redacts to one line)" \
  '[ "$(pyj "$TMP/ex1.json" "(lambda t: (t[0], t[-1]))(J[\"processes\"][0][\"log_tail\"].split(chr(10)))")" = "('"'"'job log line 40'"'"', '"'"'[REDACTED:private_key]'"'"')" ]'
check "export: an ok process gets no log excerpt" \
  '[ "$(pyj "$TMP/ex1.json" "\"log_tail\" in J[\"processes\"][1]")" = False ]'

# 3.2: redaction removes token, key, password, Authorization and email patterns.
for secret in ghp_abcdefghijklmnopqrstuvwxyz0123456789 sk-ant-api03-abcdefghijklmnopqrstuvwxyz \
              AKIAABCDEFGHIJKLMNOP hunter2hunter2 abc.def.ghi someone@example.org ops@example.com \
              b3BlbnNzaC1rZXktdjEAAAAA; do
  check "export redacts $secret" '! grep -qF "$secret" "$TMP/ex1.json"'
done
check "export marks each redaction with its rule" \
  '( for r in github_token anthropic_key aws_access_key secret_assignment authorization email private_key; do grep -q "REDACTED:$r" "$TMP/ex1.json" || exit 1; done )'
check "export: the redaction rules are byte-identical to toodoo-herdr's (when checked out)" \
  'th="${TOODOO_HERDR_DIR:-$DOT/../toodoo-herdr}/toodoo_herdr/redaction-rules.json"; [ ! -f "$th" ] || cmp -s "$th" "$DOT/lib/procrun/redaction-rules.json"'

# 3.2: a request naming a path or an unknown key is rejected.
# shellcheck disable=SC2088 # a literal ~ is the point: keys are never expanded
for key in /etc/passwd ../job "~/.ssh/id_ed25519" "job/../../x" ".hidden" "dice:02/../../../etc"; do
  export_req "[{\"stream\":\"runs\",\"key\":\"$key\"},{\"stream\":\"checks\",\"key\":\"$key\"}]" "$TMP/ex-path.json"
  check "export rejects a path as a key: $key" \
    '[ "$rc" = 1 ] && [ "$(pyj "$TMP/ex-path.json" "[s.get(\"error\") for s in S] + [\"lines\" in s for s in S]")" = "['"'"'keys are registry names, never paths'"'"', '"'"'keys are registry names, never paths'"'"', False, False]" ]'
done
export_req '[{"stream":"runs","key":"ghost"},{"stream":"checks","key":"dice:99"},{"stream":"checks","key":"job"},{"stream":"runs","key":"dice:02"},{"stream":"runs","key":"job"}]' "$TMP/ex-unk.json"
check "export rejects unknown keys and keys of the wrong kind, and still answers the rest" \
  '[ "$rc" = 1 ] && [ "$(pyj "$TMP/ex-unk.json" "[s.get(\"error\") for s in S[:4]] + [len(S[4][\"lines\"])]")" = "['"'"'unknown key'"'"', '"'"'unknown key'"'"', '"'"'unknown key'"'"', '"'"'unknown key'"'"', 3]" ]'
for bad in 'not json' '{"stream":"runs","key":"job"}' '[{"stream":"files","key":"job"}]' \
           '[{"stream":"runs","key":"job","path":"/etc/passwd"}]' '[{"stream":"runs","key":"job","offset":-1}]' \
           '[{"stream":"runs","key":["job"]}]'; do
  export_req "$bad" "$TMP/ex-bad.json"
  check "export rejects a malformed request with exit 2: $bad" \
    '[ "$rc" = 2 ] && [ "$(pyj "$TMP/ex-bad.json" "sorted(J)")" = "['"'"'error'"'"', '"'"'v'"'"']" ]'
done

snapshot > "$TMP/ex-after"
check "export writes nothing (every file's size, mtime and inode unchanged; nothing created)" \
  'diff "$TMP/ex-before" "$TMP/ex-after" >/dev/null' "$(diff "$TMP/ex-before" "$TMP/ex-after")"
printf '[]' | PROCRUN_REGISTRY="$EX/processes.toml" PROCRUN_STATE_DIR="$EX/no-state" "$PR" export > /dev/null
check "export does not create a missing state directory" '[ ! -e "$EX/no-state" ]'

# 3.2: rotation between polls loses no line. Position is (inode, offset).
pos_of() { pyj "$1" "json.dumps({k: S[0][k] for k in (\"inode\", \"offset\", \"prev\") if k in S[0]})"; }
runs_req() {  # runs_req POSITION-JSON: a runs request for job continuing at that position
  python3 -c 'import json, sys; d = json.loads(sys.argv[1]); d.update(stream="runs", key="job"); print(json.dumps([d]))' "$1"
}
export_req '[{"stream":"runs","key":"job"}]' "$TMP/p1.json"
p=$(pos_of "$TMP/p1.json")
for i in 4 5; do printf '{"v":1,"proc":"job","event":"start","n":%s}\n' "$i" >> "$ES/job.jsonl"; done
printf '{"v":1,"proc":"job","event":"start","n":6,"partial":' >> "$ES/job.jsonl"  # still being written
export_req "$(runs_req "$p")" "$TMP/p2.json"
check "export returns only lines after the offset, and no partial line" \
  '[ "$(pyj "$TMP/p2.json" "[json.loads(l)[\"n\"] for l in S[0][\"lines\"]]")" = "[4, 5]" ]'
p=$(pos_of "$TMP/p2.json")
printf 'true}\n{"v":1,"proc":"job","event":"start","n":7}\n' >> "$ES/job.jsonl"
mv "$ES/job.jsonl" "$ES/job.jsonl.1"   # procrun check's rotation is this rename
for i in 8 9; do printf '{"v":1,"proc":"job","event":"start","n":%s}\n' "$i" >> "$ES/job.jsonl"; done
export_req "$(runs_req "$p")" "$TMP/p3.json"
check "rotation between polls: the rest of .1 comes first, then the new file, nothing lost" \
  '[ "$(pyj "$TMP/p3.json" "([json.loads(l)[\"n\"] for l in S[0][\"lines\"]], S[0][\"gap\"])")" = "([6, 7, 8, 9], False)" ]' \
  "$(cat "$TMP/p3.json")"
p=$(pos_of "$TMP/p3.json")
printf '{"v":1,"proc":"job","event":"end","n":10}\n' >> "$ES/job.jsonl.1"  # a run open across the rename ends in .1
printf '{"v":1,"proc":"job","event":"start","n":11}\n' >> "$ES/job.jsonl"
export_req "$(runs_req "$p")" "$TMP/p4.json"
check "a line written to .1 after the collector moved on is still returned (prev)" \
  '[ "$(pyj "$TMP/p4.json" "[json.loads(l)[\"n\"] for l in S[0][\"lines\"]]")" = "[10, 11]" ]' "$(cat "$TMP/p4.json")"
p=$(pos_of "$TMP/p4.json")
export_req "$(runs_req "$p")" "$TMP/p5.json"
check "a poll with nothing new returns nothing" '[ "$(pyj "$TMP/p5.json" "S[0][\"lines\"]")" = "[]" ]'
# Hard links keep the replaced files' inodes allocated, so a new file cannot
# reuse the inode the position names (ext4 reuses freed inodes at once).
ln "$ES/job.jsonl.1" "$TMP/keep-a"; ln "$ES/job.jsonl" "$TMP/keep-b"
mv "$ES/job.jsonl" "$ES/job.jsonl.1"
printf '{"v":1,"proc":"job","event":"start","n":12}\n' > "$ES/job.jsonl"
mv "$ES/job.jsonl" "$ES/job.jsonl.1"
printf '{"v":1,"proc":"job","event":"start","n":13}\n' > "$ES/job.jsonl"
export_req "$(runs_req "$p")" "$TMP/p6.json"
check "two rotations between polls are reported as a gap, then read from the start" \
  '[ "$(pyj "$TMP/p6.json" "([json.loads(l)[\"n\"] for l in S[0][\"lines\"]], S[0][\"gap\"])")" = "([12, 13], True)" ]'

# 1 MB cap: more is set, and following the positions returns every line once.
python3 - "$ES/job.jsonl" <<'EOF'
import sys
with open(sys.argv[1], "w") as f:
    for i in range(3000):
        f.write('{"v":1,"proc":"job","n":%d,"pad":"%s"}\n' % (i, "x" * 700))
EOF
rm -f "$ES/job.jsonl.1"
p='{}'; seen="$TMP/cap-seen"; : > "$seen"; polls=0; maxbytes=0
while [ $polls -lt 10 ]; do
  export_req "$(runs_req "$p")" "$TMP/cap.json"
  polls=$((polls + 1))
  size=$(wc -c < "$TMP/cap.json"); [ "$size" -gt "$maxbytes" ] && maxbytes=$size
  pyj "$TMP/cap.json" "'\n'.join(str(json.loads(l)['n']) for l in S[0]['lines'])" | grep . >> "$seen"
  p=$(pos_of "$TMP/cap.json")
  [ "$(pyj "$TMP/cap.json" "S[0][\"more\"]")" = True ] || break
done
check "the response is capped at 1 MB and needs several polls for 2 MB" \
  '[ "$maxbytes" -le $((1024 * 1024 + 1)) ] && [ "$polls" -ge 3 ]' "max $maxbytes bytes, $polls polls"
check "following the capped responses returns every line exactly once, in order" \
  '[ "$(seq 0 2999 | cmp -s - "$seen" && echo same)" = same ]'

python3 - "$ES/job.jsonl" <<'EOF2'
import sys
with open(sys.argv[1], "a") as f:
    f.write('{"v":1,"proc":"job","n":"huge","pad":"%s"}\n' % ("y" * (1100 * 1024)))
    f.write('{"v":1,"proc":"job","n":"after"}\n')
EOF2
export_req "$(runs_req "$p")" "$TMP/big.json"
check "a line larger than the cap is skipped and counted, and the position moves past it" \
  '[ "$(pyj "$TMP/big.json" "([json.loads(l)[\"n\"] for l in S[0][\"lines\"]], S[0].get(\"oversize_lines\"))")" = "(['"'"'after'"'"'], 1)" ]' \
  "$(head -c 300 "$TMP/big.json")"

# The cap can stop a poll inside the .1 lines that prev points at; the
# position then stays in the current file, which is not read twice.
printf '{"v":1,"proc":"job","n":"cur1"}\n' > "$ES/job.jsonl"
export_req '[{"stream":"runs","key":"job"}]' "$TMP/pv1.json"
p=$(pos_of "$TMP/pv1.json")
mv "$ES/job.jsonl" "$ES/job.jsonl.1"
printf '{"v":1,"proc":"job","n":"cur2"}\n' > "$ES/job.jsonl"
export_req "$(runs_req "$p")" "$TMP/pv2.json"
p=$(pos_of "$TMP/pv2.json")
python3 - "$ES/job.jsonl.1" <<'EOF2'
import sys
with open(sys.argv[1], "a") as f:
    for i in range(2000):
        f.write('{"v":1,"proc":"job","n":"late%d","pad":"%s"}\n' % (i, "z" * 700))
EOF2
printf '{"v":1,"proc":"job","n":"cur3"}\n' >> "$ES/job.jsonl"
: > "$seen"; polls=0
while [ $polls -lt 10 ]; do
  export_req "$(runs_req "$p")" "$TMP/pv.json"
  polls=$((polls + 1))
  pyj "$TMP/pv.json" "'\n'.join(json.loads(l)['n'] for l in S[0]['lines'])" | grep . >> "$seen"
  p=$(pos_of "$TMP/pv.json")
  [ "$(pyj "$TMP/pv.json" "S[0][\"more\"]")" = True ] || break
done
check "late .1 lines larger than the cap: every line once, and the current file is not re-read" \
  '[ "$(sort "$seen" | uniq -d | wc -l | tr -d " ")" = 0 ] && [ "$(wc -l < "$seen" | tr -d " ")" = 2001 ] && [ "$(tail -1 "$seen")" = cur3 ] && [ $polls -ge 2 ]' \
  "$(wc -l < "$seen") lines in $polls polls; dups: $(sort "$seen" | uniq -d | head -3)"

# Fail closed: without the rules file nothing is exported.
mkdir -p "$TMP/norules/bin"
cp "$PR" "$TMP/norules/bin/procrun"
out=$(printf '[]' | PROCRUN_REGISTRY="$EX/processes.toml" PROCRUN_STATE_DIR="$ES" "$TMP/norules/bin/procrun" export); rc=$?
check "export fails closed when the redaction rules are missing" \
  '[ "$rc" = 2 ] && printf "%s" "$out" | grep -q "redaction rules unavailable" && ! printf "%s" "$out" | grep -q exporthost' "$out"

# A registry name that is a path cannot be declared either.
printf '[[process]]\nname = "../escape"\nkind = "sentinel"\n' > "$TMP/r-pathname.toml"
out=$(PROCRUN_REGISTRY="$TMP/r-pathname.toml" "$PR" validate 2>&1)
check "validate fails a process name that is a path" \
  'printf "%s" "$out" | grep -q "name must not contain a path separator"' "$out"

# ── 1.7: install ─────────────────────────────────────────────────────────────
echo "install"
IH="$TMP/install-home"
mkdir -p "$IH"
(
  ok() { :; }; warn() { :; }; skip() { :; }
  HOME="$IH" DOTFILES_DIR="$DOT"
  # shellcheck source=../lib/links.sh
  . "$DOT/lib/links.sh"
  links_reset_counters
  link_bin_tools
)
check "link_bin_tools installs ~/.local/bin/procrun -> bin/procrun" \
  '[ -L "$IH/.local/bin/procrun" ] && [ "$(readlink "$IH/.local/bin/procrun")" = "$PR" ]'
out=$(cd / && env -i HOME="$HOME" PATH=/usr/bin:/bin PROCRUN_UV="$PROCRUN_UV" "$IH/.local/bin/procrun" --help 2>&1 | head -1)
check "the installed link runs under cron's minimal PATH" 'printf "%s" "$out" | grep -q "procrun: run, check and validate"' "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
