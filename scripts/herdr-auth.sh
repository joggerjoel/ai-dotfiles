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

probe_claude() {
  local out
  out="$(remote "$1" '[ -f ~/.claude/.credentials.json ] && echo authed || echo missing')"
  case "$out" in
    *authed*) echo authed ;;
    *) echo missing ;;
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
  python3 -c "$(cat <<'PY'
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
)"
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
  local host cli state a=0 m=0 u=0
  printf '%-10s %-10s %-10s %-10s\n' HOST CURSOR CODEX CLAUDE
  for host in $HOSTS_STR; do
    printf '%-10s' "$host"
    if host_reachable "$host"; then
      for cli in cursor codex claude; do
        state="$(probe "$cli" "$host")"
        printf ' %-10s' "$state"
        if [ "$state" = authed ]; then a=$((a + 1)); else m=$((m + 1)); fi
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
}

main() {
  case "${1:-status}" in
    status) cmd_status ;;
    _probe) shift; probe "$@" ;;          # test seam
    _extract_url) extract_url ;;          # test seam
    _redact) redact ;;                    # test seam
    *) echo "usage: herdr-auth.sh status" >&2; exit 2 ;;
  esac
}

main "$@"
