#!/bin/bash
# bootstrap-plugins.sh — install the Claude Code plugins that power the agentic
# workflow. The CORE stack auto-installs; OPTIONAL plugins are offered by group
# (opt-in). Everything is reversible later:
#   enable later:   claude plugin install <plugin>@<marketplace>
#   remove:         claude plugin uninstall <plugin>
#   list:           claude plugin list
#
# Run standalone (./scripts/bootstrap-plugins.sh) or via ./setup.sh.
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

# Make `claude` findable in a bare/non-login shell (Ansible, cron, `bash script`).
# The native installer drops the binary in ~/.local/bin but only wires PATH via
# shell rc files, which those shells don't source — so resolve it ourselves.
for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do
  [ -x "$d/claude" ] && PATH="$d:$PATH"
done
if ! command -v claude &>/dev/null; then
  for d in "$HOME"/.nvm/versions/node/*/bin; do
    [ -x "$d/claude" ] && { PATH="$d:$PATH"; break; }
  done
fi
export PATH

if ! command -v claude &>/dev/null; then
  warn "Claude Code CLI not found — install it first, then re-run this script."
  exit 1
fi

# Non-interactive mode: install core only, skip all optional groups.
AUTO="${1:-}"
DOTFILES_ROOT="${AI_DOTFILES_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PLUGIN_SELECTION_FILE="$DOTFILES_ROOT/.local/.plugin-selection"

# ── Marketplaces (GitHub repos) ──────────────────────────────────
# name|repo
MARKETPLACES=(
  "superpowers-marketplace|obra/superpowers-marketplace"
  "claude-plugins-official|anthropics/claude-plugins-official"
  "ui-ux-pro-max-skill|nextlevelbuilder/ui-ux-pro-max-skill"
  "agent-browser|vercel-labs/agent-browser"
  "thedotmack|thedotmack/claude-mem"
  "openai-codex|openai/codex-plugin-cc"
  "karpathy-skills|multica-ai/andrej-karpathy-skills"
  "autoresearch|uditgoenka/autoresearch"
  "aiguide|timescale/pg-aiguide"
  "n8n-mcp-skills|czlonkowski/n8n-skills"
  "pstack-claude|michael-denyer/pstack-claude"
  "caveman|JuliusBrussee/caveman"
  "trailofbits|trailofbits/skills"
  "context-mode|mksglu/context-mode"
  "firecrawl|firecrawl/firecrawl-cli"
)

# ── CORE: the shipping engine (always installed) ─────────────────
# plugin@marketplace|what it gives you
CORE=(
  "superpowers@superpowers-marketplace|Brainstorming, TDD, systematic-debugging, planning, worktrees — the workflow backbone"
  "feature-dev@claude-plugins-official|Guided feature development (architect / explorer / reviewer agents)"
  "code-review@claude-plugins-official|Review a diff/PR for bugs & cleanups"
  "pr-review-toolkit@claude-plugins-official|Specialized review agents (silent-failure, type-design, tests, comments)"
  "code-simplifier@claude-plugins-official|Post-work simplification pass"
  "commit-commands@claude-plugins-official|/commit, /commit-push-pr, /clean_gone git workflow"
  "frontend-design@claude-plugins-official|Production-grade frontend / component generation"
  "ui-ux-pro-max@ui-ux-pro-max-skill|UI/UX intelligence: styles, palettes, font pairs, UX rules"
  "agent-browser@agent-browser|Browser automation + UI verification"
  "claude-mem@thedotmack|Persistent cross-session memory"
  "codex@openai-codex|Second-opinion / rescue via Codex"
  "andrej-karpathy-skills@karpathy-skills|Engineering guidelines (think-before-coding, simplicity, surgical changes)"
  "skill-creator@claude-plugins-official|Create & refine your own skills"
  "typescript-lsp@claude-plugins-official|TypeScript code intelligence"
  "security-guidance@claude-plugins-official|Security guidance & review"
)

# ── OPTIONAL groups (prompted) ───────────────────────────────────
# Each entry: plugin@marketplace|description
OPT_BACKEND=(
  "supabase@claude-plugins-official|Supabase DB / auth / edge functions"
  "stripe@claude-plugins-official|Stripe payments integration"
  "pg@aiguide|Postgres / TimescaleDB / pgvector design skills"
)
OPT_AUTOMATION=(
  "autoresearch@autoresearch|Autonomous iteration / research loops (token-heavy)"
  "n8n-mcp-skills@n8n-mcp-skills|n8n workflow automation expertise"
  "ralph-loop@claude-plugins-official|Long-running autonomous task loop"
  "pstack@pstack-claude|poteto's rigorous parallel workflows: poteto-mode, arena, interrogate, swarm (auto-fires at SessionStart like superpowers)"
  "firecrawl@firecrawl|Firecrawl CLI skills incl. the Developer Index (needs a Firecrawl API key: npx -y firecrawl-cli@latest init --browser)"
)
OPT_INTEL=(
  "serena@claude-plugins-official|Semantic code navigation (LSP-backed)"
  "chrome-devtools-mcp@claude-plugins-official|Chrome DevTools debugging (desktop)"
  "context-mode@context-mode|Sandboxed tool output + session restore (hooks every Bash/Read/Grep; overlaps claude-mem)"
)
OPT_AUTHORING=(
  "plugin-dev@claude-plugins-official|Author your own plugins"
  "hookify@claude-plugins-official|Turn behaviors into enforced hooks"
  "agent-sdk-dev@claude-plugins-official|Build Claude Agent SDK apps"
  "claude-md-management@claude-plugins-official|Maintain CLAUDE.md from session learnings"
  "claude-code-setup@claude-plugins-official|Recommend automations for a codebase"
)
OPT_WRITING=(
  "elements-of-style@superpowers-marketplace|Strunk's writing rules for prose/docs"
  "learning-output-style@claude-plugins-official|Interactive 'learning' output style"
  "caveman@caveman|Terse output mode, on demand via /caveman (settings env CAVEMAN_DEFAULT_MODE=off keeps it off at start)"
)
OPT_SECURITY=(
  "static-analysis@trailofbits|CodeQL / Semgrep / SARIF static analysis (Trail of Bits)"
  "variant-analysis@trailofbits|Find variants of a known bug across a codebase (Trail of Bits)"
  "audit-context-building@trailofbits|Structured codebase understanding before an audit (Trail of Bits)"
)

ALL_PLUGINS=(
  "${CORE[@]}"
  "${OPT_BACKEND[@]}"
  "${OPT_AUTOMATION[@]}"
  "${OPT_INTEL[@]}"
  "${OPT_AUTHORING[@]}"
  "${OPT_WRITING[@]}"
  "${OPT_SECURITY[@]}"
)

# ── Command runner ───────────────────────────────────────────────
# A freshly added marketplace finishes cloning its catalog asynchronously, so
# the `marketplace update` / `plugin install` calls that follow can hit a
# half-populated catalog and fail spuriously. Retry before believing a failure,
# and always keep the output so we can show WHY something failed.
#
# Two rules keep this from wedging an unattended fleet run, both learned the
# hard way (2026-09-03: a `marketplace update` sat for 5+ minutes and took the
# whole `setup.sh update` down with it):
#   1. Every attempt runs under a hard time cap. git inside the CLI has no
#      timeout of its own and macOS ships no `timeout`, so the cap is a
#      portable perl alarm. On expiry the attempt counts as failed, the loop
#      retries, and control falls through to the caller's "stale" warning —
#      the degradation path setup.sh already expects.
#   2. Output goes to a temp file, not `$(...)`. A command substitution waits
#      for every holder of the stdout pipe to close it, so anything the CLI
#      leaves running in the background would block us long after the CLI
#      itself exited. A file has no reader to wait on.
ATTEMPTS=3
RETRY_DELAY=3
CMD_TIMEOUT="${BOOTSTRAP_CMD_TIMEOUT:-120}"
RUN_OUT=""

run_retry() {
  local attempt out rc
  for attempt in $(seq 1 "$ATTEMPTS"); do
    out=$(mktemp)
    # Backgrounded, reaped with `wait`, inside a brace group whose stderr is
    # /dev/null: bash reports a signal death at the moment it reaps the job,
    # so this is the one place "Alarm clock" would otherwise land in the fleet
    # log. The command's own output is already routed to $out before the
    # fork, so nothing useful is lost. rc survives (no subshell); 142 = alarm.
    { perl -e 'alarm shift; exec @ARGV' "$CMD_TIMEOUT" "$@" >"$out" 2>&1 </dev/null & wait $!; rc=$?; } 2>/dev/null
    RUN_OUT=$(<"$out"); rm -f "$out"
    [ "$rc" -eq 0 ] && return 0
    # 142 = killed by the alarm; the CLI printed nothing useful, so say why.
    [ "$rc" -eq 142 ] && RUN_OUT="timed out after ${CMD_TIMEOUT}s: $*"
    [ "$attempt" -lt "$ATTEMPTS" ] && sleep "$RETRY_DELAY"
  done
  return 1
}

# The CLI writes progress and result on one line; show the meaningful tail.
last_line() { printf '%s' "$1" | tr '\r' '\n' | grep -v '^[[:space:]]*$' | tail -1; }

FAILED_PLUGINS=()

add_marketplaces() {
  header "Adding marketplaces"
  for entry in "${MARKETPLACES[@]}"; do
    local name="${entry%%|*}" repo="${entry##*|}"
    # `marketplace add` is idempotent and says "already on disk" when it is a
    # no-op, so trust its own answer rather than grepping `marketplace list` —
    # that list is empty whenever the registry has been reset, which silently
    # turned every marketplace into a "fresh add" and triggered the clone race.
    if run_retry claude plugin marketplace add "$repo"; then
      case "$RUN_OUT" in
        *"already on disk"*) skip "$name (already added)" ;;
        *)                   ok   "$name ($repo)" ;;
      esac
    else
      warn "$name ($repo) — add failed: $(last_line "$RUN_OUT")"
    fi
  done
}

refresh_marketplaces() {
  # Pull the latest catalog for every added marketplace so already-installed
  # plugins pick up updates on the next Claude Code start. Mirrors the daily
  # cron (marketplace-auto-update.sh); harmless right after a fresh add.
  header "Refreshing marketplaces"
  # One attempt, not three. The retry loop exists for the add/install clone
  # race; a refresh that hits the cap is a slow upstream, and retrying only
  # multiplies the wait. A stale catalog is benign — installed plugins keep
  # working, and marketplace-auto-update.sh refreshes daily.
  if ATTEMPTS=1 run_retry claude plugin marketplace update; then
    ok "Marketplaces up to date"
  else
    warn "Marketplace refresh failed: $(last_line "$RUN_OUT")"
    warn "Plugins may be stale — retry: claude plugin marketplace update"
  fi
}

update_installed_plugins() {
  # A catalog refresh alone does not move an installed plugin: claude-mem sat
  # at 13.11.0 with 13.35.0 already in the cache, and its stale SessionStart
  # hook printed invalid JSON on every start. Ask the CLI to update each one.
  header "Updating installed plugins"
  local spec name updated=0 current=0
  local specs
  specs=$(installed_plugins)
  [ -n "$specs" ] || { skip "No installed plugins"; return 0; }
  for spec in ${specs//,/ }; do
    name="${spec%%@*}"
    # One attempt: an update that times out leaves the working version in place.
    if ATTEMPTS=1 run_retry claude plugin update "$spec"; then
      case "$RUN_OUT" in
        *"already at the latest"*) current=$((current + 1)) ;;
        *) ok "$name — $(last_line "$RUN_OUT")"; updated=$((updated + 1)) ;;
      esac
    else
      warn "$name — update failed: $(last_line "$RUN_OUT")"
    fi
  done
  ok "$updated updated, $current already current (restart Claude Code to apply)"
}

install_plugin() {
  local spec="$1" desc="$2" name="${1%%@*}"
  # `plugin install` is idempotent too, and reports "already installed". Asking
  # it directly beats grepping `claude plugin list` for a bare plugin name,
  # which both substring-matched the wrong rows (pg, code-review) and came up
  # empty when the marketplace registry was missing.
  if run_retry claude plugin install "$spec"; then
    case "$RUN_OUT" in
      *"already installed"*) skip "$name (already installed)" ;;
      *)                     ok   "$name — $desc" ;;
    esac
  else
    warn "$name — install failed: $(last_line "$RUN_OUT")"
    FAILED_PLUGINS+=("$spec")
  fi
}

install_core() {
  header "Core stack (the shipping engine)"
  for entry in "${CORE[@]}"; do
    install_plugin "${entry%%|*}" "${entry##*|}"
  done
}

install_saved_core() {
  local saved_selection="$1" entry spec
  header "Core stack (saved selection)"
  for entry in "${CORE[@]}"; do
    spec="${entry%%|*}"
    if contains_spec "$saved_selection" "$spec"; then
      install_plugin "$spec" "${entry##*|}"
    else
      skip "$spec (deselected)"
    fi
  done
}

contains_spec() {
  case ",$1," in *",$2,"*) return 0 ;; *) return 1 ;; esac
}

append_spec() {
  contains_spec "$SELECTED_PLUGINS" "$1" || \
    SELECTED_PLUGINS="${SELECTED_PLUGINS}${SELECTED_PLUGINS:+,}$1"
}

installed_plugins() {
  claude plugin list 2>/dev/null \
    | sed -n 's/^[[:space:]]*❯[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    | paste -sd, -
}

select_group_plugins() {
  local title="$1"; shift
  local group=("$@") defaults="" entry spec marker i=1 answer token start end n old_ifs

  echo ""
  echo -e "  ${BOLD}${title}${RESET}"
  for entry in "${group[@]}"; do
    spec="${entry%%|*}"
    marker="[ ]"
    if contains_spec "$BASELINE_PLUGINS" "$spec"; then
      marker="[installed]"
      defaults="${defaults}${defaults:+,}${i}"
    fi
    printf "    %2d) %-11s %-36s %s\n" "$i" "$marker" "$spec" "${entry##*|}"
    i=$((i+1))
  done

  echo -ne "  Select plugins (1,3-5 | all | none | Enter keeps installed): "
  read -r answer || answer=""
  [ -n "$answer" ] || answer="$defaults"
  answer=$(printf '%s' "$answer" | tr -d ' ')
  [ "$answer" = "none" ] && return 0

  if [ "$answer" = "all" ]; then
    for entry in "${group[@]}"; do append_spec "${entry%%|*}"; done
    return 0
  fi

  old_ifs="$IFS"; IFS=','
  for token in $answer; do
    case "$token" in
      *-*) start="${token%-*}"; end="${token#*-}" ;;
      *) start="$token"; end="$token" ;;
    esac
    case "$start:$end" in
      *[!0-9:]*|:*) warn "Ignoring invalid selection '$token'"; continue ;;
    esac
    [ "$start" -le "$end" ] 2>/dev/null || { warn "Ignoring invalid range '$token'"; continue; }
    n="$start"
    while [ "$n" -le "$end" ]; do
      if [ "$n" -ge 1 ] && [ "$n" -le "${#group[@]}" ]; then
        entry="${group[$((n-1))]}"
        append_spec "${entry%%|*}"
      else
        warn "Ignoring out-of-range choice '$n'"
      fi
      n=$((n+1))
    done
  done
  IFS="$old_ifs"
}

description_for() {
  local want="$1" entry
  for entry in "${ALL_PLUGINS[@]}"; do
    [ "${entry%%|*}" = "$want" ] && { printf '%s' "${entry##*|}"; return 0; }
  done
  return 1
}

uninstall_plugin() {
  local spec="$1" name="${1%%@*}"
  if run_retry claude plugin uninstall --keep-data "$name"; then
    ok "$spec deselected and uninstalled"
  else
    warn "$spec — uninstall failed: $(last_line "$RUN_OUT")"
    FAILED_PLUGINS+=("uninstall $name")
  fi
}

# ── Run ──────────────────────────────────────────────────────────
add_marketplaces
refresh_marketplaces
update_installed_plugins

if [ "$AUTO" = "--core-only" ] || [ "$AUTO" = "-y" ]; then
  if [ -f "$PLUGIN_SELECTION_FILE" ]; then
    saved_plugins=$(cat "$PLUGIN_SELECTION_FILE")
    [ "$saved_plugins" = "none" ] && saved_plugins=""
    install_saved_core "$saved_plugins"
  else
    install_core
  fi
  echo ""
  ok "Saved core selection reconciled. Optional groups skipped (--core-only)."
  echo -e "  ${DIM}See optional plugins: open scripts/bootstrap-plugins.sh${RESET}"
else
  INSTALLED_PLUGINS=$(installed_plugins)
  BASELINE_PLUGINS="$INSTALLED_PLUGINS"
  SELECTED_PLUGINS=""

  if [ -f "$PLUGIN_SELECTION_FILE" ]; then
    SELECTED_PLUGINS=$(cat "$PLUGIN_SELECTION_FILE")
    [ "$SELECTED_PLUGINS" = "none" ] && SELECTED_PLUGINS=""
    skip "Plugin selection loaded from .local/.plugin-selection"
  else
    header "Plugin selection"
    echo -e "  ${DIM}Installed packages are preselected. Omit one to uninstall it.${RESET}"
    select_group_plugins "Core stack"             "${CORE[@]}"
    select_group_plugins "Backend & data"          "${OPT_BACKEND[@]}"
    select_group_plugins "Automation & research"   "${OPT_AUTOMATION[@]}"
    select_group_plugins "Code intelligence"       "${OPT_INTEL[@]}"
    select_group_plugins "Authoring & meta"         "${OPT_AUTHORING[@]}"
    select_group_plugins "Writing & output"         "${OPT_WRITING[@]}"
    select_group_plugins "Security audit"           "${OPT_SECURITY[@]}"
  fi

  mkdir -p "$(dirname "$PLUGIN_SELECTION_FILE")"
  printf '%s\n' "${SELECTED_PLUGINS:-none}" > "$PLUGIN_SELECTION_FILE"

  old_ifs="$IFS"; IFS=','
  for spec in $SELECTED_PLUGINS; do
    [ -n "$spec" ] || continue
    install_plugin "$spec" "$(description_for "$spec")"
  done
  IFS="$old_ifs"

  for entry in "${ALL_PLUGINS[@]}"; do
    spec="${entry%%|*}"
    if contains_spec "$INSTALLED_PLUGINS" "$spec" && ! contains_spec "$SELECTED_PLUGINS" "$spec"; then
      uninstall_plugin "$spec"
    fi
  done
fi

header "Plugins bootstrapped"
if [ ${#FAILED_PLUGINS[@]} -gt 0 ]; then
  warn "${#FAILED_PLUGINS[@]} plugin(s) failed after $ATTEMPTS attempts:"
  for spec in "${FAILED_PLUGINS[@]}"; do
    echo -e "      ${DIM}claude plugin install $spec${RESET}"
  done
fi
echo -e "  ${DIM}Restart Claude Code to load newly installed plugins.${RESET}"
echo -e "  ${DIM}List:   claude plugin list${RESET}"
echo -e "  ${DIM}Add:    claude plugin install <plugin>@<marketplace>${RESET}"
echo -e "  ${DIM}Remove: claude plugin uninstall <plugin>${RESET}"

[ ${#FAILED_PLUGINS[@]} -eq 0 ]
