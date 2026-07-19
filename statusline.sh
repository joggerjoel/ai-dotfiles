#!/bin/bash
# Multi-line status line for Claude Code
# Line 1: Model | Directory | Git branch + status | Output style | Headroom
# Line 2: Context bar (color-coded) | Cost | Duration | Lines changed

input=$(cat)

# ── Extract fields ──────────────────────────────────────────────
MODEL=$(echo "$input" | jq -r '.model.display_name')
HOST=$(hostname)
DIR=$(echo "$input" | jq -r '.workspace.current_dir')
SESSION_NAME=$(echo "$input" | jq -r '.session_name // empty')
SESSION_ID=$(echo "$input" | jq -r '.session_id')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
STYLE=$(echo "$input" | jq -r '.output_style.name // "default"')
LINES_ADDED=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
LINES_REMOVED=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
VIM_MODE=$(echo "$input" | jq -r '.vim.mode // empty')

# ── Colors ──────────────────────────────────────────────────────
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'
# Hard reset: clears SGR + explicitly resets fg (39) and bg (49) to default.
# Defensive against the v2.1.139 TUI leaving a stray bg color active when our
# statusline starts drawing (manifests as a full-width green bar).
HARD_RESET='\033[0m\033[39m\033[49m'

# ── Git info (cached for performance) ───────────────────────────
CACHE_FILE="/tmp/claude-statusline-git-cache"
CACHE_MAX_AGE=5

# OS-aware stat for modification time
if [[ "$(uname -s)" == "Darwin" ]]; then
    stat_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
    stat_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

cache_is_stale() {
    [ ! -f "$CACHE_FILE" ] || \
    [ $(($(date +%s) - $(stat_mtime "$CACHE_FILE"))) -gt $CACHE_MAX_AGE ]
}

if cache_is_stale; then
    if git rev-parse --git-dir > /dev/null 2>&1; then
        BRANCH=$(git branch --show-current 2>/dev/null)
        STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
        MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
        UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
        echo "$BRANCH|$STAGED|$MODIFIED|$UNTRACKED" > "$CACHE_FILE"
    else
        echo "|||" > "$CACHE_FILE"
    fi
fi

IFS='|' read -r BRANCH STAGED MODIFIED UNTRACKED < "$CACHE_FILE"

# ── Headroom routing indicator (cached) ─────────────────────────
# "Using headroom" means BOTH: this session's ANTHROPIC_BASE_URL points
# at the local proxy (env is inherited from the claude process, so it
# reflects the actual routing) AND the proxy answers /livez. Routed but
# dead proxy = red — that's the silent state where every request fails.
HR_CACHE="/tmp/claude-statusline-hr-cache"
HR_MAX_AGE=10
HR_SEG=""
# PATH-independent install check: the statusline runs in a minimal env
# where ~/.local/bin (pipx's bin dir) may be absent from PATH.
if command -v headroom > /dev/null 2>&1 || [ -x "$HOME/.local/bin/headroom" ]; then
    HR_PORT="${HEADROOM_PORT:-8787}"
    if [ ! -f "$HR_CACHE" ] || \
       [ $(($(date +%s) - $(stat_mtime "$HR_CACHE"))) -gt $HR_MAX_AGE ]; then
        if curl -m 0.3 -fsS "http://127.0.0.1:${HR_PORT}/livez" > /dev/null 2>&1; then
            echo "up" > "$HR_CACHE"
        else
            echo "down" > "$HR_CACHE"
        fi
    fi
    HR_PROXY=$(cat "$HR_CACHE")
    case "${ANTHROPIC_BASE_URL:-}" in
        *"127.0.0.1:${HR_PORT}"* | *"localhost:${HR_PORT}"*)
            if [ "$HR_PROXY" = "up" ]; then
                HR_SEG="${GREEN}HR✓${RESET}"
            else
                HR_SEG="${RED}HR✗${RESET}"
            fi ;;
        *)
            HR_SEG="${DIM}HR off${RESET}" ;;
    esac
fi

# ── Line 1: [Session] Model | Dir | Git | Style ────────────────
if [ -n "$SESSION_NAME" ]; then
    LABEL="${SESSION_NAME}"
else
    LABEL="${SESSION_ID:0:8}"
fi
LINE1="${DIM}[${LABEL}]${RESET} ${CYAN}${BOLD}${MODEL}${RESET}"
LINE1="${LINE1} ${DIM}|${RESET} ${DIM}${HOST}${RESET}${DIM}:${RESET}${DIR}"

if [ -n "$BRANCH" ]; then
    LINE1="${LINE1} ${DIM}|${RESET} ${GREEN}${BRANCH}${RESET}"
    GIT_INDICATORS=""
    [ "$STAGED" -gt 0 ] && GIT_INDICATORS="${GIT_INDICATORS} ${GREEN}+${STAGED}${RESET}"
    [ "$MODIFIED" -gt 0 ] && GIT_INDICATORS="${GIT_INDICATORS} ${YELLOW}~${MODIFIED}${RESET}"
    [ "$UNTRACKED" -gt 0 ] && GIT_INDICATORS="${GIT_INDICATORS} ${RED}?${UNTRACKED}${RESET}"
    LINE1="${LINE1}${GIT_INDICATORS}"
fi

[ -n "$VIM_MODE" ] && LINE1="${LINE1} ${DIM}|${RESET} ${VIM_MODE}"
LINE1="${LINE1} ${DIM}|${RESET} ${DIM}${STYLE}${RESET}"
[ -n "$HR_SEG" ] && LINE1="${LINE1} ${DIM}|${RESET} ${HR_SEG}"

# ── Line 2: Context bar | Cost | Duration | Lines ──────────────
# Color-coded context bar
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

BAR_WIDTH=15
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))
BAR=""
# Build the bar by appending the real multibyte glyphs directly. Do NOT pipe
# through `tr ' ' '█'`: `tr` is byte-oriented, so it maps space to only the
# first byte (0xE2) of the 3-byte block char, emitting invalid UTF-8 that
# renders as garbage. This pure-bash loop needs no external command (portable
# to macOS bash 3.2 and Linux alike) and forks no subshell per render.
for ((i = 0; i < FILLED; i++)); do BAR+='█'; done
for ((i = 0; i < EMPTY; i++)); do BAR+='░'; done

# Format cost
COST_FMT=$(printf '$%.2f' "$COST")

# Format duration
DURATION_SEC=$((DURATION_MS / 1000))
MINS=$((DURATION_SEC / 60))
SECS=$((DURATION_SEC % 60))

# Lines changed
LINES_INFO=""
if [ "$LINES_ADDED" -gt 0 ] || [ "$LINES_REMOVED" -gt 0 ]; then
    LINES_INFO=" ${DIM}|${RESET} ${GREEN}+${LINES_ADDED}${RESET} ${RED}-${LINES_REMOVED}${RESET}"
fi

LINE2="${BAR_COLOR}${BAR}${RESET} ${PCT}% ${DIM}|${RESET} ${YELLOW}${COST_FMT}${RESET} ${DIM}|${RESET} ${MINS}m ${SECS}s${LINES_INFO}"

# ── Author mark (auto-on; disable with: export SIGMA_BRAND=0) ──
# build: 0xBdf1980e7Fc57DBE03874C29c203C3dff576D40c
if [ "${SIGMA_BRAND:-1}" != "0" ]; then
    LINE2="${LINE2} ${DIM}|${RESET} ${DIM}made with ♥ by Sigma Synapses & Busybee Technologies${RESET}"
fi

# ── Output ──────────────────────────────────────────────────────
# Wrap each line in HARD_RESET to neutralize any stray bg attribute the TUI
# may have left active before/after rendering the statusline.
printf '%b%b%b\n' "$HARD_RESET" "$LINE1" "$HARD_RESET"
printf '%b%b%b\n' "$HARD_RESET" "$LINE2" "$HARD_RESET"
