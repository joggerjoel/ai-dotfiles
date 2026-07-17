#!/usr/bin/env bash
# rtk-rewrite.sh — non-blocking per-project logger for Bash PreToolUse events.
#
# Scope: logging ONLY. It records each Bash tool call to a per-project JSONL file
# and ALWAYS exits 0 (never blocks or rewrites a command). The security guards
# (.env privacy-block, /tmp scout-block, dangerous-cmd-block) are provided
# independently by the autoresearch plugin's own registered hooks — this script
# does NOT duplicate them.
#
# Log path: ~/.claude/hooks/.logs/<basename>-<first8 md5(project-abspath)>/hook-log.jsonl
# Slug matches the original scheme so entries append to existing files.

set +e  # never fail the hook

# jq is required to parse/emit JSON safely; if absent, log nothing and pass through.
command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat 2>/dev/null)"
[ -z "$INPUT" ] && exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)"
CMD="$(printf '%s'  "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
CWD="$(printf '%s'  "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$CWD" ] && CWD="$PWD"

# Project root + branch (best-effort; empty if not a git repo).
ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)"
[ -z "$ROOT" ] && ROOT="$CWD"
BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null)"

# first 8 hex of md5(project abspath) — cross-platform (md5 on macOS, md5sum on Linux).
if command -v md5 >/dev/null 2>&1; then
  HASH="$(printf '%s' "$ROOT" | md5 | cut -c1-8)"
elif command -v md5sum >/dev/null 2>&1; then
  HASH="$(printf '%s' "$ROOT" | md5sum | cut -c1-8)"
else
  HASH="nohash"
fi

SLUG="$(basename "$ROOT")-$HASH"
LOGDIR="$HOME/.claude/hooks/.logs/$SLUG"
mkdir -p "$LOGDIR" 2>/dev/null || exit 0

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"

jq -cn \
  --arg ts "$TS" --arg tool "${TOOL:-Bash}" --arg cwd "$CWD" \
  --arg root "$ROOT" --arg branch "$BRANCH" --arg cmd "$CMD" \
  '{ts:$ts, hook:"bash-log", tool:$tool, cwd:$cwd, projectRoot:$root, gitBranch:$branch, command:$cmd}' \
  >> "$LOGDIR/hook-log.jsonl" 2>/dev/null

exit 0
