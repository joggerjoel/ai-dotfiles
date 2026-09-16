#!/usr/bin/env bash
# herdr-inbox-notice.sh — tell a starting agent it has coordination mail.
#
# Several parties change one repository at once: interactive Claude Code sessions, a
# Cursor agent running as a worker inside a Herdr pane, and Orca terminals. Session-to-
# session messaging reaches only sessions, so a worker in a pane cannot be addressed at
# all. What every party shares is a filesystem and the ability to run a command, so the
# inbox is a file and this hook is how an agent notices it has mail.
#
# On SessionStart only, it resolves the repository from the payload's cwd, asks
#
#   herdr-master inbox --repo <repo> --all
#
# for unread messages, and prints them to stdout. Stdout is the entire mechanism: a
# SessionStart hook's output lands in the starting agent's context, which is the one
# place a hook may legitimately write. This is a sibling of herdr-transcript-spool.sh
# rather than an extension of it, so that hook's "never prints to stdout" contract
# stays simple and intact.
#
# Three rules shape the output:
#   * Silent when there is no mail. A hook that speaks on every start teaches people to
#     ignore it.
#   * Capped hard. Filling an agent's context with a backlog is worse than saying
#     nothing, so a few short lines and a pointer to the command for the rest.
#   * Never acknowledges anything. Reading is not acting, and a hook that marked mail
#     read would lose messages for whoever actually needed them. No flag here writes.
#
# Fail-open contract: no jq, no herdr-master, no repository, a nonzero exit, a timeout
# or malformed input all print nothing and exit 0.
#
# The binary comes from PATH or HERDR_MASTER_BIN, never from the repository being
# opened: executing something found in whatever directory a session happens to start
# in would make this hook an arbitrary-code path.
#
# Test seams (all optional): HERDR_MASTER_BIN, HERDR_MASTER_ROOT,
# HERDR_INBOX_TIMEOUT, HERDR_INBOX_MAX.

MAX_MESSAGES="${HERDR_INBOX_MAX:-5}"
LINE_WIDTH=200
TIMEOUT_S="${HERDR_INBOX_TIMEOUT:-3}"

command -v jq > /dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ "$EVENT" = SessionStart ] || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CWD" ] || exit 0
RESOLVED=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0

find_repo() { # resolved directory → the nearest ancestor holding .git
  local dir="$1" depth=0
  while [ "$depth" -lt 12 ]; do
    # A worktree records .git as a file, not a directory.
    if [ -e "$dir/.git" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    [ "$dir" = "/" ] && return 1
    dir=$(dirname "$dir")
    depth=$((depth + 1))
  done
  return 1
}

REPO=$(find_repo "$RESOLVED") || exit 0

BIN="${HERDR_MASTER_BIN:-herdr-master}"
command -v "$BIN" > /dev/null 2>&1 || exit 0

bounded() {
  if command -v timeout > /dev/null 2>&1; then
    timeout "$TIMEOUT_S" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then
    gtimeout "$TIMEOUT_S" "$@"
  else
    "$@"
  fi
}

# `--all` is every message for every audience, read or not, and each carries a `read`
# flag. Asking for everything and keeping the unread is how one reader with no audience
# of its own sees what is outstanding for anybody. `--ack` is the only flag that writes
# and is never passed here, so reading leaves the inbox exactly as it was.
# HERDR_MASTER_ROOT names the supervisor state, exactly as the spool hook reads it.
# Unset means the CLI's own default, which is the right answer in production.
ROOT_ARGS=()
[ -n "${HERDR_MASTER_ROOT:-}" ] && ROOT_ARGS=(--root "$HERDR_MASTER_ROOT")
RAW=$(bounded "$BIN" "${ROOT_ARGS[@]}" inbox --repo "$REPO" --all --json 2>/dev/null) \
  || exit 0
[ -n "$RAW" ] || exit 0

TOTAL=$(printf '%s' "$RAW" | jq '[.messages[]? | select(.read != true)] | length' 2>/dev/null)
case "$TOTAL" in '' | 0 | *[!0-9]*) exit 0 ;; esac

printf 'herdr inbox: %s unread message(s) for this repository.\n' "$TOTAL"
printf '%s' "$RAW" | jq -r --argjson n "$MAX_MESSAGES" '
  [.messages[]? | select(.read != true)][:$n][]
  | "  \(.at // "") \(.from // "someone") -> \(.to // "all"): \(.subject // "")"' \
  2>/dev/null | cut -c "1-$LINE_WIDTH"
if [ "$TOTAL" -gt "$MAX_MESSAGES" ]; then
  printf 'and %s more; run: herdr-master inbox --repo %s --all\n' \
    "$((TOTAL - MAX_MESSAGES))" "$REPO"
fi
printf 'Nothing was marked read. Use herdr-master inbox --ack <id> to acknowledge.\n'

exit 0
