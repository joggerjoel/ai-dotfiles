#!/usr/bin/env bash
# herdr-auth.sh — bring the fleet's agent CLIs to a logged-in state.
#
# Two verbs:
#   status   read-only probe of every host; safe to run any time
#   login    drive the OAuth flows (see Task 3 and Task 5)
#
# The CLIs split into two classes. cursor-agent prints its login URL over a
# plain pipe and polls Cursor's servers, so it needs no PTY and the URL can be
# opened on any machine. codex and claude produce nothing without a controlling
# terminal, so they are driven inside herdr panes, which are PTYs.
#
# SECURITY: login URLs carry a PKCE challenge and are bearer credentials for
# that login attempt. They are held in shell variables, passed straight to
# `open`, and never written to disk or logged. See references/herdr-auth.md.
#
# bash 3.2 compatible (the node is macOS): no mapfile, no associative arrays.

set -uo pipefail
# -f disables pathname expansion. The host list is deliberately word-split from
# a space-separated string, and without -f a glob metacharacter in
# HERDR_AUTH_HOSTS would expand against files in the cwd instead of naming hosts.
set -f

HOSTS_DEFAULT="aorus aorus4 aorus5 aorus6 aorus7 aorus8"
HOSTS_STR="${HERDR_AUTH_HOSTS:-$HOSTS_DEFAULT}"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"
HERDR_AUTH_NO_WAIT="${HERDR_AUTH_NO_WAIT:-0}"
# Single source of truth for the poll ceiling default: used both by
# wait_for_login()'s own default and by cmd_login's timeout message, so the
# two can never drift apart.
POLL_CEILING_DEFAULT=300

# Single indirection point for every remote call, so tests can stub `ssh`.
remote() {
  local host="$1"; shift
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$host" "$@" 2>/dev/null
}

probe_cursor() {
  local out; out="$(remote "$1" 'bash -lc "cursor-agent status"')"
  case "$out" in
    *"Not logged in"*|"") echo missing ;;
    *) echo authed ;;
  esac
}

# codex writes its status line to STDERR, not stdout — verified on aorus7:
# stdout is 0 bytes, and `2>&1` is what surfaces "Logged in using ChatGPT".
# The 2>&1 must live INSIDE the remote command so the remote's stderr merges
# into the remote's stdout; remote()'s own 2>/dev/null still discards local ssh
# noise. Without this the probe reports every host as missing, and cmd_login
# then drives a fresh login on hosts that are already authenticated.
probe_codex() {
  local out; out="$(remote "$1" 'bash -lc "codex login status 2>&1"')"
  case "$out" in
    *"Logged in"*) echo authed ;;
    *) echo missing ;;
  esac
}

# How close to the edge counts as `expiring`. Refresh tokens run ~30 days, so
# three days is enough warning to act without the table crying wolf.
CLAUDE_WARN_HOURS="${HERDR_AUTH_WARN_HOURS:-72}"

# The classifier. Reads a credentials file on STDIN and prints a verdict — never
# a token, never a URL, never anything that could be a secret. Keeping it
# stdin-driven is what makes it testable against real JSON without any ssh.
#
# Why this is not `[ -f ~/.claude/.credentials.json ]`, which is what it used to
# be: that file is a shared store. The supabase MCP plugin writes `mcpOAuth`
# entries into it, so it exists on hosts that have never logged into Claude at
# all. On 2026-08-11 the old probe called all six hosts authed while aorus4 had
# no `claudeAiOauth` block whatsoever and aorus6's had expired a fortnight
# earlier — a status table that reports the opposite of the truth is worse than
# no status table.
#
# The verdict hangs on the REFRESH token, not the access token. The access token
# lives ~12h and is reissued whenever claude starts, so it says nothing about
# health. The refresh token runs from the original interactive login and is not
# extended by use — measured across the fleet, four hosts refreshed in the same
# second still held four different refresh windows. When it lapses, only a fresh
# interactive login helps, and for claude that cannot be driven remotely.
claude_state_program() {
  cat <<'PY'
import json
import os
import sys
import time

try:
    warn = float(os.environ.get("HERDR_AUTH_WARN_HOURS") or 72)
except ValueError:
    warn = 72.0

def verdict():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return "missing"
    if not isinstance(data, dict):
        return "missing"
    oauth = data.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return "missing"
    if not oauth.get("refreshToken"):
        return "missing"
    expires = oauth.get("refreshTokenExpiresAt")
    if not isinstance(expires, (int, float)) or isinstance(expires, bool):
        return "missing"
    hours = (expires / 1000.0 - time.time()) / 3600.0
    if hours <= 0:
        return "missing"
    if hours < warn:
        return "expiring:%d" % int(hours)
    return "authed"

sys.stdout.write(verdict())
PY
}

# Run the classifier here, on stdin. Used by the tests, and by nothing else.
classify_creds() {
  local prog
  prog="$(claude_state_program)"
  HERDR_AUTH_WARN_HOURS="$CLAUDE_WARN_HOURS" python3 -c "$prog"
}

probe_claude() {
  local prog b64 out
  prog="$(claude_state_program)"
  # base64 so the program crosses ssh without any quoting to get wrong, and is
  # rebuilt into a VARIABLE on the far side — `python3 -c "$(...)"` would
  # brace-expand it there exactly as it did here. See references/herdr-auth.md.
  b64="$(printf '%s' "$prog" | base64 | tr -d '\n')"
  # The env var is checked FIRST because it wins. Verified on aorus8: a host
  # with a working stored credential answers `ok` normally and
  # `401 OAuth access token is invalid` with a bogus CLAUDE_CODE_OAUTH_TOKEN
  # set — so on a host carrying the fleet token, the credentials file is not
  # what authenticates and reporting on it would describe the wrong thing.
  #
  # Read in a `bash -lc` shell, the same login-but-non-interactive shape herdr
  # wires panes with, so this sees the token exactly when a pane would.
  out="$(remote "$1" "bash -lc 'if [ -n \"\${CLAUDE_CODE_OAUTH_TOKEN:-}\" ]; then printf token; else P=\$(echo $b64 | base64 -d); HERDR_AUTH_WARN_HOURS=$CLAUDE_WARN_HOURS; export HERDR_AUTH_WARN_HOURS; cat ~/.claude/.credentials.json 2>/dev/null | python3 -c \"\$P\"; fi'")"
  case "$out" in
    token)      echo token ;;
    authed)     echo authed ;;
    expiring:*) echo "$out" ;;
    *)          echo missing ;;
  esac
}

probe() {  # <cli> <host>
  case "$1" in
    cursor) probe_cursor "$2" ;;
    codex)  probe_codex  "$2" ;;
    claude) probe_claude "$2" ;;
    *) echo "unknown cli: $1" >&2; return 2 ;;
  esac
}

# An unreachable host must not read as merely logged-out: later phases drive
# login flows off these probes, and firing one at a dead host wastes a device
# code that expires.
host_reachable() {
  ssh $SSH_OPTS "$1" true >/dev/null 2>&1
}

# Pull the login URL out of captured CLI output. Last match wins: a retry
# prints a fresh URL below the stale one. Real pane output can carry ANSI
# color/cursor codes and can be embedded in prose ("...to this link: URL."),
# so both ANSI escapes and trailing punctuation are stripped before matching
# and before returning, or a mangled URL gets opened.
extract_url() {
  # The script is built via a heredoc (for readability) but run with `-c`,
  # not fed to python3's own stdin: python3 with no script argument treats
  # its stdin as the program to execute, which would swallow the piped pane
  # text instead of leaving it for sys.stdin.read() below.
  # Built into a variable, not inlined into `python3 -c "$(...)"`: that form
  # brace-expands the substituted text. Harmless here today because this regex
  # has no braces, and a trap for the next person to add one — see extract_code.
  local prog
  prog=$(cat <<'PY'
import re
import sys

# CSI ("\x1b[...m"), OSC ("\x1b]...BEL/ST"), and simple two-byte ("\x1b" + one
# byte in @-_) escape forms. Good enough for real terminal output; this is a
# scrubber, not a full ANSI parser.
ANSI_RE = re.compile(
    r"\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|\[[0-?]*[ -/]*[@-~]|[@-_])"
)
# Characters that cannot legally end a URL when it is really trailing prose
# punctuation or a stray escape remnant, not part of the URL itself.
TRAILING = ".,;:!?)]}'\">"

data = ANSI_RE.sub("", sys.stdin.read())
urls = re.findall(r"https://\S+", data)
if urls:
    sys.stdout.write(urls[-1].rstrip(TRAILING))
PY
)
  python3 -c "$prog"
}

# Strip credential-bearing parameter values. Everything this script prints
# goes through here — a login URL is a bearer credential for that login
# attempt, so only parameter NAMES may appear in output, never their values.
#
# ALLOWLIST, not denylist. Every key=value token is redacted except the few
# keys known to carry nothing secret. Three vendors own these URLs and can add
# a parameter without telling us — `state`, `verifier`, whatever comes next —
# and a denylist prints anything it has not heard of. This fails closed
# instead: unknown key, redacted value.
#
# This operates on ARBITRARY TEXT, not a guaranteed-clean URL — captured pane
# output, not just the URL substring — so a key=value token is recognized
# after `?`, `&`, `#`, OR at the start of a line/whitespace-delimited word.
# `#` matters because a fragment (everything after `#`) never reaches the
# server and many OAuth implicit/PKCE flows carry the token there; the old
# sed pipeline only ever matched after `?`/`&` and let fragment tokens through
# in the clear. A token with no leading separator at all (the very first
# key=value on a line) is also covered, which the old two-argument sed pass
# missed.
#
# Repeated key semantics: each occurrence is judged independently by its own
# key name against the allowlist, with no "remember what we already redacted"
# state. A repeated non-allowlisted key is redacted on every occurrence
# (fail-closed); a repeated allowlisted key is left alone on every occurrence,
# consistent with the allowlist's premise that a value paired with an
# allowlisted key is defined as non-secret regardless of how many times that
# key appears.
#
# C0 control bytes (other than tab/newline) are stripped before any pattern
# runs. The prior implementation protected allowlisted keys with a `\001`
# sentinel and rewrote it back to `=` in a final pass; raw pane text is not a
# clean URL and can itself contain a literal `\001`, which let a forged
# sentinel reconstruct a secret's `key=value` shape in the clear. This
# implementation never reintroduces a sentinel of any kind, so stripping
# control bytes up front is enough to close that off — there is nothing left
# for a forged control byte to collide with.
#
# RESIDUAL RISK, not fixed here: a secret embedded in the URL PATH itself
# (e.g. `/device/ABC-123-SECRET`) has no `key=value` shape and this cannot
# catch it — redacting arbitrary path segments would mangle every ordinary
# URL. The primary control for that case is the plan's rule that this script
# never prints a login URL at all; redact() is defence in depth for whatever
# text does get printed (retries, error output, etc.), not the only line of
# defence.
REDACT_KEEP='mode|redirectTarget|response_type|scope|prompt'
redact() {
  # See extract_url() above for why this is `-c "$(cat <<...)"` and not a
  # heredoc fed straight to python3's own stdin.
  REDACT_KEEP="$REDACT_KEEP" python3 -c "$(cat <<'PY'
import os
import re
import sys

KEEP = frozenset(os.environ["REDACT_KEEP"].split("|"))
# C0 control bytes except tab (0x09) and newline (0x0a).
CONTROL_RE = re.compile(r"[\x00-\x08\x0b-\x1f]")
TOKEN_RE = re.compile(r"(^|[\s?&#])([A-Za-z_][A-Za-z0-9_.-]*)=([^\s&#]*)")


def _redact_token(m):
    sep, key = m.group(1), m.group(2)
    if key in KEEP:
        return m.group(0)
    return sep + key + "=REDACTED"


data = CONTROL_RE.sub("", sys.stdin.read())
lines = [TOKEN_RE.sub(_redact_token, line) for line in data.split("\n")]
sys.stdout.write("\n".join(lines))
PY
)"
}

cmd_status() {
  local host cli state a=0 m=0 u=0 soon=""
  printf '%-10s %-10s %-10s %-10s\n' HOST CURSOR CODEX CLAUDE
  for host in $HOSTS_STR; do
    printf '%-10s' "$host"
    if host_reachable "$host"; then
      for cli in cursor codex claude; do
        state="$(probe "$cli" "$host")"
        case "$state" in
          # Still logged in, so it counts as authed — but it is the one state
          # that needs an action booked before it becomes `missing`, and a
          # count alone would hide that.
          expiring:*)
            printf ' %-10s' "exp ${state#expiring:}h"
            a=$((a + 1))
            soon="$soon $host/$cli(${state#expiring:}h)"
            ;;
          # Distinguished from `authed` on purpose: it says the host runs on the
          # fleet token rather than its own login, which is what you need to
          # know when one revoked token would take every `token` host down at
          # once. A bare "authed" would hide that shared fate.
          token)
            printf ' %-10s' token
            a=$((a + 1))
            ;;
          authed)
            printf ' %-10s' authed
            a=$((a + 1))
            ;;
          *)
            printf ' %-10s' "$state"
            m=$((m + 1))
            ;;
        esac
      done
    else
      for cli in cursor codex claude; do
        printf ' %-10s' unreachable
        u=$((u + 1))
      done
    fi
    printf '\n'
  done
  printf '\n%d authed, %d missing, %d unreachable\n' "$a" "$m" "$u"
  # Named, with hours, because "expiring" without a deadline is not actionable.
  [ -n "$soon" ] && printf 'expiring within %sh:%s\n' "$CLAUDE_WARN_HOURS" "$soon"
  return 0
}

open_url() {
  "${HERDR_AUTH_OPEN:-open}" "$1" >/dev/null 2>&1
}

# cursor prints its URL over a plain pipe and then polls Cursor's servers, so
# no PTY is needed and the URL completes the login opened from any machine.
# NO_OPEN_BROWSER stops the remote from trying to launch a browser it has not
# got. The remote process must be LEFT RUNNING: it polls Cursor's servers until
# the human half of the flow completes.
#
# That is exactly why the URL cannot be read with `out="$(remote ...)"`.
# Command substitution waits for the process to exit, and this one does not
# exit until the login lands — so the URL never arrives, no browser tab is
# opened, and the script waits forever for a login nobody can complete because
# the link was never handed over. It also blocks on host 1 and never reaches
# the rest of the fleet. (Found on the first live run; the stub used to model a
# command that returns, so 46 passing tests said nothing about it.)
#
# Start it detached with its output on the host, then read the URL out of that
# file while the process keeps running.
CURSOR_LOG="${HERDR_AUTH_CURSOR_LOG:-/tmp/herdr-auth-cursor-login.log}"

login_cursor() {
  local host="$1" url="" waited=0
  local ceiling="${HERDR_AUTH_URL_TIMEOUT:-20}"
  local interval="${HERDR_AUTH_URL_INTERVAL:-1}"

  remote "$host" "bash -lc 'rm -f $CURSOR_LOG; NO_OPEN_BROWSER=1 nohup cursor-agent login >$CURSOR_LOG 2>&1 &'" >/dev/null 2>&1

  # The URL appears a beat after the process starts, so poll the log rather
  # than reading once and concluding the flow produced nothing.
  while :; do
    url="$(remote "$host" "bash -lc 'cat $CURSOR_LOG 2>/dev/null'" | extract_url)"
    [ -n "$url" ] && break
    [ "$waited" -ge "$ceiling" ] && break
    sleep "$interval"
    waited=$((waited + 1))
  done
  printf '%s' "$url"
}

# Stop a login flow that never completed. Without this the detached process
# outlives the run and sits on the host polling forever — one had to be killed
# by hand after the first live attempt.
#
# Two things here are load-bearing and neither is obvious.
#
# The log is removed FIRST. It holds a live login URL, and cancelling is
# exactly when that must not be left behind; ordering it after the kill makes
# the cleanup contingent on the kill going well.
#
# The pattern must not match the command line carrying it. `pkill -f` matches
# full command lines, and the remote shell's own argv contains whatever pattern
# it was handed — so a literal "cursor-agent login" makes this signal itself.
# Verified on a live host:
#
#     $ pgrep -af "cursor-agent login"
#     931550 bash -lc pgrep -af "cursor-agent login"; ...
#
# `[ ]` encodes a space that the argv text does not literally contain: the
# regex needs a space between the words, and this command line has a bracket
# there, so it matches the real `cursor-agent login` and not itself.
cancel_login() {
  local host="$1"
  remote "$host" "bash -lc 'rm -f $CURSOR_LOG; pkill -f \"cursor-agent[ ]login\" >/dev/null 2>&1'" >/dev/null 2>&1 || true
}

# codex prints its device URL and one-time code to a plain pipe with no TTY —
# verified on aorus8 under nohup, which also disproves this file's original
# claim that codex "produces nothing without a controlling terminal". So it is
# driven exactly like cursor, with one inversion that changes the whole design:
# the value travels OUTWARD. The operator reads the code off this terminal and
# types it into the browser; nothing is ever delivered back into the pane, and
# the CLI polls until the human half completes.
#
# `--device-auth` is not a preference. Plain `codex login` calls back to
# localhost on the machine running codex, so a URL opened on your Mac hits the
# wrong localhost and the flow dies silently.
CODEX_LOG="${HERDR_AUTH_CODEX_LOG:-/tmp/herdr-auth-codex-login.log}"
# Static, carries no per-run secret — unlike cursor's URL, this one is safe to
# print. The secret in this flow is the code, not the link.
CODEX_DEVICE_URL="https://auth.openai.com/codex/device"

# Pull the one-time device code out of captured CLI output. Anchored on the
# code's own shape rather than on the prose around it: "Enter this one-time
# code" is vendor copy that can be reworded, while the code's form is part of
# the protocol. Last match wins, for the same reason as extract_url — a retry
# prints a fresh code below the stale one.
#
# The program is built into a VARIABLE first, then passed as "$prog". Inlining
# it as `python3 -c "$(cat <<'PY' ... PY)"` — the form extract_url uses — leaks
# brace expansion onto the substituted text: `{4,8}` becomes the cross product
# `4 8`, python takes the first variant as the program and the rest as argv,
# and the quantifier silently degrades to a single digit:
#
#     PATTERN: '\b[A-Z0-9]4-[A-Z0-9]4\b'     # not what was written
#
# extract_url never exposed this because its regex contains no braces. A
# variable assignment undergoes no brace expansion, so this form is safe for
# any program text.
extract_code() {
  local prog
  prog=$(cat <<'PY'
import re
import sys

ANSI_RE = re.compile(
    r"\x1b(?:\][^\x07\x1b]*(?:\x07|\x1b\\)|\[[0-?]*[ -/]*[@-~]|[@-_])"
)
data = ANSI_RE.sub("", sys.stdin.read())
codes = re.findall(r"\b[A-Z0-9]{4,8}-[A-Z0-9]{4,8}\b", data)
if codes:
    sys.stdout.write(codes[-1])
PY
)
  python3 -c "$prog"
}

# Same detached-then-poll shape as login_cursor, and for the same reason: the
# process does not exit until the login lands, so command substitution would
# wait forever and never hand back the code.
login_codex() {
  local host="$1" code="" waited=0
  local ceiling="${HERDR_AUTH_URL_TIMEOUT:-20}"
  local interval="${HERDR_AUTH_URL_INTERVAL:-1}"

  remote "$host" "bash -lc 'rm -f $CODEX_LOG; nohup codex login --device-auth >$CODEX_LOG 2>&1 &'" >/dev/null 2>&1

  while :; do
    code="$(remote "$host" "bash -lc 'cat $CODEX_LOG 2>/dev/null'" | extract_code)"
    [ -n "$code" ] && break
    [ "$waited" -ge "$ceiling" ] && break
    sleep "$interval"
    waited=$((waited + 1))
  done
  printf '%s' "$code"
}

# The log holds the device code and lands world-readable — observed at mode 644,
# group ticket-demo, on aorus8. It must not outlive the flow on ANY path.
# Cleanup used to exist only in the cancel path, so a login that SUCCEEDED left
# the file behind: the failure case was tidy and the happy case leaked, which is
# the wrong way round. A real fleet run left one on five hosts.
clear_codex_log() {
  remote "$1" "bash -lc 'rm -f $CODEX_LOG'" >/dev/null 2>&1 || true
}

# Log removed first, and a pattern that cannot match this command line — see
# cancel_login above for why both matter.
cancel_codex_login() {
  local host="$1"
  remote "$host" "bash -lc 'rm -f $CODEX_LOG; pkill -f \"codex[ ]login\" >/dev/null 2>&1'" >/dev/null 2>&1 || true
}

# Poll until the CLI reports itself logged in, or give up at the ceiling.
# Always returns — a stalled login must not block the remaining hosts.
wait_for_login() {
  local cli="$1" host="$2"
  local interval="${HERDR_AUTH_POLL_INTERVAL:-5}"
  local ceiling="${HERDR_AUTH_POLL_CEILING:-$POLL_CEILING_DEFAULT}"
  local waited=0 step
  # step is at least 1 even when interval is 0 (tests use interval=0 to avoid
  # real sleeping), so the loop always makes progress toward ceiling through
  # the SAME arithmetic production uses — no separate "interval=0" shortcut
  # that could mask a regression in the real increment/comparison.
  while [ "$waited" -lt "$ceiling" ]; do
    if [ "$(probe "$cli" "$host")" = authed ]; then echo ok; return 0; fi
    sleep "$interval"
    step="$interval"
    [ "$step" -ge 1 ] || step=1
    waited=$((waited + step))
  done
  [ "$(probe "$cli" "$host")" = authed ] && { echo ok; return 0; }
  echo timeout
  return 1
}

cmd_login() {
  local cli="$1" host url code opened=0
  # Space-separated accumulator, not an array — bash 3.2 has no arrays.
  # Only hosts a flow actually started for belong here: a host skipped as
  # unreachable, or one that produced no login URL, never got a login
  # attempt running, so it must not sit in the wait phase burning a full
  # poll ceiling waiting for something that was never started.
  local waiting=""
  case "$cli" in
    cursor)
      for host in $HOSTS_STR; do
        if ! host_reachable "$host"; then
          echo "  host $host: unreachable, skipping — a login fired at a dead host wastes a device code"
          continue
        fi
        url="$(login_cursor "$host")"
        if [ -z "$url" ]; then
          echo "  host $host: no login URL — flow did not start"
          continue
        fi
        open_url "$url"
        opened=$((opened + 1))
        waiting="$waiting $host"
        echo "  opened login URL for host $host"
      done
      echo "$opened URL(s) opened. Complete them in the browser."
      if [ "${HERDR_AUTH_NO_WAIT:-0}" != 0 ]; then
        :
      elif [ -z "$waiting" ]; then
        echo "  no hosts to wait on — no login flow was started"
      else
        for host in $waiting; do
          case "$(wait_for_login "$cli" "$host")" in
            ok) echo "  host $host: logged in" ;;
            *)  echo "  host $host: still not logged in after ${HERDR_AUTH_POLL_CEILING:-$POLL_CEILING_DEFAULT}s — cancelling the flow" >&2
                cancel_login "$host" ;;
          esac
        done
      fi
      ;;
    codex)
      # Serial, one host at a time — the opposite of cursor's single pass, and
      # deliberately so. The operator enters codes one at a time at a single
      # page, and each lives 15 minutes; starting six at once means the last is
      # most of the way through its TTL before anyone reaches it.
      #
      # The probe-and-skip is what makes a re-run cheap: an already-authed host
      # costs one probe instead of a code the operator has to type.
      for host in $HOSTS_STR; do
        if ! host_reachable "$host"; then
          echo "  host $host: unreachable, skipping — a login fired at a dead host wastes a device code"
          continue
        fi
        if [ "$(probe codex "$host")" = authed ]; then
          echo "  host $host: already logged in, skipping"
          continue
        fi
        code="$(login_codex "$host")"
        if [ -z "$code" ]; then
          echo "  host $host: no device code — flow did not start"
          cancel_codex_login "$host"
          continue
        fi
        open_url "$CODEX_DEVICE_URL"
        # Printed on purpose. This is the one credential the script must put in
        # front of the operator — the flow cannot complete otherwise — and it
        # is the reason redact() does not govern this branch. It reaches the
        # terminal and nothing else: never a file, never a log, never argv.
        printf '  host %s: enter code %s at %s\n' "$host" "$code" "$CODEX_DEVICE_URL"
        opened=$((opened + 1))
        [ "$HERDR_AUTH_NO_WAIT" != 0 ] && continue
        # Waiting here, inside the loop, IS the serialisation. Moving this to a
        # second pass would mint every code up front and reintroduce the TTL
        # problem this ordering exists to avoid.
        case "$(wait_for_login codex "$host")" in
          # Success cleans up too. The log holds the device code, and a flow that
          # worked has no more use for it than one that failed.
          ok) echo "  host $host: logged in"
              clear_codex_log "$host" ;;
          *)  echo "  host $host: still not logged in after ${HERDR_AUTH_POLL_CEILING:-$POLL_CEILING_DEFAULT}s — cancelling the flow" >&2
              cancel_codex_login "$host" ;;
        esac
      done
      echo "$opened device code(s) issued."
      ;;
    *)
      echo "unknown or unimplemented cli: $cli" >&2; exit 2 ;;
  esac
}

main() {
  local verb="${1:-status}"; shift 2>/dev/null || true
  case "$verb" in
    status) cmd_status ;;
    login)
      local cli=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --cli)  cli="$2"; shift 2 ;;
          --host) HOSTS_STR="$2"; shift 2 ;;
          --no-wait) HERDR_AUTH_NO_WAIT=1; shift ;;
          *) echo "unknown flag: $1" >&2; exit 2 ;;
        esac
      done
      [ -n "$cli" ] || { echo "login needs --cli cursor|codex|claude" >&2; exit 2; }
      cmd_login "$cli"
      ;;
    _probe) probe "$@" ;;
    _wait) wait_for_login "$@" ;;
    _extract_url) extract_url ;;
    _extract_code) extract_code ;;
    _classify_creds) classify_creds ;;
    _redact) redact ;;
    *) echo "usage: herdr-auth.sh status | login --cli <cli> [--host H]" >&2; exit 2 ;;
  esac
}

main "$@"
