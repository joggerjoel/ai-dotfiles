#!/bin/bash
# preflight.sh — verify that configured assets actually work.
#
# Deliberately NOT `set -e`: probes are expected to fail, and the script must
# continue and report rather than abort on the first broken asset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/integrations.sh
source "$DOTFILES_DIR/lib/integrations.sh"

# Every path is overridable so tests never read the real $HOME.
CLAUDE_JSON="${PREFLIGHT_CLAUDE_JSON:-$HOME/.claude.json}"
SETTINGS_JSON="${PREFLIGHT_SETTINGS_JSON:-$HOME/.claude/settings.json}"
ENV_FILE="${PREFLIGHT_ENV_FILE:-$HOME/.claude/.env}"
SKILLS_DIR="${PREFLIGHT_SKILLS_DIR:-$DOTFILES_DIR/skills}"
SMOKE_DIR="${PREFLIGHT_SMOKE_DIR:-$DOTFILES_DIR/tests/smoke}"
MCP_TIMEOUT="${PREFLIGHT_MCP_TIMEOUT:-180}"

OPT_JSON=0
OPT_QUARANTINE=0
OPT_SMOKE=0

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)       OPT_JSON=1 ;;
      --quarantine) OPT_QUARANTINE=1 ;;
      --smoke)      OPT_SMOKE=1 ;;
      -h|--help)
        cat <<'USAGE'
preflight.sh — verify configured assets actually work

  --json         machine-readable output (schema 1)
  --quarantine   disable failing MCP servers (backs up first)
  --smoke        also run tests/smoke/ for assets that passed
  -h, --help     this message
USAGE
        exit 0 ;;
      *)
        echo "unknown option: $1" >&2
        exit 2 ;;
    esac
    shift
  done
}

# class|name|verdict|detail|containable
FINDINGS=()

CHECKER_BROKEN=0
CHECKER_REASON=""
MCP_TIMED_OUT=0

add_finding() {
  FINDINGS+=("$1|$2|$3|$4|$5")
}

# Count findings matching a verdict.
count_verdict() {
  local want="$1" n=0 f
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    [ "$(cut -d'|' -f3 <<<"$f")" = "$want" ] && n=$((n + 1))
  done
  echo "$n"
}

# Probe every MCP server with a single `claude mcp list`. One invocation covers
# all servers in ~90s; per-server probing would cost ~90s each.
probe_mcp() {
  local out rc line name detail
  local seen_names=""

  if ! command -v claude >/dev/null 2>&1; then
    CHECKER_BROKEN=1
    CHECKER_REASON="claude CLI not found on PATH"
    return
  fi

  out=$(timeout "$MCP_TIMEOUT" claude mcp list 2>&1)
  rc=$?

  # 124 is `timeout` killing the child. Every server becomes UNKNOWN — never
  # FAIL. Auto-quarantining a whole toolchain on a network blip is the worst
  # outcome this script can produce.
  if [ "$rc" -eq 124 ]; then
    MCP_TIMED_OUT=1
    local key
    while IFS= read -r key; do
      [ -n "$key" ] && add_finding mcp "$key" unknown "handshake timed out after ${MCP_TIMEOUT}s" no
    done < <(jq -r '.mcpServers // {} | keys[]' "$CLAUDE_JSON" 2>/dev/null)
    return
  fi

  while IFS= read -r line; do
    case "$line" in
      *"✔ Connected"*)
        name="${line%%: *}"
        add_finding mcp "$name" pass "connected" no
        seen_names="$seen_names|$name|"
        ;;
      *"Needs authentication"*)
        name="${line%%: *}"
        add_finding mcp "$name" unknown "needs authentication" no
        seen_names="$seen_names|$name|"
        ;;
      *"✘ Failed to connect"*)
        name="${line%%: *}"
        detail="${line#*✘ }"
        add_finding mcp "$name" fail "$detail" yes
        seen_names="$seen_names|$name|"
        ;;
      *) continue ;;
    esac
  done <<<"$out"

  # Cross-reference against configured servers: any key present in
  # $CLAUDE_JSON that produced no finding above was silently absent from
  # `claude mcp list` output (or emitted a status line none of the case arms
  # recognize). That's still an observable gap, not a clean bill of health —
  # report it as `unknown` (never `fail`: we don't know it's broken, only
  # that we couldn't observe it) so it can't be auto-quarantined.
  local cfg_key
  while IFS= read -r cfg_key; do
    [ -n "$cfg_key" ] || continue
    case "$seen_names" in
      *"|$cfg_key|"*) continue ;;
    esac
    add_finding mcp "$cfg_key" unknown "configured but absent from claude mcp list output" no
  done < <(jq -r '.mcpServers // {} | keys[]' "$CLAUDE_JSON" 2>/dev/null)
}

# Mandated CLIs. Missing ones cannot be contained — there is nothing to disable.
probe_clis() {
  local cli
  for cli in "${MANDATED_CLIS[@]}"; do
    if command -v "$cli" >/dev/null 2>&1; then
      add_finding cli "$cli" pass "on PATH" no
    else
      add_finding cli "$cli" fail "not on PATH — CLAUDE.md names it required" no
    fi
  done
}

# Is a variable set to a non-empty value in the env file or the environment?
env_var_set() {
  local var="$1" val=""
  if [ -f "$ENV_FILE" ]; then
    val=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${var}=" "$ENV_FILE" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=//' | tr -d '"'"'"' ')
  fi
  [ -z "$val" ] && val="${!var:-}"
  [ -n "$val" ]
}

# Is the given $CLAUDE_JSON mcpServers key present? A missing or malformed
# $CLAUDE_JSON simply means "not configured" — jq's failure is swallowed the
# same way probe_mcp already swallows it, so a broken file can never abort
# the run.
integration_configured() {
  jq -e --arg k "$1" '(.mcpServers // {}) | has($k)' "$CLAUDE_JSON" >/dev/null 2>&1
}

# Env-var services declared by INTEGRATIONS (key_var and extra_vars). Only
# integrations actually configured in $CLAUDE_JSON are checked: an
# integration that was deliberately never wired up (or removed) has nothing
# to report on, and flagging it forever produces a checker nobody trusts.
probe_env() {
  local entry name needs_key key_var extra_vars missing key
  for entry in "${INTEGRATIONS[@]}"; do
    IFS='|' read -r name _ needs_key key_var _ extra_vars _ <<<"$entry"
    [ "$needs_key" = "yes" ] || continue

    key="$(mcp_key_for "$name")"
    integration_configured "$key" || continue

    missing=""
    if [ -n "$key_var" ] && ! env_var_set "$key_var"; then
      missing="$key_var"
    fi
    if [ -n "$extra_vars" ] && ! env_var_set "$extra_vars"; then
      missing="${missing:+$missing, }$extra_vars"
    fi

    if [ -n "$missing" ]; then
      add_finding env "$name" fail "unset: $missing" no
    else
      add_finding env "$name" pass "configured" no
    fi
  done
}

# Hook scripts referenced by settings.json must exist and be executable.
probe_hooks() {
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ ! -e "$path" ]; then
      add_finding hook "$path" fail "hook path does not exist" no
    elif [ ! -x "$path" ]; then
      add_finding hook "$path" fail "hook exists but is not executable" no
    else
      add_finding hook "$path" pass "exists and is executable" no
    fi
  done < <(jq -r '[.hooks // {} | .. | objects | .command? // empty] | .[]' "$SETTINGS_JSON" 2>/dev/null \
             | awk '{print $1}' | grep -E '^/|^\$HOME|^~' | sed "s|^~|$HOME|; s|^\$HOME|$HOME|")
}

# Repo-owned skills: frontmatter parses, name matches directory, referenced
# relative paths exist.
probe_skills() {
  local skill_md dir name declared ref
  [ -d "$SKILLS_DIR" ] || return
  while IFS= read -r skill_md; do
    dir="$(dirname "$skill_md")"
    name="$(basename "$dir")"

    if ! head -1 "$skill_md" | grep -q '^---'; then
      add_finding skill "$name" fail "SKILL.md has no frontmatter block" no
      continue
    fi

    declared=$(sed -n '2,/^---/p' "$skill_md" | grep -E '^name:' | head -1 | sed -E 's/^name:[[:space:]]*//')
    if [ -n "$declared" ] && [ "$declared" != "$name" ]; then
      add_finding skill "$name" fail "frontmatter name '$declared' does not match directory" no
      continue
    fi

    # Markdown links to relative paths inside the skill directory.
    local missing_ref=""
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      [ -e "$dir/$ref" ] || missing_ref="$ref"
    done < <(grep -oE '\]\([a-zA-Z0-9._/-]+\)' "$skill_md" 2>/dev/null \
               | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^https?:')

    if [ -n "$missing_ref" ]; then
      add_finding skill "$name" fail "references $missing_ref (missing)" no
    else
      add_finding skill "$name" pass "parses, references resolve" no
    fi
  done < <(find "$SKILLS_DIR" -maxdepth 2 -name SKILL.md 2>/dev/null)
}

# The checker's own dependencies. Missing ones mean exit 2 — "could not run" —
# which must never be confused with exit 1, "ran and found failures".
check_preconditions() {
  local missing=()
  command -v jq >/dev/null 2>&1 || missing+=("jq")
  command -v claude >/dev/null 2>&1 || missing+=("claude")
  if [ ${#missing[@]} -gt 0 ]; then
    CHECKER_BROKEN=1
    CHECKER_REASON="missing required tools: ${missing[*]}"
  fi
}

# Print all findings for one class. Passes collapse onto a single line, so a
# clean report stays skimmable. Body is buffered so the header can print first
# with the correct total.
render_class() {
  local class="$1" label="$2" f c n v d passes=() total=0 body=""
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r c n v d _ <<<"$f"
    [ "$c" = "$class" ] || continue
    total=$((total + 1))
    case "$v" in
      pass)     passes+=("$n") ;;
      fail)     body+="$(printf '  ✘ %-18s %s' "$n" "$d")"$'\n' ;;
      unknown)  body+="$(printf '  ! %-18s %s' "$n" "$d")"$'\n' ;;
      untested) body+="$(printf '  · %-18s %s' "$n" "$d")"$'\n' ;;
    esac
  done
  [ "$total" -eq 0 ] && return
  printf '\n%-40s %3d\n' "$label" "$total"
  if [ ${#passes[@]} -gt 0 ]; then
    printf '  ✔ %s\n' "${passes[*]}"
  fi
  [ -n "$body" ] && printf '%s' "$body"
}

render_human() {
  local pass fail unknown untested total containable f v c
  pass=$(count_verdict pass)
  fail=$(count_verdict fail)
  unknown=$(count_verdict unknown)
  untested=$(count_verdict untested)
  total=$(( pass + fail + unknown + untested ))

  printf 'PREFLIGHT  %s\n' "$(date '+%Y-%m-%d %H:%M')"

  render_class mcp   "MCP SERVERS"
  render_class cli   "MANDATED CLIS"
  render_class env   "ENV-VAR SERVICES"
  render_class hook  "HOOKS & SCRIPTS"
  render_class skill "REPO SKILLS"

  containable=0
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r _ _ v _ c <<<"$f"
    [ "$v" = "fail" ] && [ "$c" = "yes" ] && containable=$((containable + 1))
  done

  printf '\n%s\n' "────────────────────────────────────────────"
  printf '%d assets · %d pass · %d fail · %d unknown\n' "$total" "$pass" "$fail" "$unknown"
  if [ "$containable" -gt 0 ]; then
    printf 'contain %d of %d:  just preflight --quarantine\n' "$containable" "$fail"
  fi
  if [ "$(( fail - containable ))" -gt 0 ]; then
    printf '%d failures need you — not containable\n' "$(( fail - containable ))"
  fi
}

render_json() {
  local f c n v d cont
  {
    printf '{"schema":1,'
    printf '"ranAt":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '"tier":%d,' "$(( OPT_SMOKE ? 3 : 2 ))"
    printf '"summary":{"assets":%d,"pass":%d,"fail":%d,"unknown":%d,"untested":%d},' \
      "${#FINDINGS[@]}" "$(count_verdict pass)" "$(count_verdict fail)" \
      "$(count_verdict unknown)" "$(count_verdict untested)"
    printf '"assets":['
    local first=1
    for f in ${FINDINGS+"${FINDINGS[@]}"}; do
      IFS='|' read -r c n v d cont <<<"$f"
      [ "$first" -eq 0 ] && printf ','
      first=0
      printf '{"class":%s,"name":%s,"verdict":%s,"detail":%s,"containable":%s}' \
        "$(jq -Rn --arg x "$c" '$x')" \
        "$(jq -Rn --arg x "$n" '$x')" \
        "$(jq -Rn --arg x "$v" '$x')" \
        "$(jq -Rn --arg x "$d" '$x')" \
        "$([ "$cont" = "yes" ] && echo true || echo false)"
    done
    printf ']}'
  } | jq .
}

main() {
  parse_args "$@"
  check_preconditions
  if [ "$CHECKER_BROKEN" -eq 1 ]; then
    echo "preflight could not run: $CHECKER_REASON" >&2
    exit 2
  fi

  probe_mcp
  probe_clis
  probe_env
  probe_hooks
  probe_skills

  if [ "$CHECKER_BROKEN" -eq 1 ]; then
    echo "preflight could not run: $CHECKER_REASON" >&2
    exit 2
  fi

  if [ "$MCP_TIMED_OUT" -eq 1 ]; then
    # stderr, not stdout: --json callers pipe stdout straight into `jq` and
    # must see nothing but the JSON object there.
    echo "MCP handshake timed out after ${MCP_TIMEOUT}s — all servers reported unknown" >&2
  fi

  if [ "$OPT_JSON" -eq 1 ]; then
    render_json
  else
    render_human
  fi

  [ "$(count_verdict fail)" -gt 0 ] && exit 1
  exit 0
}

main "$@"
