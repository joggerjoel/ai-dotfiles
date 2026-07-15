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

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; CYAN='\033[36m'; RESET='\033[0m'
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

add_marketplaces() {
  header "Adding marketplaces"
  for entry in "${MARKETPLACES[@]}"; do
    local name="${entry%%|*}" repo="${entry##*|}"
    if claude plugin marketplace list 2>/dev/null | grep -q "$name"; then
      skip "$name (already added)"
    elif claude plugin marketplace add "$repo" &>/dev/null; then
      ok "$name ($repo)"
    else
      warn "$name ($repo) — add failed, skipping its plugins"
    fi
  done
}

refresh_marketplaces() {
  # Pull the latest catalog for every added marketplace so already-installed
  # plugins pick up updates on the next Claude Code start. Mirrors the daily
  # cron (marketplace-auto-update.sh); harmless right after a fresh add.
  header "Refreshing marketplaces"
  if claude plugin marketplace update &>/dev/null; then
    ok "Marketplaces up to date"
  else
    warn "Marketplace refresh had issues (network?) — plugins may be stale"
  fi
}

install_plugin() {
  local spec="$1" desc="$2" name="${1%%@*}"
  if claude plugin list 2>/dev/null | grep -q "$name"; then
    skip "$name (already installed)"
  elif claude plugin install "$spec" &>/dev/null; then
    ok "$name — $desc"
  else
    warn "$name — install failed"
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
  read -r ans
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
echo -e "  ${DIM}Restart Claude Code to load newly installed plugins.${RESET}"
echo -e "  ${DIM}List:   claude plugin list${RESET}"
echo -e "  ${DIM}Add:    claude plugin install <plugin>@<marketplace>${RESET}"
echo -e "  ${DIM}Remove: claude plugin uninstall <plugin>${RESET}"
