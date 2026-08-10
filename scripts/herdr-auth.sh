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
# prints a fresh URL below the stale one.
extract_url() {
  grep -oE 'https://[^[:space:]]+' | tail -1
}

# Strip credential-bearing query parameter values. Everything this script
# prints goes through here — the URL itself is a bearer credential for the
# login attempt, so only the parameter names may appear in output.
#
# ALLOWLIST, not denylist. Every parameter value is redacted except the few
# known to carry nothing secret. Three vendors own these URLs and can add a
# parameter without telling us — `state`, `verifier`, whatever comes next — and
# a denylist prints anything it has not heard of. This fails closed instead.
#
# Implemented in three passes because sed has no negative lookahead: protect the
# allowlisted separators with a control character, redact everything still
# holding an `=`, then restore. \001 cannot occur in a URL, so it is safe.
REDACT_KEEP='mode|redirectTarget|response_type|scope|prompt'
redact() {
  local sep; sep=$(printf '\001')
  sed -E "s/([?&])($REDACT_KEEP)=/\1\2${sep}/g" \
    | sed -E 's/([?&])([A-Za-z_][A-Za-z0-9_.-]*)=[^&[:space:]]*/\1\2=REDACTED/g' \
    | sed -E "s/${sep}/=/g"
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
