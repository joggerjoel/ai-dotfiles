#!/usr/bin/env bash
# Tests for herdr-paste.py. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Every external command is stubbed on PATH and no test touches the real
# herdr socket or the fleet. Run it IN PLACE — copying it elsewhere breaks the
# relative stub path and would reach real commands.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
P="$HERE/herdr-paste.py"
export P TMP   # the python probes below read these from the environment
pass=0 fail=0

TMP=$(mktemp -d -t herdrpaste-test) || exit 1
trap 'rm -rf "$TMP"' EXIT

export PATH="$ROOT/tests/paste-stubs:$PATH"

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

# --- payload validation ------------------------------------------------------
# `_validate` is an internal entry point so the rules can be exercised without
# a socket, a pane, or a human. It reads the candidate on stdin — never argv,
# which is world-readable through `ps`.

v() { printf '%s' "$1" | python3 "$P" _validate >/dev/null 2>&1; echo $?; }

eq "validate: a plain token is accepted" 0 "$(v 'sk-ant-abc123')"
eq "validate: empty is rejected" 1 "$(v '')"
eq "validate: an interior newline is rejected" 1 "$(v 'ab
cd')"
eq "validate: a tab is rejected" 1 "$(v "$(printf 'ab\tcd')")"
eq "validate: a C0 control byte is rejected" 1 "$(v "$(printf 'ab\001cd')")"
eq "validate: DEL is rejected" 1 "$(v "$(printf 'ab\177cd')")"

# These two cannot go through `v`: command substitution strips a trailing
# newline, and a literal C1 byte does not survive being typed into this file.
# Build them in python and feed them straight to stdin.
py_v() {  # <python-expression producing the candidate>
  python3 -c "import sys; sys.stdout.write($1)" |
    python3 "$P" _validate >/dev/null 2>&1
  echo $?
}

eq "validate: a trailing newline is rejected" 1 "$(py_v "'abcd' + chr(0x0A)")"
eq "validate: a C1 control codepoint is rejected" 1 "$(py_v "'abcd' + chr(0x85)")"
eq "validate: a C1 CSI codepoint is rejected" 1 "$(py_v "'abcd' + chr(0x9B)")"
eq "validate: non-ASCII is rejected" 1 "$(v 'abé')"
eq "validate: a bidi override is rejected" 1 "$(v 'ab‮cd')"

# A quote and a backslash are legal in a credential. They are dangerous only
# to a naive encoder, and the encoder — not the validator — is what handles
# them. Rejecting them here would refuse valid tokens for no gain.
eq "validate: a double quote is accepted" 0 "$(v 'ab"cd')"
eq "validate: a backslash is accepted" 0 "$(v 'ab\cd')"

# The rejection has to say what was wrong; a bare failure sends the operator
# hunting through a credential they cannot see.
printf '%s' "$(printf 'ab\001cd')" | python3 "$P" _validate 2>&1 |
  grep -qi "control\|printable\|ascii" &&
  ok "validate: rejection names the offending class" ||
  ko "validate: rejection names the offending class"

# The value must never be echoed, even back to the operator.
out=$(printf '%s' 'SENTINEL-XYZ' | python3 "$P" _validate 2>&1)
printf '%s' "$out" | grep -q 'SENTINEL-XYZ' &&
  ko "validate: never echoes the value" "leaked it" ||
  ok "validate: never echoes the value"

# --- CLI surface -------------------------------------------------------------

python3 "$P" >/dev/null 2>&1
eq "no verb exits 2 (usage)" 2 "$?"

python3 "$P" 2>&1 | grep -qi usage &&
  ok "no verb prints a usage line" ||
  ko "no verb prints a usage line"

python3 "$P" bogus >/dev/null 2>&1
eq "an unknown verb exits 2" 2 "$?"

# --- transport ---------------------------------------------------------------
# A stand-in daemon on a unix socket. It records the exact bytes it received so
# the encoding assertions can inspect the wire rather than trust the sender.

export PASTE_FIXTURE="$TMP/fx"; mkdir -p "$PASTE_FIXTURE"
export PASTE_CALLS="$TMP/calls"
export PASTE_WIRE="$TMP/wire"
export HERDR_SOCKET_PATH="$TMP/herdr.sock"

schema() { printf '{"protocol":%s}\n' "$1" > "$PASTE_FIXTURE/schema.json"; }
schema 19

daemon() {  # <ok|err|silent|eof>  — backgrounded; returns once it is listening
  rm -f "$HERDR_SOCKET_PATH" "$PASTE_WIRE"
  python3 - "$HERDR_SOCKET_PATH" "$1" "$PASTE_WIRE" <<'PY' &
import json, os, socket, sys, time
path, mode, wire = sys.argv[1], sys.argv[2], sys.argv[3]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path); s.listen(1)
open(path + ".ready", "w").close()
# Accept repeatedly until someone actually sends a request. preflight() opens
# a connection and closes it without writing — a one-shot accept() would be
# eaten by that probe and the real request would find no server. The real
# daemon serves many connections; a stub that serves one models something that
# does not exist.
#
# The timeout matters too: before the client exists (a TDD red run) an untimed
# accept() hangs the whole suite instead of failing it.
s.settimeout(12)
line = b""
while True:
    try:
        c, _ = s.accept()
    except (socket.timeout, OSError):
        s.close(); sys.exit(0)
    # Read EVERYTHING sent, not just the first line. readline() would make the
    # "exactly one JSON object reached the socket" assertion untestable: an
    # injected second request lives on the NEXT line, which readline() never
    # sees, so the check would pass even against an interpolating encoder.
    c.settimeout(2)
    buf = b""
    try:
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            buf += chunk
            if mode != "drain" and buf.endswith(b"\n"):
                break
    except (socket.timeout, OSError):
        pass
    line = buf
    if line:
        break
    c.close()  # a bare preflight probe; keep listening for the real request
open(wire, "wb").write(line)
if mode == "ok":
    c.sendall(json.dumps({"id": "paste-1", "result": {}}).encode() + b"\n")
elif mode == "err":
    c.sendall(json.dumps({"id": "paste-1",
                          "error": {"message": "no such pane"}}).encode() + b"\n")
elif mode == "silent":
    time.sleep(9)
# mode "eof": close with no reply at all — the daemon may still have acted.
c.close(); s.close()
PY
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$HERDR_SOCKET_PATH.ready" ] && break
    python3 -c "import time; time.sleep(0.05)"
  done
  rm -f "$HERDR_SOCKET_PATH.ready"
}

rm -f "$HERDR_SOCKET_PATH"
python3 "$P" _rpc >/dev/null 2>&1
eq "preflight: a missing socket exits 6, fast" 6 "$?"

daemon ok; schema 21
python3 "$P" _rpc >/dev/null 2>&1
eq "protocol mismatch refuses to run, exits 5" 5 "$?"
schema 19

daemon ok
python3 "$P" _rpc >/dev/null 2>&1
eq "a success reply exits 0" 0 "$?"

daemon err
python3 "$P" _rpc >/dev/null 2>&1
eq "an error reply exits 1" 1 "$?"

daemon silent
python3 "$P" _rpc --timeout 1 >/dev/null 2>&1
eq "a silent daemon exits 3 (ambiguous, not error)" 3 "$?"

# EOF after the write is NOT an error: the daemon may have acted before closing.
# Reporting "not delivered" there would be the misreport exit 3 exists to stop.
daemon eof
python3 "$P" _rpc --timeout 2 >/dev/null 2>&1
eq "EOF with no reply exits 3, not 1" 3 "$?"

# --- encoding ----------------------------------------------------------------
# The payload is attacker-supplied by construction. --raw-text bypasses
# validation so the encoder is tested against inputs the validator refuses;
# testing it through the validator would exercise a path production never takes.

daemon ok
python3 -c "import sys; sys.stdout.write('a\"b\\\\c' + chr(0x0A) + 'd')" |
  python3 "$P" _rpc --raw-text >/dev/null 2>&1

eq "hostile text still yields exactly one JSON line" 1 \
   "$(wc -l < "$PASTE_WIRE" | tr -d ' ')"

python3 - <<'PY' && ok "hostile text round-trips through json.dumps" \
                 || ko "hostile text round-trips through json.dumps"
import json, os, sys
o = json.load(open(os.environ["PASTE_WIRE"]))
want = 'a"b\\c' + chr(0x0A) + 'd'
sys.exit(0 if o["params"]["text"] == want else 1)
PY

python3 - <<'PY' && ok "the request names pane.send_input with keys enter" \
                 || ko "the request names pane.send_input with keys enter"
import json, os, sys
o = json.load(open(os.environ["PASTE_WIRE"]))
sys.exit(0 if o["method"] == "pane.send_input"
         and o["params"]["keys"] == ["enter"] else 1)
PY

# --- listing and label sanitisation -------------------------------------------
# `list` runs the preflight and protocol gates like every other verb — no
# daemon means no panes — so it needs one listening. It never writes, so a
# daemon that only ever accepts is enough.
daemon ok

# Tab titles and tmux session names are set by whatever runs inside a pane —
# remote ssh peers, CI output. They are untrusted input rendered into the
# operator's terminal, so the fixtures below carry real attacks.

cat > "$PASTE_FIXTURE/workspaces.json" <<'J'
{"result":{"workspaces":[{"workspace_id":"w3","label":"aorus4"},
{"workspace_id":"w9","label":"aorus8-tmux"}]}}
J
cat > "$PASTE_FIXTURE/panes.json" <<'J'
{"result":{"panes":[{"pane_id":"w3:p1","workspace_id":"w3","tab_id":"w3:t1"},
{"pane_id":"w9:p2","workspace_id":"w9","tab_id":"w9:t2"}]}}
J

# A benign tab, and one whose name carries an OSC title-set sequence, a bidi
# override, and a zero-width joiner.
python3 - <<'PY2'
import json, os
tabs = {"result": {"tabs": [
    {"tab_id": "w3:t1", "workspace_id": "w3", "label": "claude"},
    {"tab_id": "w9:t2", "workspace_id": "w9",
     "label": chr(0x1B) + "]0;pwned" + chr(0x07) + "07-dice"
              + chr(0x202E) + "evil" + chr(0x200D)},
]}}
json.dump(tabs, open(os.environ["PASTE_FIXTURE"] + "/tabs.json", "w"))
PY2

out=$(python3 "$P" list)

printf '%s' "$out" | grep -q "aorus4" &&
  ok "list: joins workspace, tab and pane" ||
  ko "list: joins workspace, tab and pane"

printf '%s' "$out" | grep -q "w9:p2" &&
  ok "list: includes a -tmux space" ||
  ko "list: includes a -tmux space"

printf '%s' "$out" | grep -q "07-dice" &&
  ok "list: keeps the printable part of a hostile label" ||
  ko "list: keeps the printable part of a hostile label"

python3 - <<'PY2' && ok "list: strips escape, bidi and zero-width from labels" \
                  || ko "list: strips escape, bidi and zero-width from labels"
import subprocess, sys, os
out = subprocess.run(["python3", os.environ["P"], "list"],
                     capture_output=True, text=True).stdout
# Newline is the output's own line separator, not label content — counting it
# as a control character would fail this assertion on every multi-line listing.
bad = [c for c in out if c != chr(0x0A) and (
       ord(c) < 0x20 or ord(c) == 0x7F
       or 0x80 <= ord(c) <= 0x9F or c in (chr(0x202E), chr(0x200D)))]
sys.exit(1 if bad else 0)
PY2

python3 "$P" list --json | python3 -c "
import json, sys
r = json.load(sys.stdin)
sys.exit(0 if r[0]['tab_id'] == 'w3:t1' and r[1]['pane_id'] == 'w9:p2' else 1)" &&
  ok "list --json emits tab_id, the producer for --expect-tab" ||
  ko "list --json emits tab_id, the producer for --expect-tab"

python3 "$P" list --json | grep -q $'\033' &&
  ko "list --json escapes labels too" "raw ESC in json" ||
  ok "list --json escapes labels too"

# --- send ---------------------------------------------------------------------

daemon ok
python3 "$P" send --pane w3:p1 --stdin --yes </dev/null >/dev/null 2>&1
eq "--pane without --expect-tab is a usage error" 2 "$?"

daemon ok
printf '%s' 'tok-123' |
  python3 "$P" send --pane w3:p1 --expect-tab w3:t1 --stdin --yes >/dev/null 2>&1
eq "a scripted send with matching identity delivers" 0 "$?"

# The recycled-id case: the pane_id is still present in a fresh listing, but it
# now sits under a different tab. A presence check would wave this through.
daemon ok
printf '%s' 'tok-123' |
  python3 "$P" send --pane w3:p1 --expect-tab w9:t2 --stdin --yes >/dev/null 2>&1
eq "identity mismatch aborts with exit 4" 4 "$?"

[ -s "$PASTE_WIRE" ] &&
  ko "a mismatch writes nothing to the socket" "the wire has content" ||
  ok "a mismatch writes nothing to the socket"

daemon ok
printf '%s' 'tok-123' |
  python3 "$P" send --pane w9:p9 --expect-tab w9:t2 --stdin --yes >/dev/null 2>&1
eq "a pane absent from a fresh listing aborts with exit 4" 4 "$?"

# The credential must not reach any stream, nor any command line. The herdr
# stub records its own argv, which is what makes the second assertion real.
: > "$PASTE_CALLS"
daemon ok
out=$(printf '%s' 'SENTINEL-XYZ' |
  python3 "$P" send --pane w3:p1 --expect-tab w3:t1 --stdin --yes 2>&1)

printf '%s' "$out" | grep -q 'SENTINEL-XYZ' &&
  ko "the value never reaches stdout or stderr" "leaked" ||
  ok "the value never reaches stdout or stderr"

grep -q 'SENTINEL-XYZ' "$PASTE_CALLS" &&
  ko "the value never reaches argv" "found in a recorded command line" ||
  ok "the value never reaches argv"

# It did reach the socket, though — otherwise the two assertions above would
# pass for a program that simply never sends anything.
grep -q 'SENTINEL-XYZ' "$PASTE_WIRE" &&
  ok "the value does reach the socket" ||
  ko "the value does reach the socket" "nothing delivered"

# Validation binds the send path, not just the internal verb.
daemon ok
python3 -c "import sys; sys.stdout.write('bad' + chr(0x0A))" |
  python3 "$P" send --pane w3:p1 --expect-tab w3:t1 --stdin --yes >/dev/null 2>&1
eq "an invalid payload is refused before any write" 1 "$?"

# --- serve: binding and authorization ------------------------------------------
# The stub resolves 127.0.0.1 so a test server binds somewhere harmless. On the
# real node this is the tailnet address and nothing else.

daemon ok
PASTE_TS_FAIL=1 python3 "$P" serve >/dev/null 2>&1
eq "serve refuses to start when address resolution fails" 6 "$?"

daemon ok
PASTE_TS_MULTI=1 python3 "$P" serve >/dev/null 2>&1
eq "serve refuses to start on an ambiguous address" 6 "$?"

# Everything below drives a live server. It is started once, probed, then shut
# down through its own endpoint.
daemon ok
python3 "$P" serve --port 8779 --timeout 30 > "$TMP/serve.out" 2>&1 &
SERVE_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  grep -q 'http://' "$TMP/serve.out" 2>/dev/null && break
  python3 -c "import time; time.sleep(0.25)"
done
CAP_URL=$(grep -o 'http://[^ ]*' "$TMP/serve.out" | head -1)
CAP_PATH=${CAP_URL##*/}
export CAP_PATH   # the python probes below read it from the environment

[ -n "$CAP_PATH" ] &&
  ok "serve prints a capability URL" ||
  ko "serve prints a capability URL" "no URL in output"

python3 - <<'PY2' && ok "the capability is long enough to be unguessable" \
                  || ko "the capability is long enough to be unguessable"
import os, sys
sys.exit(0 if len(os.environ.get("CAP_PATH", "")) >= 32 else 1)
PY2

probe() {  # <path> <method> [header:value ...] -> status code
  python3 - "$@" <<'PY2'
import sys, urllib.error, urllib.request
path, method = sys.argv[1], sys.argv[2]
req = urllib.request.Request("http://127.0.0.1:8779" + path, method=method,
                             data=b"x=1" if method == "POST" else None)
for h in sys.argv[3:]:
    k, _, v = h.partition(":")
    req.add_header(k, v)
try:
    print(urllib.request.urlopen(req, timeout=5).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:
    print("ERR %s" % e)
PY2
}

eq "a wrong capability path 404s" 404 "$(probe /nope GET)"
eq "the capability path serves the page" 200 "$(probe "/$CAP_PATH" GET)"

eq "a foreign Host is refused" 403 \
   "$(probe "/$CAP_PATH" GET "Host:evil.example.com")"

eq "a POST with a foreign Origin is refused" 403 \
   "$(probe "/$CAP_PATH" POST "Origin:http://evil.example.com")"

# Absent is refused too: a legitimate same-origin form post carries one.
eq "a POST with no Origin is refused" 403 "$(probe "/$CAP_PATH" POST)"

kill "$SERVE_PID" 2>/dev/null
wait "$SERVE_PID" 2>/dev/null

# The capability is a bearer secret: it may reach the operator's own terminal,
# and nothing else. stdlib's default request logger would put it on stderr.
grep -q "$CAP_PATH" "$TMP/serve.out" &&
  ok "the capability appears in serve's own output (that is its purpose)" ||
  ko "the capability appears in serve's own output (that is its purpose)"

python3 - <<'PY2' && ok "the capability is never logged per-request" \
                  || ko "the capability is never logged per-request"
import os, sys
out = open(os.environ["TMP"] + "/serve.out").read()
cap = os.environ["CAP_PATH"]
# One occurrence is the printed URL. More means the request logger echoed it.
sys.exit(0 if out.count(cap) <= 1 else 1)
PY2

# --- serve: the two-step flow, QR, and lifecycle -------------------------------

grep -q 'qrencode ' "$PASTE_CALLS" &&
  ok "serve renders a QR code when qrencode is present" ||
  ko "serve renders a QR code when qrencode is present"

python3 - <<'PY2' && ok "the capability URL never reaches qrencode's argv" \
                  || ko "the capability URL never reaches qrencode's argv"
import os, sys
calls = open(os.environ["PASTE_CALLS"]).read()
qr = [ln for ln in calls.splitlines() if ln.startswith("qrencode ")]
cap = os.environ["CAP_PATH"]
sys.exit(1 if any(cap in ln or "http" in ln for ln in qr) else 0)
PY2

# The flow: GET renders the picker, the first POST renders a confirmation view
# and writes nothing, and only the second POST delivers.
daemon ok
: > "$PASTE_CALLS"
python3 "$P" serve --port 8781 --timeout 30 > "$TMP/serve2.out" 2>&1 &
S2=$!
export S2
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  grep -q 'http://' "$TMP/serve2.out" 2>/dev/null && break
  python3 -c "import time; time.sleep(0.25)"
done
C2=$(grep -o 'http://[^ ]*' "$TMP/serve2.out" | head -1); C2=${C2##*/}
export C2

post() {  # <body> -> "status|body"
  python3 - "$1" <<'PY2'
import os, sys, urllib.error, urllib.request
body = sys.argv[1].encode()
req = urllib.request.Request(
    "http://127.0.0.1:8781/" + os.environ["C2"], data=body, method="POST")
req.add_header("Origin", "http://127.0.0.1:8781")
req.add_header("Content-Type", "application/x-www-form-urlencoded")
try:
    r = urllib.request.urlopen(req, timeout=5)
    print("%s|%s" % (r.status, r.read().decode("utf-8", "replace")))
except urllib.error.HTTPError as e:
    print("%s|%s" % (e.code, e.read().decode("utf-8", "replace")))
except Exception as e:
    print("ERR|%s" % e)
PY2
}

r1=$(post 'pane_id=w3:p1&tab_id=w3:t1&value=SENTINEL-PAGE')
printf '%s' "$r1" | grep -q '^200' &&
  ok "the first POST is accepted" ||
  ko "the first POST is accepted" "$r1"

printf '%s' "$r1" | grep -qi 'confirm' &&
  ok "the first POST renders a confirmation view" ||
  ko "the first POST renders a confirmation view"

[ -s "$PASTE_WIRE" ] &&
  ko "the first POST writes nothing to the socket" "the wire has content" ||
  ok "the first POST writes nothing to the socket"

printf '%s' "$r1" | grep -q 'SENTINEL-PAGE' &&
  ko "the value never appears in a response body" "echoed back" ||
  ok "the value never appears in a response body"

r2=$(post 'confirm=yes')
printf '%s' "$r2" | grep -q '^200' &&
  ok "the second POST delivers" ||
  ko "the second POST delivers" "$r2"

grep -q 'SENTINEL-PAGE' "$PASTE_WIRE" &&
  ok "the value reaches the socket only on the second POST" ||
  ko "the value reaches the socket only on the second POST"

# Bounded wait, never `wait` outright: before the watchdog exists a serve that
# does not shut itself down would hang the suite instead of failing it.
S2_CODE=$(python3 - <<'PY2'
import os, subprocess, sys, time
pid = os.environ["S2"]
for _ in range(40):
    if subprocess.run(["kill", "-0", pid], capture_output=True).returncode != 0:
        print("exited"); sys.exit(0)
    time.sleep(0.25)
print("still-running"); sys.exit(0)
PY2
)
if [ "$S2_CODE" = exited ]; then
  wait "$S2"; eq "serve exits 0 after a delivered send" 0 "$?"
else
  ko "serve exits 0 after a delivered send" "still running after 10s"
  kill "$S2" 2>/dev/null; wait "$S2" 2>/dev/null
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
