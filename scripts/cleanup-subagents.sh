#!/bin/bash
# Cleanup stale Claude subagent processes
# Strategy: hard cap on count + age-based kill (ignores CPU)

MAX_SUBAGENTS=${1:-3}   # Max allowed subagents at once
TTL_MINUTES=${2:-10}    # Kill any subagent older than this regardless of CPU

LOG_FILE="$HOME/.claude/.changelog/subagent-cleanup.log"

# ── OS-aware helpers ─────────────────────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]]; then
    stat_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
    parse_time() {
        date -j -f "%I:%M%p" "$1" +%s 2>/dev/null || \
        date -j -f "%H:%M" "$1" +%s 2>/dev/null || echo 0
    }
else
    stat_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
    parse_time() {
        # Linux ps time format: HH:MM or Mon DD
        date -d "$1" +%s 2>/dev/null || echo 0
    }
fi

cleanup_subagents() {
    local killed=0
    local now
    now=$(date +%s)
    local pids=()
    local ages=()

    # Collect all subagent processes (have --disallowedTools flag)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        pid=$(echo "$line" | awk '{print $2}')
        start_time=$(echo "$line" | awk '{print $9}')

        # Get process start time in epoch
        if [[ "$start_time" =~ ^[0-9]+:[0-9]+[AP]M$ ]] || [[ "$start_time" =~ ^[0-9]+:[0-9]+$ ]]; then
            proc_epoch=$(parse_time "$start_time")
        else
            proc_epoch=0
        fi

        if [[ $proc_epoch -gt 0 ]]; then
            age_minutes=$(( (now - proc_epoch) / 60 ))
        else
            age_minutes=999
        fi

        pids+=("$pid")
        ages+=("$age_minutes")
    done < <(ps aux | grep "disallowedTools" | grep -v grep)

    local total=${#pids[@]}

    for i in "${!pids[@]}"; do
        local should_kill=false

        # Rule 1: Kill any subagent older than TTL (regardless of CPU)
        if [[ ${ages[$i]} -ge $TTL_MINUTES ]]; then
            should_kill=true
        fi

        # Rule 2: Kill oldest first if over max count
        if [[ $total -gt $MAX_SUBAGENTS ]]; then
            should_kill=true
        fi

        if [[ "$should_kill" == "true" ]]; then
            kill -9 "${pids[$i]}" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') | Killed PID ${pids[$i]} (age: ${ages[$i]}m, total: $total)" >> "$LOG_FILE"
                ((killed++))
                ((total--))
            fi
        fi
    done

    echo "$killed"
}

killed=$(cleanup_subagents)

if [[ $killed -gt 0 ]]; then
    echo "Cleaned up $killed stale subagent(s)"
else
    echo "No stale subagents found"
fi
