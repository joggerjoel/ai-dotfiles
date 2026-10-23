#!/usr/bin/env bash
# Tests for scripts/herdr-monitor-workspace.sh. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a hook.
#
# A fake `herdr` on PATH answers from per-machine state files and logs every
# invocation, so the assertions are about what the script asked herdr to do.

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/herdr-monitor-workspace.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdrmon.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ (${2})}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing: $3" ;; esac; }
lacks() { case "$2" in *"$3"*) ko "$1" "unexpected: $3" ;; *) ok "$1" ;; esac; }

# ── fake herdr ─────────────────────────────────────────────────────────────
# State per machine lives in $STATE/<machine>: "has-monitor", "empty",
# "unreachable" or "no-metrics". Calls are appended to $LOG as "<machine> <args>".
mkdir -p "$TMP/bin" "$TMP/state"
cat > "$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
machine=local
if [ "$1" = "--machine" ]; then machine=$2; shift 2; fi
printf '%s %s\n' "$machine" "$*" >> "$LOG"
state=$(cat "$STATE/$machine" 2>/dev/null || echo empty)
case "$1 $2" in
  "machine list")
    printf 'id1\tmacstudio\tjoe@studio\tdefault\tenabled\n'
    printf 'id2\tretired\tjoe@old\tdefault\tdisabled\n'
    printf 'id3\taorus4\taorus4\tdefault\tenabled\n' ;;
  "workspace list")
    [ "$state" = unreachable ] && { echo "error: connection refused" >&2; exit 1; }
    if [ "$state" = has-monitor ]; then
      echo '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"label":"ai-dotfiles","workspace_id":"w1"},{"label":"monitor","workspace_id":"wE"}]}}'
    else
      echo '{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"label":"monitor-ish","workspace_id":"w1"}]}}'
    fi ;;
  "workspace create")
    echo '{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"w9:p1","workspace_id":"w9"},"type":"workspace_created","workspace":{"label":"monitor","workspace_id":"w9"}}}' ;;
  "pane run")
    echo '{"id":"cli:pane:run","result":{"type":"ok"}}' ;;
  "pane wait-output")
    [ "$state" = no-metrics ] && { echo '{"error":"timeout"}'; exit 1; }
    echo '{"id":"cli:pane:wait-output","result":{"type":"matched"}}' ;;
  *) echo "fake herdr: unhandled: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$TMP/bin/herdr"
export LOG="$TMP/calls.log" STATE="$TMP/state"
export HERDR_MONITOR_READY_TIMEOUT=1
run() { : > "$LOG"; PATH="$TMP/bin:$PATH" bash "$SUT" "$@"; }

# ── already present: hands off ─────────────────────────────────────────────
echo has-monitor > "$STATE/aorus4"
out=$(run aorus4); rc=$?
eq "present: exit 0" 0 "$rc"
has "present: reported current" "$out" 'aorus4: "monitor" workspace present (wE)'
has "present: summary" "$out" "created=0 current=1 failed=0"
lacks "present: no create issued" "$(cat "$LOG")" "workspace create"
lacks "present: label match is exact, not substring" "$out" "w1"

# ── absent: create, start the monitor, prove it drew ───────────────────────
echo empty > "$STATE/macstudio"
out=$(run macstudio); rc=$?
eq "absent: exit 0" 0 "$rc"
calls=$(cat "$LOG")
has "absent: forwards to the machine" "$calls" "macstudio workspace list"
has "absent: creates unfocused, labelled, in the target's home" "$calls" "macstudio workspace create --cwd ~ --label monitor --no-focus"
has "absent: runs the monitor in the root pane" "$calls" "macstudio pane run w9:p1 if command -v tmuxp"
has "absent: falls back to glances" "$calls" "else glances; fi"
has "absent: waits for a CPU gauge" "$calls" "macstudio pane wait-output w9:p1 --match CPU --timeout 1"
has "absent: reported created" "$out" 'macstudio: created "monitor" workspace (w9), monitor running'
has "absent: summary" "$out" "created=1 current=0 failed=0"

# ── absent but nothing drew: created, with a pointer, still exit 0 ─────────
echo no-metrics > "$STATE/aorus"
out=$(run aorus); rc=$?
eq "no-metrics: exit 0" 0 "$rc"
has "no-metrics: warns with the pane to read" "$out" "no metrics within 1ms — inspect: herdr --machine aorus pane read w9:p1"
has "no-metrics: still counted as created" "$out" "created=1 current=0 failed=0"

# ── unreachable: a failure, and the run keeps going ────────────────────────
echo unreachable > "$STATE/aorus2"
out=$(run aorus2 aorus4); rc=$?
eq "unreachable: exit 1" 1 "$rc"
has "unreachable: names the host and herdr's reason" "$out" "aorus2: herdr server unreachable — error: connection refused"
has "unreachable: other hosts still converge" "$out" "created=0 current=1 failed=1"

# ── no arguments: local plus every ENABLED saved machine ───────────────────
echo has-monitor > "$STATE/local"
out=$(run); rc=$?
calls=$(cat "$LOG")
has "default: local addressed without --machine" "$calls" "local workspace list"
has "default: enabled machines included" "$calls" "macstudio workspace list"
has "default: enabled machines included (2)" "$calls" "aorus4 workspace list"
lacks "default: disabled machines excluded" "$calls" "retired workspace list"
has "default: local inspect hint has no --machine" "$(echo no-metrics > "$STATE/local"; run local)" "inspect: herdr pane read w9:p1"

# ── no herdr at all: a skip, not a failure ─────────────────────────────────
out=$(: > "$LOG"; PATH="$TMP/nowhere" "$BASH" "$SUT" aorus4); rc=$?
eq "no herdr: exit 0" 0 "$rc"
has "no herdr: says so" "$out" "herdr not installed"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
