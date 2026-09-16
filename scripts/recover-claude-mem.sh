#!/usr/bin/env bash
# Recover a claude-mem worker that owns its port but no longer answers HTTP.
#
# --restart stops a RUNNING worker (healthy or not) and starts a fresh one, so
# it picks up this shell's environment. claude-mem reads CLAUDE_MEM_LLM_TIMEOUT_MS
# from process.env once at worker start, and its own `restart` subcommand has the
# old worker respawn itself with the old environment, so a real stop is the only
# way to apply a new value. With no worker listening this does nothing: the next
# hook-spawned worker inherits the value from Claude Code instead.
#
# The start path is the worker's `start` subcommand, not a synthetic
# `session-init` hook call: from 13.25.1 that hook skips when no sessionId is
# supplied, so it no longer spawns anything.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MEM_DIR="${CLAUDE_MEM_HOME:-$HOME/.claude-mem}"

RESTART=0
for arg in "$@"; do
    case "$arg" in
        --restart)
            RESTART=1
            ;;
        *)
            echo "claude-mem: unknown argument: $arg" >&2
            echo "usage: recover-claude-mem.sh [--restart]" >&2
            exit 1
            ;;
    esac
done

worker_port() {
    if [ -n "${CLAUDE_MEM_WORKER_PORT:-}" ]; then
        printf '%s\n' "$CLAUDE_MEM_WORKER_PORT"
        return
    fi

    node - "$MEM_DIR/settings.json" <<'NODE'
const fs = require("node:fs");
const settingsPath = process.argv[2];
const fallback = 37700 + ((process.getuid?.() ?? 77) % 100);

try {
  const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  process.stdout.write(String(settings.CLAUDE_MEM_WORKER_PORT || fallback));
} catch {
  process.stdout.write(String(fallback));
}
NODE
}

recorded_pid() {
    node - "$MEM_DIR/worker.pid" <<'NODE'
const fs = require("node:fs");
try {
  process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[2], "utf8")).pid || ""));
} catch {}
NODE
}

find_plugin_root() {
    local candidate root
    local -a candidates=()

    if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
        candidates+=("$CLAUDE_PLUGIN_ROOT")
    elif [ -n "${PLUGIN_ROOT:-}" ]; then
        candidates+=("$PLUGIN_ROOT")
    fi

    while IFS= read -r candidate; do
        [ -n "$candidate" ] && candidates+=("${candidate%/}")
    done < <(find "$CLAUDE_DIR/plugins/cache/thedotmack/claude-mem" \
        -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -Vr)
    candidates+=("$CLAUDE_DIR/plugins/marketplaces/thedotmack/plugin")

    for candidate in "${candidates[@]}"; do
        if [ -d "$candidate/plugin/scripts" ]; then
            root="$candidate/plugin"
        else
            root="$candidate"
        fi
        if [ -f "$root/scripts/bun-runner.js" ] && \
            [ -f "$root/scripts/worker-service.cjs" ]; then
            printf '%s\n' "$root"
            return 0
        fi
    done

    return 1
}

# `|| true` is load-bearing: lsof exits 1 when nothing is listening, and under
# `set -e` with pipefail that status kills the script at the assignment instead
# of reaching the "no worker" branch below.
listener_pid() {
    lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sed -n '1p' || true
}

is_healthy() {
    curl --fail --silent --show-error --max-time 3 \
        "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
}

wait_for_exit() {
    local pid="$1"
    for _attempt in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 1
    done
    return 1
}

stop_worker() {
    local pid="$1" reason="$2" recorded command

    case "$pid" in
        *[!0-9]*)
            echo "claude-mem: invalid listener PID: $pid" >&2
            exit 1
            ;;
    esac

    recorded=$(recorded_pid)
    command=$(ps -p "$pid" -o command= 2>/dev/null || true)
    if [ "$pid" != "$recorded" ] || \
        ! printf '%s\n' "$command" | grep -Eq '/scripts/worker-service\.cjs --daemon([[:space:]]|$)'; then
        echo "claude-mem: port $PORT is owned by an unverified process; refusing to stop PID $pid" >&2
        exit 1
    fi

    echo "claude-mem: stopping $reason worker PID $pid"
    kill -TERM "$pid"
    if ! wait_for_exit "$pid"; then
        echo "claude-mem: worker ignored SIGTERM; force-stopping validated PID $pid"
        kill -KILL "$pid"
        wait_for_exit "$pid" || {
            echo "claude-mem: worker PID $pid did not exit" >&2
            exit 1
        }
    fi
}

start_worker() {
    local plugin_root
    plugin_root=$(find_plugin_root) || {
        echo "claude-mem: plugin scripts not found under $CLAUDE_DIR" >&2
        exit 1
    }

    echo "claude-mem: starting worker from $plugin_root"
    node \
        "$plugin_root/scripts/bun-runner.js" \
        "$plugin_root/scripts/worker-service.cjs" \
        start >/dev/null
}

worker_env_tokens() {
    local pid="$1"
    if [ -r "/proc/$pid/environ" ]; then
        tr '\0' '\n' < "/proc/$pid/environ"
    else
        ps -Eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n'
    fi
}

report_timeout_env() {
    local pid="$1" entry
    if [ -z "$pid" ]; then
        echo "claude-mem: no worker PID recorded; cannot confirm CLAUDE_MEM_LLM_TIMEOUT_MS"
        return 0
    fi

    entry=$(worker_env_tokens "$pid" 2>/dev/null | grep -m1 '^CLAUDE_MEM_LLM_TIMEOUT_MS=' || true)
    if [ -n "$entry" ]; then
        echo "claude-mem: worker PID $pid carries $entry"
    else
        echo "claude-mem: worker PID $pid has no CLAUDE_MEM_LLM_TIMEOUT_MS in its environment"
    fi
}

PORT=$(worker_port)
case "$PORT" in
    ''|*[!0-9]*)
        echo "claude-mem: invalid worker port: $PORT" >&2
        exit 1
        ;;
esac

if [ "$RESTART" -eq 0 ] && is_healthy; then
    echo "claude-mem: healthy on port $PORT; nothing to recover"
    exit 0
fi

LISTENER_PID=$(listener_pid)

if [ "$RESTART" -eq 1 ] && [ -z "$LISTENER_PID" ]; then
    echo "claude-mem: worker not running; nothing to restart"
    exit 0
fi

if [ -n "$LISTENER_PID" ]; then
    if [ "$RESTART" -eq 1 ]; then
        stop_worker "$LISTENER_PID" "running"
    else
        stop_worker "$LISTENER_PID" "unresponsive"
    fi
fi

start_worker

for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if is_healthy; then
        if [ "$RESTART" -eq 1 ]; then
            echo "claude-mem: restarted; health check passed on port $PORT"
        else
            echo "claude-mem: recovered; health check passed on port $PORT"
        fi
        report_timeout_env "$(recorded_pid)"
        exit 0
    fi
    sleep 1
done

echo "claude-mem: restart attempted, but port $PORT is still unhealthy" >&2
exit 1
