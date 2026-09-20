#!/usr/bin/env bash
# agenttrail-hook.sh — guarded wrapper around agenttrail's Claude Code hook.
#
# Registered on PreToolUse(*), PostToolUse(*), Stop, SessionStart and
# SubagentStop in profiles/*/settings.json. agenttrail itself lives in a
# 3rdparty checkout installed separately (`just observability-tools install`),
# NOT in this repo — so on any machine where that checkout is absent, invoking
# it directly makes node throw MODULE_NOT_FOUND on every single tool call.
# That is exactly what happened before this wrapper existed: five unguarded
# `node .../agenttrail.mjs hook` entries, a missing ~/Developer/3rdparty, and a
# stack trace on every Bash call that nobody noticed because hook failures are
# non-blocking.
#
# Contract:
#   - Never block a tool call because agenttrail is missing.
#   - Never emit a node stack trace for the missing-checkout case.
#   - When agenttrail IS installed, get out of the way: exec it, so its stdout
#     (the hook response JSON) and its exit code pass through untouched.

set +e

# Overridable so the test harness can point at a fixture instead of $HOME.
AGENTTRAIL_BIN="${AGENTTRAIL_BIN:-$HOME/Developer/3rdparty/agenttrail/bin/agenttrail.mjs}"

# Where the once-a-day breadcrumb records that it has already fired. Lives
# beside the other hook logs rather than in the repo, so a checkout is not
# needed to suppress a warning about a missing checkout.
STAMP="${AGENTTRAIL_STAMP:-$HOME/.claude/hooks/.logs/agenttrail-missing.stamp}"

# handle_missing_checkout — agenttrail is not installed on this machine.
#
# Claude Code has already written the hook event JSON to our stdin and is
# waiting on us, so drain it before exiting: leaving it unread can hand the
# writer an EPIPE. Then answer `{}`, the no-op hook response, so the caller
# parses a valid result instead of empty output.
#
# The breadcrumb is deliberate. Total silence would fix the stack traces and
# recreate the blind spot that produced them: five hooks were dead on every
# single tool call for as long as the checkout was missing, and the ONLY
# reason it surfaced was node printing a trace. Once a day is cheap; once per
# tool call is the noise this wrapper exists to delete.
handle_missing_checkout() {
  { command -p cat 2>/dev/null || cat; } >/dev/null 2>&1 || :
  printf '{}\n'

  mkdir -p "$(dirname "$STAMP")" 2>/dev/null || return 0
  # `find -mtime -1` prints nothing when the stamp is absent OR older than a
  # day — both cases should warn — and prints the path when it is recent,
  # which suppresses. Never let a failure here break the hook.
  if [ -z "$(find "$STAMP" -mtime -1 2>/dev/null)" ]; then
    : > "$STAMP" 2>/dev/null || return 0
    printf 'agenttrail not installed (%s) — run: just observability-tools install\n' \
      "${AGENTTRAIL_BIN#"$HOME"/}" >&2
  fi
  return 0
}

command -v node >/dev/null 2>&1 || { handle_missing_checkout; exit 0; }
[ -f "$AGENTTRAIL_BIN" ]        || { handle_missing_checkout; exit 0; }

exec node "$AGENTTRAIL_BIN" hook
