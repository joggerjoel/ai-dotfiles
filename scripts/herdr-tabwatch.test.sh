#!/usr/bin/env bash
# Tests for herdr-tabwatch.py. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# No test touches a real herdr socket, a real ssh, or the fleet. A stub daemon
# on a unix socket records every request, so the assertions inspect what the
# watcher decided to send rather than trusting it.

HERE=$(cd "$(dirname "$0")" && pwd)
W="$HERE/herdr-tabwatch.py"
pass=0 fail=0

# Short root: a unix socket path cannot exceed 104 bytes on macOS.
TMP=$(mktemp -d "/tmp/tabwatch.XXXXXX") || exit 1
DPID=""
# The stub is a server: it never exits on its own. It also inherits this
# script's stdout, so leaving one running holds the pipe open and any
# `... | tail` on this script hangs forever rather than printing the results.
# Hence: exactly one at a time, its output to a file, and killed on the way out.
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

export HERDR_SOCKET_PATH="$TMP/herdr.sock"
WIRE="$TMP/wire"

# A stand-in herdr: answers workspace.list / pane.list from fixtures, records
# everything, and emits one tab_created frame to drive the watcher.
daemon() {  # <workspace-label> <pane-count-for-tab>
  [ -n "$DPID" ] && { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }
  rm -f "$HERDR_SOCKET_PATH" "$WIRE"
  python3 - "$HERDR_SOCKET_PATH" "$1" "$2" "$WIRE" "${PREEXISTING:-0}" "${PANETEXT:-}" >>"$TMP/stub.log" 2>&1 <<'PY' &
import json, socket, sys, threading
path, label, panes, wire = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
preexisting, panetext = sys.argv[5] == "1", sys.argv[6]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path); s.listen(8)
open(path + ".ready", "w").close()
log = open(wire, "a", buffering=1)
lock = threading.Lock()


def reply(conn, obj):
    conn.sendall((json.dumps(obj) + "\n").encode())


# Threaded on purpose. The watcher holds the subscription connection open for
# its whole life and opens SEPARATE connections for workspace.list and
# pane.list while handling an event. A single-threaded stub sits blocked on the
# subscription and never accepts those, which deadlocks the thing under test
# rather than testing it.
def serve(c):
    try:
        f = c.makefile("rb")
        line = f.readline()
        if not line:
            return
        req = json.loads(line)
        with lock:
            log.write(json.dumps(req) + "\n")
        m = req.get("method")
        if m == "events.subscribe":
            reply(c, {"id": req["id"],
                      "result": {"type": "subscription_started"}})
            reply(c, {"event": "tab_created", "data": {"type": "tab_created",
                      "tab": {"tab_id": "w9:t1", "workspace_id": "w9",
                              "label": "shell", "number": 1, "focused": True,
                              "pane_count": 1, "agent_status": "unknown"}}})
            while f.readline():   # hold the stream open under the watcher
                pass
        elif m == "workspace.list":
            reply(c, {"id": req["id"], "result": {"workspaces": [
                {"workspace_id": "w9", "label": label}]}})
        elif m == "tab.list":
            reply(c, {"id": req["id"], "result": {"tabs": (
                [{"tab_id": "w9:t1", "workspace_id": "w9"}]
                if preexisting else [])}})
        elif m == "pane.read":
            reply(c, {"id": req["id"], "result": {"text": panetext}})
        elif m == "pane.list":
            reply(c, {"id": req["id"], "result": {"panes": [
                {"pane_id": "w9:p%d" % i, "tab_id": "w9:t1"}
                for i in range(1, panes + 1)]}})
        elif m == "pane.wait_for_output":
            reply(c, {"id": req["id"], "result": {"matched": True}})
        else:
            reply(c, {"id": req["id"], "result": {}})
    except (OSError, ValueError):
        pass
    finally:
        try:
            c.close()
        except OSError:
            pass


while True:
    try:
        c, _ = s.accept()
    except OSError:
        break
    threading.Thread(target=serve, args=(c,), daemon=True).start()
PY
  DPID=$!
  local n=0
  while [ $n -lt 100 ]; do
    [ -e "$HERDR_SOCKET_PATH.ready" ] && break
    sleep 0.05; n=$((n + 1))
  done
  [ -e "$HERDR_SOCKET_PATH.ready" ] || { ko "daemon bound" "never ready"; return 1; }
  rm -f "$HERDR_SOCKET_PATH.ready"
}

# A fake ssh config, so the allowlist is ours and not the developer's.
export HOME="$TMP/home"; mkdir -p "$HOME/.ssh" "$TMP/bin"
SELF=$(hostname -s 2>/dev/null || hostname)
cat > "$HOME/.ssh/config" <<EOF
Host aorus4
Host aorus5
Host *-jump
Host $SELF
Host selfalias
Host unresolvable
EOF


# The PATH the watcher actually runs under, read from the generator that writes
# it. Hardcoding a second copy here is how the original bug happened: a fact
# about the daemon's environment lived somewhere nothing checked.
LAUNCHD_PATH=$(grep -o '<key>PATH</key><string>[^<]*' "$HERE/herdr-node.sh" |
               head -1 | sed 's/.*<string>//; s|${HOME}|'"$HOME"'|g')
[ -n "$LAUNCHD_PATH" ] || { echo "cannot read the plist PATH from herdr-node.sh"; exit 1; }

# Stub ssh so `ssh -G` resolution is ours. `selfalias` is the macstudio shape:
# an alias that is nothing like the hostname but points back at this machine.
cat > "$TMP/bin/ssh" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-G" ]; then
  case "\$2" in
    selfalias|$SELF) echo "hostname $SELF" ;;
    unresolvable)    exit 0 ;;
    *)               echo "hostname \$2.example.net" ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/ssh"
export PATH="$TMP/bin:$PATH"

PY3=$(command -v python3)

run_watch_with_path() {  # process one event under an explicit PATH, then stop
  PATH="$1" "$PY3" "$W" >"$TMP/out" 2>&1 &
  local pid=$!
  local n=0
  while [ $n -lt 60 ]; do
    grep -q "w9:t1" "$TMP/out" 2>/dev/null && break
    sleep 0.1; n=$((n + 1))
  done
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

run_watch() { run_watch_with_path "$PATH"; }

# grep -c prints 0 and exits 1 when it matches nothing; the substitution still
# captures the 0, so no `|| echo 0` — that appended a SECOND zero and made
# every "expected 0" assertion compare against "0\n0".
sent() { grep -c '"method": "pane.send_input"' "$WIRE" 2>/dev/null; }

# --- the allowlist -----------------------------------------------------------

daemon aorus4 1 && run_watch
eq "a workspace named after a known ssh host is connected" 1 "$(sent)"
grep -q 'ssh -t aorus4' "$WIRE" &&
  ok "the command names the workspace's host" ||
  ko "the command names the workspace's host" "wire: $(cat "$WIRE")"
grep -q 'hostname' "$WIRE" &&
  ok "the command asks the host to identify itself" ||
  ko "the command asks the host to identify itself"

# One line, not two: a separate `hostname` write would race the ssh handshake.
eq "it is a single write, not a racy pair" 1 "$(sent)"

daemon nowhere 1 && run_watch
eq "a workspace that is not an ssh host is left alone" 0 "$(sent)"
grep -q "not an ssh host" "$TMP/out" &&
  ok "and says why" ||
  ko "and says why" "out: $(cat "$TMP/out")"

# `*-jump` configures other hosts; it is not a host. Treating the pattern as
# one would let a label like `foo-jump` dial a machine that does not exist.
daemon foo-jump 1 && run_watch
eq "a wildcard ssh-config pattern is not a host" 0 "$(sent)"

# --- not ssh'ing into ourselves ----------------------------------------------

daemon "$SELF" 1 && run_watch
eq "the node's own workspace is not ssh'd into" 0 "$(sent)"
grep -q "is this machine" "$TMP/out" &&
  ok "and says so" ||
  ko "and says so" "out: $(cat "$TMP/out")"

# The real shape of this bug, found by dry-running on macstudio: the workspace
# is labelled `macstudio` because that is its ssh ALIAS, while the box answers
# to JoggerJoels-Mac-Studio and carries `Host macstudio` in its own ssh config.
# The label never matches the hostname as a string, so comparing names alone
# has the node cheerfully ssh into itself. Resolution is what catches it.
daemon selfalias 1 && run_watch
eq "an ssh ALIAS pointing back at this machine is not dialled" 0 "$(sent)"
grep -q "is this machine" "$TMP/out" &&
  ok "and recognises it through ssh -G, not the name" ||
  ko "and recognises it through ssh -G, not the name" "out: $(cat "$TMP/out")"


# An allowlisted alias that ssh cannot resolve is the third answer the old
# boolean had nowhere to put. A missing ssh, a timeout, or a config naming no
# hostname all reach here, and all of them used to mean "elsewhere, go ahead".

daemon unresolvable 1 && run_watch
eq "an allowlisted alias ssh cannot resolve is not dialled" 0 "$(sent)"
grep -q "cannot resolve" "$TMP/out" &&
  ok "and says it refused rather than claiming the box is ours" ||
  ko "and says it refused rather than claiming the box is ours" \
     "out: $(cat "$TMP/out")"

# The probe that decides identity has to run where the daemon runs. Point PATH
# somewhere it cannot be found and the real one still has to answer, which is
# only true while the lookup is absolute. macOS only, because scutil is.

if [ "$(uname)" = Darwin ]; then
  LHN=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null | cut -d. -f1 | tr 'A-Z' 'a-z')
  if [ -n "$LHN" ]; then
    got=$(PATH="/usr/bin:/bin" "$PY3" -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("w", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0]]
spec.loader.exec_module(m)
print(" ".join(sorted(m.local_names())))' "$W")
    case " $got " in
      *" $LHN "*) ok "LocalHostName is found on a PATH that cannot reach scutil" ;;
      *) ko "LocalHostName is found on a PATH that cannot reach scutil" \
            "wanted $LHN in [$got]" ;;
    esac
  else
    printf '  SKIP  LocalHostName is found on a PATH that cannot reach scutil (unset here)\n'
  fi
fi

# refusal_to_dial takes the identity set as an argument, so the cases that used
# to need a fixture binary and an exported override are a function call.

pure=$("$PY3" -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("w", sys.argv[1])
m = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0]]
spec.loader.exec_module(m)
print("none" if m.refusal_to_dial("anything", None) else "dialled")' "$W")
eq "nothing is dialled while this machine has no known identity" "none" "$pure"

# --- refusing to guess -------------------------------------------------------
# A tab with several panes is not the fresh tab this assumed. Typing into an
# arbitrary one would land a command in the middle of someone's work.

daemon aorus4 3 && run_watch
eq "a tab with several panes is left alone" 0 "$(sent)"
grep -q "no single fresh pane" "$TMP/out" &&
  ok "and says it refused rather than picked" ||
  ko "and says it refused rather than picked" "out: $(cat "$TMP/out")"

# --- replayed history --------------------------------------------------------
# events.subscribe does NOT open a clean stream: it replays historical
# tab_created events. Treating those as new made the watcher type an ssh
# command into a live pane running an agent session — and under launchd's
# KeepAlive it would have done so again on every restart. A tab that already
# existed when we subscribed is never ours to touch.

PREEXISTING=1 daemon aorus4 1 && run_watch
eq "a tab replayed from before we subscribed is never typed into" 0 "$(sent)"
grep -q "replay" "$TMP/out" &&
  ok "and names it as a replay rather than a mystery skip" ||
  ko "and names it as a replay rather than a mystery skip" \
     "out: $(cat "$TMP/out")"
unset PREEXISTING

# --- panes with work in them -------------------------------------------------
# Independent of the replay guard: whatever the event says, a pane with
# scrollback belongs to someone. This is the guard that would have spared the
# agent session even if the replay check had been missed.

PANETEXT='$ npm test
running 40 tests
  auth ok
  paste ok
  tabwatch ok
all green
$ ' daemon aorus4 1 && run_watch
eq "a pane that already has output is not typed into" 0 "$(sent)"
grep -q "already has output" "$TMP/out" &&
  ok "and says the pane was in use" ||
  ko "and says the pane was in use" "out: $(cat "$TMP/out")"
unset PANETEXT

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
