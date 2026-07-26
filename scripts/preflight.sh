#!/bin/bash
# preflight.sh — verify that configured assets actually work.
#
# Deliberately NOT `set -e`: probes are expected to fail, and the script must
# continue and report rather than abort on the first broken asset.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# On-disk field order: class|name|verdict|containable|detail. Detail is
# stored LAST — not in the add_finding(class, name, verdict, detail,
# containable) call order — because `read` assigns the remainder of the
# line to its final variable, so a detail containing literal `|` survives
# intact instead of shifting containable out of position.
FINDINGS=()

CHECKER_BROKEN=0
CHECKER_REASON=""
MCP_TIMED_OUT=0
CONFIG_MALFORMED_CLAUDE=0
CONFIG_MALFORMED_SETTINGS=0

add_finding() {
  # Public signature stays (class, name, verdict, detail, containable) — no
  # call site moves. Only the stored order changes: detail ($4) goes last.
  FINDINGS+=("$1|$2|$3|$5|$4")
}

# Every jq call against $CLAUDE_JSON / $SETTINGS_JSON elsewhere in this script
# is `2>/dev/null`, on purpose: a *missing* file just means "nothing
# configured" and must stay non-fatal. But that same tolerance means a file
# that exists and is simply corrupt gets swallowed identically — whole
# classes (mcp cross-reference, env, hooks) silently produce zero findings
# and the run looks clean. Validate both files once, up front, and turn a
# malformed-but-present file into an explicit `fail` finding naming the file
# and what it takes down, instead of letting it evaporate.
validate_configs() {
  if [ -f "$CLAUDE_JSON" ] && ! jq -e . "$CLAUDE_JSON" >/dev/null 2>&1; then
    CONFIG_MALFORMED_CLAUDE=1
    add_finding config "$CLAUDE_JSON" fail "malformed JSON — mcp cross-reference and env probes cannot run" no
  fi
  if [ -f "$SETTINGS_JSON" ] && ! jq -e . "$SETTINGS_JSON" >/dev/null 2>&1; then
    CONFIG_MALFORMED_SETTINGS=1
    add_finding config "$SETTINGS_JSON" fail "malformed JSON — hooks probe cannot run" no
  fi
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

  # No `command -v claude` guard here: check_preconditions() already verified
  # `claude` is on PATH before main() ever calls probe_mcp, and exited 2 if
  # not. A duplicate guard here could never fire — see main()'s single
  # CHECKER_BROKEN check right after check_preconditions.
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
  local cfg_key quarantined_at reason
  while IFS= read -r cfg_key; do
    [ -n "$cfg_key" ] || continue
    case "$seen_names" in
      *"|$cfg_key|"*) continue ;;
    esac
    # This is preflight's own quarantine marker (see apply_quarantine):
    # distinguish "I disabled this on purpose" from a genuine unexplained
    # absence, so a server we quarantined ourselves doesn't come back next
    # run looking like a fresh, unexplained gap. Verdict stays `unknown` —
    # a quarantined server must never become containable again.
    quarantined_at=$(jq -r --arg k "$cfg_key" '.mcpServers[$k]._preflight.quarantinedAt // empty' "$CLAUDE_JSON" 2>/dev/null)
    if [ -n "$quarantined_at" ]; then
      reason=$(jq -r --arg k "$cfg_key" '.mcpServers[$k]._preflight.reason // "no reason recorded"' "$CLAUDE_JSON" 2>/dev/null)
      add_finding mcp "$cfg_key" unknown "quarantined by preflight on $quarantined_at: $reason" no
    else
      add_finding mcp "$cfg_key" unknown "configured but absent from claude mcp list output" no
    fi
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
    IFS='|' read -r c n v _ d <<<"$f"
    [ "$c" = "$class" ] || continue
    total=$((total + 1))
    case "$v" in
      pass)     passes+=("$n") ;;
      fail)     body+="$(printf '  ✘ %-18s %s' "$n" "$d")"$'\n' ;;
      unknown)  body+="$(printf '  ! %-18s %s' "$n" "$d")"$'\n' ;;
      untested) body+="$(printf '  · %-18s untested — %s' "$n" "$d")"$'\n' ;;
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

  render_class config "CONFIG FILES"
  render_class mcp   "MCP SERVERS"
  render_class cli   "MANDATED CLIS"
  render_class env   "ENV-VAR SERVICES"
  render_class hook  "HOOKS & SCRIPTS"
  render_class skill "REPO SKILLS"
  render_class smoke "SMOKE"

  containable=0
  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r _ _ v c _ <<<"$f"
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
      IFS='|' read -r c n v cont d <<<"$f"
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

# Disable failing MCP servers, recording why and when. Only class=mcp with
# verdict=fail and containable=yes is eligible: UNKNOWN is never quarantined,
# because "needs authentication" is an unfinished setup, not a fault.
#
# All human-readable output goes to stderr: `preflight.sh --json --quarantine`
# must still emit nothing but the JSON document on stdout (see render_json).
apply_quarantine() {
  local f c n v d cont applied=0 failed=0 backup_done=0 backup ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r c n v cont d <<<"$f"
    [ "$c" = "mcp" ] && [ "$v" = "fail" ] && [ "$cont" = "yes" ] || continue
    jq -e --arg k "$n" '.mcpServers | has($k)' "$CLAUDE_JSON" >/dev/null 2>&1 || continue

    # Backed up at most once per run, regardless of how many servers below
    # fail to write: `applied` only counts successful writes, so gating the
    # backup on it re-ran the cp/banner once per failing server.
    if [ "$backup_done" -eq 0 ]; then
      # mktemp (not a bare date-stamped name) so two runs in the same second
      # never collide and silently clobber the first backup. Same directory
      # as $CLAUDE_JSON. No ".bak" suffix on the template: BSD mktemp (macOS)
      # only randomizes a trailing run of X's — anything after them (e.g.
      # ".XXXXXX.bak") is taken literally and NOT substituted, unlike GNU
      # mktemp. Keeping the X's as the last characters is what's portable.
      # (Also deliberately not `mv`-based: apply_quarantine's own `mv` stub
      # test below shadows `mv` to always fail, and that must only affect the
      # per-server rename, not backup creation.)
      backup="$(mktemp "${CLAUDE_JSON}.preflight-$(date '+%Y%m%d_%H%M%S').XXXXXX")" || {
        echo "preflight: could not create a backup path for $CLAUDE_JSON — aborting quarantine" >&2
        return
      }
      if ! cp "$CLAUDE_JSON" "$backup"; then
        echo "preflight: could not back up $CLAUDE_JSON to $backup — aborting quarantine" >&2
        rm -f "$backup"
        return
      fi
      printf '\nQUARANTINE\n  backed up %s\n' "$backup" >&2
      backup_done=1
    fi

    local tmp
    # Same directory as $CLAUDE_JSON (not $TMPDIR) so the final `mv` is a true
    # atomic rename on one filesystem, and the temp file inherits its perms.
    tmp="$(mktemp "${CLAUDE_JSON}.XXXXXX")"
    # Preserve an existing quarantinedAt so re-running is idempotent.
    if ! jq --arg k "$n" --arg r "$d" --arg t "$ts" '
      .mcpServers[$k].disabled = true
      | .mcpServers[$k]._preflight.quarantinedAt =
          (.mcpServers[$k]._preflight.quarantinedAt // $t)
      | .mcpServers[$k]._preflight.reason = $r
    ' "$CLAUDE_JSON" > "$tmp"; then
      echo "preflight: jq failed while quarantining $n — leaving it untouched" >&2
      rm -f "$tmp"
      failed=$((failed + 1))
      continue
    fi

    # mv must be checked like the jq call above it: on failure, $CLAUDE_JSON
    # is untouched (mv never started writing it — rename is atomic), so
    # report the same "left it untouched" outcome rather than the success
    # line, and don't count it as applied.
    if ! mv "$tmp" "$CLAUDE_JSON"; then
      echo "preflight: mv failed while quarantining $n — leaving it untouched" >&2
      rm -f "$tmp"
      failed=$((failed + 1))
      continue
    fi

    printf '  → %-18s disabled: true\n' "$n" >&2
    applied=$((applied + 1))
  done

  if [ "$applied" -eq 0 ] && [ "$failed" -eq 0 ]; then
    printf '\nQUARANTINE\n  nothing containable\n' >&2
  elif [ "$applied" -eq 0 ]; then
    printf '\nQUARANTINE\n  %d write(s) failed — nothing was contained\n' "$failed" >&2
  else
    printf '  %d contained · re-enable with ./setup.sh add <name>\n' "$applied" >&2
    [ "$failed" -gt 0 ] && printf '  %d write(s) failed — see errors above\n' "$failed" >&2
  fi
}

# Tier 3. Runs only for assets whose tier-2 verdict is pass — smoke-testing a
# server that never connected buries the root cause under cascading noise.
#
# Findings only — no stdout output here. Both renderers must see identical
# tier-3 results (render_json snapshots FINDINGS once; a document claiming
# "tier":3 must actually carry smoke findings), and a --json run's stdout
# must stay a single JSON document, so run_smoke cannot print human text of
# its own. render_human's render_class call is what makes smoke results
# visible in human mode; render_json's existing FINDINGS loop picks them up
# automatically.
run_smoke() {
  local f c n v script rc out
  [ -d "$SMOKE_DIR" ] || return

  for f in ${FINDINGS+"${FINDINGS[@]}"}; do
    IFS='|' read -r c n v _ _ <<<"$f"
    [ "$v" = "pass" ] || continue
    script="$SMOKE_DIR/${c}-${n}.sh"
    if [ ! -x "$script" ]; then
      add_finding smoke "$n" untested "no smoke test" no
      continue
    fi
    out=$(timeout 60 bash "$script" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      add_finding smoke "$n" pass "smoke ok" no
    else
      add_finding smoke "$n" fail "${c}-${n}.sh exit $rc: $(head -1 <<<"$out")" no
    fi
  done
}

main() {
  parse_args "$@"
  check_preconditions
  if [ "$CHECKER_BROKEN" -eq 1 ]; then
    echo "preflight could not run: $CHECKER_REASON" >&2
    exit 2
  fi

  validate_configs

  probe_mcp
  probe_clis
  probe_env
  probe_hooks
  probe_skills

  if [ "$MCP_TIMED_OUT" -eq 1 ]; then
    # stderr, not stdout: --json callers pipe stdout straight into `jq` and
    # must see nothing but the JSON object there.
    echo "MCP handshake timed out after ${MCP_TIMEOUT}s — all servers reported unknown" >&2
  fi

  # Tier 3 must run — and its findings land in FINDINGS — before either
  # renderer executes. run_smoke() only checked pass-verdicts that existed
  # up to this point, so calling it here still runs smoke tests only for
  # assets whose tier-2 verdict is pass.
  if [ "$OPT_SMOKE" -eq 1 ]; then
    run_smoke
  fi

  if [ "$OPT_JSON" -eq 1 ]; then
    render_json
  else
    render_human
  fi

  if [ "$OPT_QUARANTINE" -eq 1 ]; then
    apply_quarantine
  fi

  [ "$(count_verdict fail)" -gt 0 ] && exit 1
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
