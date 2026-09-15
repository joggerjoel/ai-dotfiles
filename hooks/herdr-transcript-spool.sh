#!/usr/bin/env bash
# herdr-transcript-spool.sh — join Claude Code sessions to herdr supervisor attempts.
#
# Registered for any hook event that carries a transcript (SessionStart, Stop,
# SubagentStop, …). It appends ONE compact JSON line per event to
#
#   ${HERDR_MASTER_ROOT:-$HOME/.herdr-master}/transcript-spool.jsonl
#
# holding only: recorded_at, hook_event_name, session_id, transcript_path, cwd
# and agent_transcript_path. No prompt text, no transcript contents, no secrets.
# herdr reads the spool and matches a session to a work-unit attempt by working
# directory and time window, so it can tell which files a later attempt rewrote
# after an earlier attempt failed verification.
#
# On SessionStart and Stop it additionally binds this session to a herdr workflow
# role in a running agenttrail Kitchen. herdr drops a role marker at
#
#   ${HERDR_MASTER_ROOT:-$HOME/.herdr-master}/role-markers/<sha256 of resolved cwd>.json
#
# when it dispatches a worker into a worktree. If that marker and a Kitchen
# registration both exist, the hook POSTs a session-start and then a role event on
# SessionStart, and re-posts the role event on Stop, so the Kitchen labels the chef
# from herdr's own role instead of guessing from file paths.
#
# With no marker, SessionStart falls back to a default station: the nearest ancestor
# .office/kitchen.json is read, and if it declares workflow id "herdr" and a role named
# ${HERDR_DEFAULT_KITCHEN_ROLE:-supervisor} the session binds to that role. Without it
# the Kitchen renders every unbound session as a chef of its own.
#
# THE RULE, which explains all three branches at once: we open, label, end turns for,
# and close exactly the sessions we bind, and we touch nothing else. A session we could
# not label is left entirely alone, because creating a board entry for it would make it
# its own chef, which is the crowding the binding exists to prevent. Log discovery
# creates those entries moments later anyway.
#
# Lifecycle events posted, matching the Kitchen's own hook adapter
# (packages/kitchen/src/connectors/events.mjs):
#
#   SessionStart -> session-start, then the role binding
#   Stop         -> the role re-post, then turn-end
#   SessionEnd   -> session-end
#
# Stop is a TURN boundary, not a session boundary. It fires after every turn of an
# interactive session, so posting session-end there would mark a live agent offline
# and nothing would revive it. Without the turn-end a session we opened would sit at
# state "working" until the Kitchen's 24-hour TTL evicted it.
#
# Fail-open contract: malformed JSON, a missing jq, curl or sha256 tool, missing
# keys, an unwritable spool directory, an absent marker, an absent or unreachable
# Kitchen all exit 0. The hook NEVER prints to stdout — SessionStart and
# UserPromptSubmit stdout is injected into the agent's context, and this hook has
# nothing to say to the model.
#
# Test seams (all optional): HERDR_MASTER_ROOT, HERDR_SPOOL_NOW (frozen
# timestamp, used verbatim as recorded_at), KITCHEN_STATE_DIR.

exec 1> /dev/null

command -v jq > /dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

RECORDED_AT="${HERDR_SPOOL_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
[ -n "$RECORDED_AT" ] || exit 0
# Epoch seconds in production; the same seam as recorded_at so a test can pin it.
TURN_STAMP="${HERDR_SPOOL_NOW:-$(date -u +%s)}"

LINE=$(printf '%s' "$INPUT" | jq -c --arg now "$RECORDED_AT" '
  if (.hook_event_name | type) == "string" and (.hook_event_name | length) > 0
     and (.session_id | type) == "string" and (.session_id | length) > 0
     and (.transcript_path | type) == "string" and (.transcript_path | length) > 0
     and (.cwd | type) == "string" and (.cwd | length) > 0
  then
    {recorded_at: $now, hook_event_name, session_id, transcript_path, cwd,
     agent_transcript_path:
       (if (.agent_transcript_path | type) == "string" and (.agent_transcript_path | length) > 0
        then .agent_transcript_path else null end)}
  else empty end' 2>/dev/null) || exit 0
[ -n "$LINE" ] || exit 0

SPOOL_DIR="${HERDR_MASTER_ROOT:-$HOME/.herdr-master}"
mkdir -p "$SPOOL_DIR" 2>/dev/null || exit 0
printf '%s\n' "$LINE" >> "$SPOOL_DIR/transcript-spool.jsonl" 2>/dev/null || exit 0

# ── Kitchen role binding (SessionStart only) ────────────────────────────────
sha256_hex() {
  if command -v shasum > /dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | cut -d' ' -f1
  else
    return 1
  fi
}

EVENT=$(printf '%s' "$LINE" | jq -r '.hook_event_name')
case "$EVENT" in SessionStart | Stop | SessionEnd) ;; *) exit 0 ;; esac
command -v curl > /dev/null 2>&1 || exit 0

CWD=$(printf '%s' "$LINE" | jq -r '.cwd')
SESSION=$(printf '%s' "$LINE" | jq -r '.session_id')
# Both sides hash the fully resolved directory, or a worktree reached through a symlink
# would never match the path the supervisor recorded for the same directory.
RESOLVED=$(cd "$CWD" 2>/dev/null && pwd -P) || exit 0
[ -n "$RESOLVED" ] || exit 0
DIGEST=$(sha256_hex "$RESOLVED") || exit 0
[ -n "$DIGEST" ] || exit 0

MARKER="$SPOOL_DIR/role-markers/$DIGEST.json"
REGISTRATION="${KITCHEN_STATE_DIR:-$HOME/.agent-office}/server.json"
[ -f "$REGISTRATION" ] || exit 0

find_crew() { # resolved directory → nearest ancestor's .office/kitchen.json
  local dir="$1" depth=0
  while [ "$depth" -lt 12 ]; do
    if [ -f "$dir/.office/kitchen.json" ]; then
      printf '%s\n' "$dir/.office/kitchen.json"
      return 0
    fi
    [ "$dir" = "/" ] && return 1
    dir=$(dirname "$dir")
    depth=$((depth + 1))
  done
  return 1
}

# Resolved for every handled event, not just SessionStart: the answer is the predicate
# "would we bind this session", and every branch below is gated on it.
ROLE_ID=""
ROLE_WORKFLOW=""
if [ -f "$MARKER" ]; then
  ROLE_ID=$(jq -r '.role // empty' "$MARKER" 2>/dev/null)
  ROLE_WORKFLOW=$(jq -r '.workflow_id // empty' "$MARKER" 2>/dev/null)
elif CREW=$(find_crew "$RESOLVED"); then
  # Without a marker herdr has no specific role for this session. Binding it to one
  # default station beats letting the Kitchen render it as a chef of its own.
  CREW_WORKFLOW=$(jq -r '.workflow.id // empty' "$CREW" 2>/dev/null)
  CREW_ROLE="${HERDR_DEFAULT_KITCHEN_ROLE:-supervisor}"
  # roleForSession returns null outright when a binding names a different workflow, so
  # binding into a repo with an inferred crew would hide the session, not surface it.
  if [ "$CREW_WORKFLOW" = "herdr" ] \
    && jq -e --arg r "$CREW_ROLE" 'any(.workflow.roles[]?; .id == $r)' "$CREW" > /dev/null 2>&1; then
    ROLE_ID="$CREW_ROLE"
    ROLE_WORKFLOW="$CREW_WORKFLOW"
  fi
fi

PORT=$(jq -r 'if (.port | type) == "number" then .port else empty end' "$REGISTRATION" 2>/dev/null)
TOKEN=$(jq -r '.hookToken // empty' "$REGISTRATION" 2>/dev/null)
[ -n "$PORT" ] && [ -n "$TOKEN" ] || exit 0

# The token goes in a 0600 config file, never on the command line, where every other
# user on the machine could read it out of the process table.
CONFIG=$(mktemp "${TMPDIR:-/tmp}/herdr-kitchen.XXXXXX" 2>/dev/null) || exit 0
chmod 600 "$CONFIG" 2>/dev/null
trap 'rm -f "$CONFIG"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CONFIG" 2>/dev/null || exit 0

kitchen_post() { # compact JSON body
  curl --config "$CONFIG" --silent --show-error --output /dev/null --max-time 0.4 \
    --request POST --header "Content-Type: application/json" --data "$1" \
    "http://127.0.0.1:$PORT/api/hook" > /dev/null 2>&1
}

role_body() { # event id
  jq -cn --arg s "$SESSION" --arg c "$CWD" --arg i "$1" \
    --arg r "$ROLE_ID" --arg w "$ROLE_WORKFLOW" '
    {provider: "claude", sessionId: $s, cwd: $c, id: $i, kind: "role",
     roleId: $r, workflowId: (if ($w | length) > 0 then $w else null end)}' 2>/dev/null
}

lifecycle_body() { # kind event-id
  jq -cn --arg s "$SESSION" --arg c "$CWD" --arg k "$1" --arg i "$2" \
    '{provider: "claude", sessionId: $s, cwd: $c, id: $i, kind: $k}' 2>/dev/null
}

case "$EVENT" in
  SessionStart)
    # Only opened when there is a role to bind. Creating a session we cannot label
    # would put an unbound chef on the board, which is what the binding exists to stop.
    if [ -n "$ROLE_ID" ]; then
      # The Kitchen drops a role event for a session it has not seen, and it discovers
      # Claude sessions by tailing logs, which races this hook. Opening the session
      # here first makes the binding that follows unconditional.
      START=$(lifecycle_body session-start "herdr-session:$SESSION")
      [ -n "$START" ] && kitchen_post "$START"
      BODY=$(role_body "herdr-role:$SESSION")
      [ -n "$BODY" ] && kitchen_post "$BODY"
    fi
    ;;
  Stop)
    [ -n "$ROLE_ID" ] || exit 0
    # Belt and braces for a session the Kitchen had already created from its logs
    # before this hook ever ran. A distinct id keeps it from deduplicating against
    # the first.
    BODY=$(role_body "herdr-role:$SESSION:stop")
    [ -n "$BODY" ] && kitchen_post "$BODY"
    # A turn boundary, never a session boundary: Stop fires after every turn of an
    # interactive session, and ending the session here would mark a live agent offline
    # with nothing left to revive it. The id must be fresh because the Kitchen
    # deduplicates on (project, provider, id) and one session ends many turns.
    TURN=$(lifecycle_body turn-end "herdr-turn-end:$SESSION:$TURN_STAMP")
    [ -n "$TURN" ] && kitchen_post "$TURN"
    ;;
  SessionEnd)
    [ -n "$ROLE_ID" ] || exit 0
    ENDED=$(lifecycle_body session-end "herdr-session-end:$SESSION")
    [ -n "$ENDED" ] && kitchen_post "$ENDED"
    ;;
esac

exit 0
