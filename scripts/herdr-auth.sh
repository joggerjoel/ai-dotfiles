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

probe_codex() {
  local out; out="$(remote "$1" 'bash -lc "codex login status"')"
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

cmd_status() {
  local host cli state a=0 m=0
  printf '%-10s %-10s %-10s %-10s\n' HOST CURSOR CODEX CLAUDE
  for host in $HOSTS_STR; do
    printf '%-10s' "$host"
    for cli in cursor codex claude; do
      state="$(probe "$cli" "$host")"
      printf ' %-10s' "$state"
      if [ "$state" = authed ]; then a=$((a + 1)); else m=$((m + 1)); fi
    done
    printf '\n'
  done
  printf '\n%d authed, %d missing\n' "$a" "$m"
}

main() {
  case "${1:-status}" in
    status) cmd_status ;;
    _probe) shift; probe "$@" ;;   # test seam
    *) echo "usage: herdr-auth.sh status" >&2; exit 2 ;;
  esac
}

main "$@"
