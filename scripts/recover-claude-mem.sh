#!/usr/bin/env bash
# Recover a claude-mem worker that owns its port but no longer answers HTTP.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MEM_DIR="${CLAUDE_MEM_HOME:-$HOME/.claude-mem}"

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

PORT=$(worker_port)
case "$PORT" in
    ''|*[!0-9]*)
        echo "claude-mem: invalid worker port: $PORT" >&2
        exit 1
        ;;
esac

if is_healthy; then
    echo "claude-mem: healthy on port $PORT; nothing to recover"
    exit 0
fi

LISTENER_PID=$(lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sed -n '1p')
if [ -n "$LISTENER_PID" ]; then
    case "$LISTENER_PID" in
        *[!0-9]*)
            echo "claude-mem: invalid listener PID: $LISTENER_PID" >&2
            exit 1
            ;;
    esac

    RECORDED_PID=$(node - "$MEM_DIR/worker.pid" <<'NODE'
const fs = require("node:fs");
try {
  process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[2], "utf8")).pid || ""));
} catch {}
NODE
)
    COMMAND=$(ps -p "$LISTENER_PID" -o command= 2>/dev/null || true)
    if [ "$LISTENER_PID" != "$RECORDED_PID" ] || \
        ! printf '%s\n' "$COMMAND" | grep -Eq '/scripts/worker-service\.cjs --daemon([[:space:]]|$)'; then
        echo "claude-mem: port $PORT is owned by an unverified process; refusing to stop PID $LISTENER_PID" >&2
        exit 1
    fi

    echo "claude-mem: stopping unresponsive worker PID $LISTENER_PID"
    kill -TERM "$LISTENER_PID"
    if ! wait_for_exit "$LISTENER_PID"; then
        echo "claude-mem: worker ignored SIGTERM; force-stopping validated PID $LISTENER_PID"
        kill -KILL "$LISTENER_PID"
        wait_for_exit "$LISTENER_PID" || {
            echo "claude-mem: worker PID $LISTENER_PID did not exit" >&2
            exit 1
        }
    fi
fi

PLUGIN_ROOT=$(find_plugin_root) || {
    echo "claude-mem: plugin scripts not found under $CLAUDE_DIR" >&2
    exit 1
}

echo "claude-mem: starting worker from $PLUGIN_ROOT"
printf '{}\n' | node \
    "$PLUGIN_ROOT/scripts/bun-runner.js" \
    "$PLUGIN_ROOT/scripts/worker-service.cjs" \
    hook claude-code session-init >/dev/null

for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if is_healthy; then
        echo "claude-mem: recovered; health check passed on port $PORT"
        exit 0
    fi
    sleep 1
done

echo "claude-mem: restart attempted, but port $PORT is still unhealthy" >&2
exit 1
