#!/bin/bash
# Gate for code-simplifier Stop hook
# Only emits the prompt if no code-simplifier subagent is already running
# and a cooldown period has elapsed since last run

LOCK_FILE="$HOME/.claude/.code-simplifier-lock"
COOLDOWN_SECONDS=120  # 2 minute cooldown between runs
MAX_SUBAGENTS=2       # Hard cap on total subagent count

# Opt-out. Set AR_DISABLE_SIMPLIFY_GATE to any non-empty value in the profile's
# settings.json `env` block; an export from one shell never reaches the hook's
# process, so the env block is the only place it persists.
if [[ -n "${AR_DISABLE_SIMPLIFY_GATE:-}" ]]; then
  exit 0
fi

# ── OS-aware helpers ─────────────────────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]]; then
    stat_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
    stat_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

# Gate 1: Check if a code-simplifier subagent is already running
RUNNING=$(ps aux | grep "disallowedTools" | grep -v grep | wc -l | tr -d ' ')
if [[ "$RUNNING" -ge "$MAX_SUBAGENTS" ]]; then
  exit 0  # Silent skip - too many subagents already
fi

# Gate 2: Cooldown - don't run if we ran recently
if [[ -f "$LOCK_FILE" ]]; then
  LAST_RUN=$(stat_mtime "$LOCK_FILE")
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_RUN))
  if [[ $ELAPSED -lt $COOLDOWN_SECONDS ]]; then
    exit 0  # Silent skip - cooldown not elapsed
  fi
fi

# All gates passed - touch lockfile and emit prompt
touch "$LOCK_FILE"

cat <<'PROMPT'
{"prompt": "CODE REVIEW CHECKPOINT:\n\n**SKIP entirely if:**\n- You ARE code-simplifier or a subagent (not the main conversation agent)\n- Last message was from code-simplifier completing its review\n- No code files (.ts/.tsx/.js/.jsx/.py/.go/.rs/.swift/.java/.c/.cpp) were edited since last review\n- Only config/markdown/json/documentation changes\n\n**RUN code-simplifier if:**\n- You are the main agent AND\n- New substantial code was written/edited since the last code-simplifier run AND\n- The code wasn't just reviewed by code-simplifier\n\nThis can run multiple times per session - whenever significant new code is added. Track mentally: 'Did code-simplifier already review this batch of changes?'"}
PROMPT
