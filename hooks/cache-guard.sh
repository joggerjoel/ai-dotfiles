#!/usr/bin/env bash
# cache-guard.sh — Claude Code prompt-cache awareness: observe / warn / protect.
#
# One event-aware hook (dispatch on .hook_event_name) registered for
# SessionStart, UserPromptSubmit, Stop, PostCompact and SessionEnd, plus two
# self-invoked entry points:
#
#   cache-guard.sh watch <sid> <gen>   detached idle watcher, one per session:
#                                      fires a single desktop notification
#                                      before the cache TTL lapses on a large
#                                      idle session (osascript / notify-send;
#                                      silently does nothing when headless)
#   cache-guard.sh segment             statusline helper: reads the statusline
#                                      JSON on stdin, records token telemetry
#                                      to the session state, prints a colored
#                                      "Cache R184k/W0 · warm 42m" segment
#
# The guard only OBSERVES Anthropic's server-side prompt cache — it cannot and
# does not claim to change the cache TTL or cache keys. TTLs are configured,
# not detected: subscriptions get a 1-hour TTL, API keys default to 5 minutes
# (see ./setup.sh cache).
#
# Fail-open contract: malformed input, a missing jq, or any state error exits 0
# with no output. The ONLY intentional interruption is an explicit
# mode=protect block of a large prompt into a cold session (UserPromptSubmit
# JSON decision, before any model processing).
#
# State: $CACHE_GUARD_STATE_DIR/<session_id>.state    (hook-owned)
#        $CACHE_GUARD_STATE_DIR/<session_id>.telemetry (statusline-owned)
# key=value lines holding ONLY: session id, timestamps, token counts, model /
# effort / fast-mode metadata, warning state and the watcher pid. Prompt text,
# transcript contents and secrets are never written.
#
# Test seams (all optional): CACHE_GUARD_STATE_DIR, CACHE_GUARD_POLICY_FILE,
# CACHE_GUARD_NOW (frozen epoch clock), CACHE_GUARD_NO_WATCHER=1,
# CACHE_GUARD_NOTIFY=0, CACHE_GUARD_NOTIFY_CMD, CACHE_GUARD_WATCH_INTERVAL.

STATE_DIR="${CACHE_GUARD_STATE_DIR:-$HOME/.claude/hooks/.state/cache-guard}"

now() { echo "${CACHE_GUARD_NOW:-$(date +%s)}"; }
is_num() { case "$1" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
sfile() { echo "$STATE_DIR/$1.state"; }
tfile() { echo "$STATE_DIR/$1.telemetry"; }

self_path() {
  # Resolve through the ~/.claude/hooks symlink to the repo copy.
  readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}"
}

# ── Policy (machine-local, gitignored; written by ./setup.sh cache) ─────────
resolve_policy_file() {
  if [ -n "${CACHE_GUARD_POLICY_FILE:-}" ]; then
    echo "$CACHE_GUARD_POLICY_FILE"
  else
    echo "$(dirname "$(self_path)")/../.local/.cache-policy"
  fi
}

load_policy() {
  PROFILE=subscription MODE=warn NOTIFY=auto
  TTL="" MARGIN="" PROTECT_THRESHOLD=100000 WARN_THRESHOLD=20000
  local pf line key val
  pf=$(resolve_policy_file)
  if [ -f "$pf" ]; then
    while IFS= read -r line; do
      key="${line%%=*}" val="${line#*=}"
      case "$key" in
        profile) case "$val" in subscription | api | custom | off) PROFILE="$val" ;; esac ;;
        mode) case "$val" in observe | warn | protect) MODE="$val" ;; esac ;;
        notify) case "$val" in auto | on | off) NOTIFY="$val" ;; esac ;;
        ttl_seconds) is_num "$val" && TTL="$val" ;;
        warning_margin_seconds) is_num "$val" && MARGIN="$val" ;;
        protect_threshold_tokens) is_num "$val" && PROTECT_THRESHOLD="$val" ;;
        warn_threshold_tokens) is_num "$val" && WARN_THRESHOLD="$val" ;;
      esac
    done < "$pf"
  fi
  case "$PROFILE" in
    api) : "${TTL:=300}" "${MARGIN:=60}" ;;
    *) : "${TTL:=3600}" "${MARGIN:=600}" ;;
  esac
  # A margin >= TTL would make every session "expiring" from birth.
  [ "$MARGIN" -lt "$TTL" ] || MARGIN=$((TTL / 6))
}

# ── State (key=value; atomic rewrite via temp + mv) ─────────────────────────
state_get() { # file key
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

state_set() { # file key value [key value ...]
  local f="$1" tmp line key i keep
  shift
  local -a kv=("$@")
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  tmp="${f}.tmp.$$"
  : > "$tmp" 2>/dev/null || return 0
  if [ -f "$f" ]; then
    while IFS= read -r line; do
      key="${line%%=*}" keep=1
      for ((i = 0; i < ${#kv[@]}; i += 2)); do
        [ "$key" = "${kv[i]}" ] && { keep=0; break; }
      done
      [ "$keep" = 1 ] && printf '%s\n' "$line" >> "$tmp"
    done < "$f"
  fi
  for ((i = 0; i < ${#kv[@]}; i += 2)); do
    printf '%s=%s\n' "${kv[i]}" "${kv[i + 1]}" >> "$tmp"
  done
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# ── Cache-state computation (single source of truth, incl. statusline) ──────
# Sets STATE (warm|expiring|cold|unknown) and IDLE. Not a printing function:
# $(cache_state) would run in a subshell and lose IDLE.
cache_state() { # last_activity_epoch
  local last="$1"
  STATE=unknown IDLE=0
  is_num "$last" || return 0
  IDLE=$(($(now) - last))
  if [ "$IDLE" -lt $((TTL - MARGIN)) ]; then
    STATE=warm
  elif [ "$IDLE" -lt "$TTL" ]; then
    STATE=expiring
  else
    STATE=cold
  fi
}

# ── Notifications (desktop only; headless degrades to state/statusline) ─────
notify_available() {
  [ "${CACHE_GUARD_NOTIFY:-1}" = 0 ] && return 1
  [ "$NOTIFY" = off ] && return 1
  [ -n "${CACHE_GUARD_NOTIFY_CMD:-}" ] && return 0
  case "$(uname -s)" in
    Darwin) command -v osascript > /dev/null 2>&1 ;;
    *) command -v notify-send > /dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] ;;
  esac
}

send_notify() { # message (guard-authored only — never prompt/transcript text)
  local msg="$1"
  if [ -n "${CACHE_GUARD_NOTIFY_CMD:-}" ]; then
    "$CACHE_GUARD_NOTIFY_CMD" "$msg" > /dev/null 2>&1
    return
  fi
  case "$(uname -s)" in
    Darwin) osascript -e "display notification \"$msg\" with title \"Claude Code cache\"" > /dev/null 2>&1 ;;
    *) notify-send "Claude Code cache" "$msg" > /dev/null 2>&1 ;;
  esac
}

# ── Watcher (at most one per session; started by SessionStart) ──────────────
start_watcher() { # state_file sid
  local f="$1" sid="$2" pid gen
  [ "${CACHE_GUARD_NO_WATCHER:-0}" = 1 ] && return 0
  notify_available || return 0
  pid=$(state_get "$f" watcher_pid)
  if is_num "$pid" && kill -0 "$pid" 2>/dev/null; then
    return 0 # live watcher already covers this session
  fi
  gen=$(state_get "$f" watcher_gen)
  is_num "$gen" || gen=0
  gen=$((gen + 1))
  nohup "$(self_path)" watch "$sid" "$gen" > /dev/null 2>&1 &
  state_set "$f" watcher_pid "$!" watcher_gen "$gen"
}

run_watcher() { # sid gen
  local sid="$1" gen="$2" interval f t last warned ctx rem
  f=$(sfile "$sid") t=$(tfile "$sid")
  interval="${CACHE_GUARD_WATCH_INTERVAL:-60}"
  while :; do
    sleep "$interval"
    [ -f "$f" ] || exit 0                                # SessionEnd cleaned up
    [ "$(state_get "$f" watcher_gen)" = "$gen" ] || exit 0 # superseded
    load_policy # re-read each tick so a policy change applies live
    [ "$PROFILE" = off ] && exit 0
    last=$(state_get "$f" last_activity)
    is_num "$last" || continue
    cache_state "$last"
    [ "$IDLE" -gt 86400 ] && exit 0 # abandoned session; stop polling
    warned=$(state_get "$f" warned_at)
    ctx=$(state_get "$t" context_tokens)
    is_num "$ctx" || ctx=0
    if [ "$STATE" = expiring ] && [ -z "$warned" ] && [ "$ctx" -ge "$WARN_THRESHOLD" ]; then
      rem=$(((TTL - IDLE + 59) / 60))
      notify_available && send_notify "Session cache expires in ~${rem}m (${ctx} tokens of context). Prompt to keep it warm, or /clear after it goes cold."
      state_set "$f" warned_at "$(now)"
    fi
  done
}

# ── Statusline segment (stdin: statusline JSON) ─────────────────────────────
run_segment() {
  local input sid read_tok write_tok total rem seg
  local GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' DIM=$'\033[2m' RESET=$'\033[0m'
  command -v jq > /dev/null 2>&1 || exit 0
  input=$(cat 2>/dev/null) || exit 0
  load_policy
  [ "$PROFILE" = off ] && exit 0
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  case "$sid" in *[!A-Za-z0-9_-]* | '') exit 0 ;; esac
  # -1 sentinel: current_usage is null before the first API call and again
  # right after /compact — never overwrite telemetry with a phantom zero.
  read_tok=$(printf '%s' "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // -1' 2>/dev/null)
  write_tok=$(printf '%s' "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // -1' 2>/dev/null)
  total=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
  if is_num "$read_tok" && is_num "$write_tok"; then
    state_set "$(tfile "$sid")" \
      context_tokens "$total" cache_read "$read_tok" cache_write "$write_tok" \
      model "$(printf '%s' "$input" | jq -r '.model.id // empty' 2>/dev/null)" \
      effort "$(printf '%s' "$input" | jq -r '.effort.level // empty' 2>/dev/null)" \
      fast_mode "$(printf '%s' "$input" | jq -r '.fast_mode | if . == null then "" else tostring end' 2>/dev/null)" \
      updated_at "$(now)"
  fi
  cache_state "$(state_get "$(sfile "$sid")" last_activity)"
  if ! is_num "$read_tok" || ! is_num "$write_tok"; then
    printf '%s' "${DIM}Cache –${RESET}" # no completed API call yet
    exit 0
  fi
  seg="Cache R$(fmt_k "$read_tok")/W$(fmt_k "$write_tok")"
  case "$STATE" in
    warm)
      rem=$(((TTL - IDLE + 59) / 60))
      printf '%s' "${GREEN}${seg} · warm ${rem}m${RESET}" ;;
    expiring)
      rem=$(((TTL - IDLE + 59) / 60))
      printf '%s' "${YELLOW}${seg} · expiring ${rem}m${RESET}" ;;
    cold)
      printf '%s' "${RED}${seg} · cold${RESET}" ;;
    *)
      printf '%s' "${DIM}${seg} · ?${RESET}" ;; # hook not installed / no state
  esac
}

fmt_k() { # 184215 -> 184k, 950 -> 950
  if [ "$1" -ge 1000 ]; then
    echo "$((($1 + 500) / 1000))k"
  else
    echo "$1"
  fi
}

# ── Hook event handlers ─────────────────────────────────────────────────────
on_session_start() {
  local f src
  f=$(sfile "$SID")
  [ -f "$f" ] || state_set "$f" session_id "$SID" started_at "$(now)"
  src=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
  # A compact-sourced start is a fresh, smaller context: drop the warning latch.
  [ "$src" = compact ] && state_set "$f" warned_at "" compacted_at "$(now)"
  start_watcher "$f" "$SID"
}

on_prompt() {
  local f t ctx
  f=$(sfile "$SID") t=$(tfile "$SID")
  cache_state "$(state_get "$f" last_activity)"
  ctx=$(state_get "$t" context_tokens)
  is_num "$ctx" || ctx=0
  if [ "$STATE" = cold ] && [ "$ctx" -ge "$PROTECT_THRESHOLD" ]; then
    case "$MODE" in
      protect)
        # Supported UserPromptSubmit decision: stops the prompt BEFORE model
        # processing. The prompt is never copied to disk by this hook.
        jq -n --argjson idle_m "$((IDLE / 60))" --argjson ctx "$ctx" '{
          decision: "block",
          reason: "Cache expired; this large prompt would rebuild the session context. Run /clear and resubmit, or disable cache protection to continue this session.",
          suppressOriginalPrompt: false,
          systemMessage: ("cache-guard: blocked — cache cold (idle \($idle_m)m) with \($ctx) tokens of context. /clear to start fresh, or `./setup.sh cache warn` to stop blocking.")
        }'
        return # blocked prompt never reaches the API: no activity to record
        ;;
      warn)
        jq -n --argjson idle_m "$((IDLE / 60))" --argjson ctx "$ctx" '{
          systemMessage: ("cache-guard: cache likely cold (idle \($idle_m)m ≥ TTL) — this prompt re-writes ~\($ctx) tokens of context at full input cost. /clear if you are starting something new.")
        }'
        ;;
      observe) : ;;
    esac
  fi
  state_set "$f" last_activity "$(now)" warned_at ""
}

on_stop() {
  state_set "$(sfile "$SID")" last_activity "$(now)" warned_at ""
}

on_post_compact() {
  local after
  after=$(printf '%s' "$INPUT" | jq -r '.context_after // empty' 2>/dev/null)
  is_num "$after" || after=0
  state_set "$(sfile "$SID")" compacted_at "$(now)" warned_at ""
  # Reset the context estimate so protect/warn thresholds see the shrunken
  # session; the next statusline render repopulates it from live telemetry.
  state_set "$(tfile "$SID")" context_tokens "$after"
}

on_session_end() {
  local f pid
  f=$(sfile "$SID")
  pid=$(state_get "$f" watcher_pid)
  if is_num "$pid"; then kill "$pid" 2>/dev/null; fi
  rm -f "$f" "$(tfile "$SID")"
  # Age out state from sessions that never got a SessionEnd (crash, kill -9).
  find "$STATE_DIR" -maxdepth 1 \( -name '*.state' -o -name '*.telemetry' -o -name '*.tmp.*' \) \
    -mtime +7 -delete 2>/dev/null
}

# ── Entry points ────────────────────────────────────────────────────────────
case "${1:-}" in
  watch)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || exit 0
    run_watcher "$2" "$3"
    exit 0
    ;;
  segment)
    run_segment
    exit 0
    ;;
esac

# Hook mode: JSON event on stdin. Everything below fails open (exit 0).
command -v jq > /dev/null 2>&1 || exit 0
INPUT=$(cat 2>/dev/null) || exit 0
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$EVENT" ] || exit 0
case "$SID" in *[!A-Za-z0-9_-]* | '') exit 0 ;; esac # state files are named by sid

load_policy
if [ "$PROFILE" = off ] && [ "$EVENT" != SessionEnd ]; then exit 0; fi

case "$EVENT" in
  SessionStart) on_session_start ;;
  UserPromptSubmit) on_prompt ;;
  Stop) on_stop ;;
  PostCompact) on_post_compact ;;
  SessionEnd) on_session_end ;;
esac
exit 0
