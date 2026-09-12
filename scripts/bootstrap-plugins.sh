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
)
OPT_INTEL=(
  "serena@claude-plugins-official|Semantic code navigation (LSP-backed)"
  "chrome-devtools-mcp@claude-plugins-official|Chrome DevTools debugging (desktop)"
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

offer_group() {
  local title="$1"; shift
  local group=("$@")
  echo ""
  echo -e "  ${BOLD}${title}${RESET}"
  for entry in "${group[@]}"; do
    printf "      ${DIM}%-32s${RESET} %s\n" "${entry%%|*}" "${entry##*|}"
  done
  echo -ne "  Install this group? (y/N): "
  read -r ans || ans=""
  case "${ans:-n}" in
    y|Y|yes)
      for entry in "${group[@]}"; do install_plugin "${entry%%|*}" "${entry##*|}"; done ;;
    *) skip "Skipped (add later with: claude plugin install <plugin>@<marketplace>)" ;;
  esac
}

# ── Run ──────────────────────────────────────────────────────────
add_marketplaces
refresh_marketplaces
install_core

if [ "$AUTO" = "--core-only" ] || [ "$AUTO" = "-y" ]; then
  echo ""
  ok "Core installed. Optional groups skipped (--core-only)."
  echo -e "  ${DIM}See optional plugins: open scripts/bootstrap-plugins.sh${RESET}"
else
  header "Optional plugins (opt-in — you can add/remove any of these anytime)"
  offer_group "Backend & data"       "${OPT_BACKEND[@]}"
  offer_group "Automation & research" "${OPT_AUTOMATION[@]}"
  offer_group "Code intelligence"     "${OPT_INTEL[@]}"
  offer_group "Authoring & meta"      "${OPT_AUTHORING[@]}"
  offer_group "Writing & output"      "${OPT_WRITING[@]}"
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
