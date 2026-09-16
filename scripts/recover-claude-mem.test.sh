#!/usr/bin/env bash
# Tests for recover-claude-mem.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Nothing here touches a real claude-mem worker. Every case points the script at
# a scratch CLAUDE_MEM_HOME and CLAUDE_CONFIG_DIR and at a port this file owns,
# so the plugin root is never found and no worker is ever started or stopped.
#
# The case that matters is "no listener reaches the start path". `lsof` exits 1
# when nothing is listening, and under `set -euo pipefail` that status killed the
# script at the assignment — so a host whose worker had died entirely got a
# silent exit 1 instead of a new worker, and `--restart` could never reach its
# "nothing to restart" branch. A test that only ever runs with a live worker
# never sees it.

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/recover-claude-mem.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/recoverclaudemem-test.XXXXXX") || exit 1
cleanup() {
  [ -n "${DECOY_PID:-}" ] && kill "$DECOY_PID" 2>/dev/null
  [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

# A port nothing on this machine is listening on. Not "probably free" — asked.
free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# Scratch dirs, so find_plugin_root() always fails and worker.pid is absent.
# CLAUDE_MEM_HOME empty means recorded_pid() returns "", which is what makes the
# unverified-process guard refuse rather than kill.
run() { # <port> [args...]
  local port="$1"; shift
  CLAUDE_MEM_WORKER_PORT="$port" \
  CLAUDE_MEM_HOME="$TMP/mem" \
  CLAUDE_CONFIG_DIR="$TMP/claude" \
    bash "$S" "$@" 2>&1
}

mkdir -p "$TMP/mem" "$TMP/claude"

# ── no listener ───────────────────────────────────────────────────────────────
PORT=$(free_port)

out=$(run "$PORT" --restart); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'worker not running; nothing to restart'; then
  ok "--restart with no worker says so and exits 0"
else
  ko "--restart with no worker says so and exits 0" "rc=$rc out='$out'"
fi

# Same dead port WITHOUT the flag must still reach the start path — it gets as
# far as looking for the plugin and fails there, which is the proof it did not
# die silently at the lsof pipeline.
out=$(run "$PORT"); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'plugin scripts not found'; then
  ok "no listener reaches the start path instead of exiting silently"
else
  ko "no listener reaches the start path instead of exiting silently" "rc=$rc out='$out'"
fi

# ── argument handling ─────────────────────────────────────────────────────────
out=$(run "$PORT" --bogus); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'unknown argument: --bogus'; then
  ok "an unknown argument is rejected"
else
  ko "an unknown argument is rejected" "rc=$rc out='$out'"
fi

# ── a healthy worker is left alone without the flag ───────────────────────────
HEALTHY_PORT=$(free_port)
python3 - "$HEALTHY_PORT" >/dev/null 2>&1 <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
STUB_PID=$!
sleep 1

out=$(run "$HEALTHY_PORT"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'nothing to recover'; then
  ok "a healthy worker is left alone without --restart"
else
  ko "a healthy worker is left alone without --restart" "rc=$rc out='$out'"
fi

# ── the stop guard ────────────────────────────────────────────────────────────
# The stub answers /health, so --restart is the path that wants to stop it. It is
# not the recorded worker, so the script must refuse and leave it running. If
# this ever fails, the script kills processes it does not own.
out=$(run "$HEALTHY_PORT" --restart); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'refusing to stop PID'; then
  ok "--restart refuses to stop a process that is not the worker"
else
  ko "--restart refuses to stop a process that is not the worker" "rc=$rc out='$out'"
fi

if kill -0 "$STUB_PID" 2>/dev/null; then
  ok "the refused process is still running"
else
  ko "the refused process is still running" "the script killed PID $STUB_PID"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
