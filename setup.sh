#!/bin/bash
set -euo pipefail

# ── Colors & formatting ──────────────────────────────────────────
BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

ok() { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"

# ── OS-aware helpers ─────────────────────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]]; then
    sed_inplace() { sed -i '' "$@"; }
else
    sed_inplace() { sed -i "$@"; }
fi

# ── MCP Integration definitions ──────────────────────────────────
# Format: name|description|needs_key|key_var|disabled_by_default|extra_vars|desktop_only
INTEGRATIONS=(
  "context7|Documentation lookup|no||||no"
  "serena|Semantic code assistant|no||||no"
  "morphllm-fast-apply|Fast code application|no||||no"
  "chrome-devtools|Browser DevTools (desktop only)|no||yes||yes"
  "firecrawl|Web scraping (large-scale)|yes|FIRECRAWL_API_KEY|||no"
  "github|GitHub repo/issue/PR management|yes|GITHUB_PERSONAL_ACCESS_TOKEN|yes||no"
  "openrouter|OpenRouter AI models|yes|OPENROUTER_API_KEY|yes||no"
  "apify|Web scraping actors|yes|APIFY_TOKEN|yes||no"
  "digitalocean|DigitalOcean infrastructure|yes|DIGITALOCEAN_API_TOKEN|yes||no"
  "n8n|Workflow automation|yes|N8N_JWT|yes|N8N_URL|no"
  "crawl4ai|Self-hosted web scraping (SSE)|yes|CRAWL4AI_TOKEN|yes|CRAWL4AI_URL|no"
  "playwright|Browser automation & testing|no||yes||yes"
  "browser-tools|Advanced browser tools|no||yes||yes"
  "magic|UI component generation|no||yes||yes"
)

# ── MCP server JSON generators ───────────────────────────────────
mcp_json_for() {
  local name="$1" key_val="${2:-}" extra_val="${3:-}"
  case "$name" in
    context7)
      echo '{"type":"stdio","command":"npx","args":["-y","@upstash/context7-mcp"],"env":{}}';;
    serena)
      echo '{"type":"stdio","command":"uvx","args":["--from","git+https://github.com/oraios/serena","serena","start-mcp-server","--context","ide-assistant","--enable-web-dashboard","false","--enable-gui-log-window","false"],"env":{}}';;
    morphllm-fast-apply)
      echo '{"type":"stdio","command":"npx","args":["-y","@morph-llm/morph-fast-apply"],"env":{}}';;
    chrome-devtools)
      echo '{"type":"stdio","command":"npx","args":["-y","chrome-devtools-mcp@latest"],"env":{}}';;
    firecrawl)
      echo "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"firecrawl-mcp\"],\"env\":{\"FIRECRAWL_API_KEY\":\"${key_val}\"}}";;
    github)
      echo "{\"command\":\"npx\",\"args\":[\"-y\",\"@modelcontextprotocol/server-github\"],\"env\":{\"GITHUB_PERSONAL_ACCESS_TOKEN\":\"${key_val}\"}}";;
    openrouter)
      echo "{\"command\":\"npx\",\"args\":[\"-y\",\"@mcpservers/openrouterai\"],\"env\":{\"OPENROUTER_API_KEY\":\"${key_val}\"}}";;
    apify)
      echo "{\"command\":\"npx\",\"args\":[\"-y\",\"@apify/actors-mcp-server\"],\"env\":{\"APIFY_TOKEN\":\"${key_val}\"}}";;
    digitalocean)
      echo "{\"command\":\"npx\",\"args\":[\"@digitalocean/mcp\",\"--services\",\"apps,databases\"],\"env\":{\"DIGITALOCEAN_API_TOKEN\":\"${key_val}\"}}";;
    n8n)
      local url="${extra_val:-https://n8n.example.com/mcp-server/http}"
      echo "{\"type\":\"http\",\"url\":\"${url}\",\"headers\":{\"Authorization\":\"Bearer ${key_val}\"}}";;
    crawl4ai)
      local url="${extra_val:-https://crawl.example.com/mcp/sse}"
      echo "{\"type\":\"sse\",\"url\":\"${url}\",\"headers\":{\"Authorization\":\"Bearer ${key_val}\"}}";;
    playwright)
      echo '{"command":"npx","args":["@playwright/mcp@latest"]}';;
    browser-tools)
      echo '{"command":"npx","args":["-y","@agentdeskai/browser-tools-mcp@latest"]}';;
    magic)
      echo '{"type":"stdio","command":"npx","args":["-y","@21st-dev/magic"],"env":{}}';;
    *) echo '{}' ;;
  esac
}

# Map integration names to .claude.json MCP key names
mcp_key_for() {
  case "$1" in
    browser-tools) echo "browser-tools-mcp" ;;
    firecrawl) echo "firecrawl-mcp" ;;
    openrouter) echo "openrouterai" ;;
    digitalocean) echo "digitalocean-mcp" ;;
    n8n) echo "n8n-mcp" ;;
    *) echo "$1" ;;
  esac
}

# ── Helpers ───────────────────────────────────────────────────────
check_prereq() {
  local missing=()
  for cmd in jq git curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing required tools: ${missing[*]}"
    echo "  Install them first, then re-run setup."
    exit 1
  fi
  ok "Prerequisites: jq, git, curl"
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "macOS" ;;
    Linux)  echo "Linux" ;;
    *)      echo "Unknown" ;;
  esac
}

ensure_claude_json() {
  if [ ! -f "$CLAUDE_JSON" ]; then
    echo '{"mcpServers":{}}' > "$CLAUDE_JSON"
    ok "Created $CLAUDE_JSON"
  else
    # Ensure mcpServers key exists
    if ! jq -e '.mcpServers' "$CLAUDE_JSON" &>/dev/null; then
      local tmp
      tmp=$(jq '. + {"mcpServers":{}}' "$CLAUDE_JSON")
      echo "$tmp" > "$CLAUDE_JSON"
    fi
  fi
}

set_mcp_server() {
  local name="$1" json="$2" disabled="${3:-false}"
  local mcp_key
  mcp_key=$(mcp_key_for "$name")

  if [ "$disabled" = "true" ]; then
    json=$(echo "$json" | jq '. + {"disabled": true}')
  fi

  local tmp
  tmp=$(jq --arg key "$mcp_key" --argjson val "$json" '.mcpServers[$key] = $val' "$CLAUDE_JSON")
  echo "$tmp" > "$CLAUDE_JSON"
}

link_file() {
  local src="$1" dst="$2"
  local dst_dir
  dst_dir=$(dirname "$dst")
  mkdir -p "$dst_dir"

  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -f "$dst" ]; then
    # Backup existing file
    local backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_dir/$(basename "$dst")"
    warn "Backed up existing $(basename "$dst") to $backup_dir/"
    rm "$dst"
  fi

  ln -s "$src" "$dst"
  ok "$(basename "$dst") -> $(basename "$src")"
}

# ── Parse integration fields ─────────────────────────────────────
get_field() {
  echo "$1" | cut -d'|' -f"$2"
}

# ── Skill installation ───────────────────────────────────────────
# Copies repo skills/<name>/ into ~/.claude/skills/<name>/ (copy model, like
# references). Only touches skills the repo owns; leaves plugin-provided and
# user-local skills untouched. setup.sh does NOT install plugins/marketplaces —
# those are declared in profiles/<profile>/settings.json (enabledPlugins) and
# must be added via `claude plugin marketplace add` / `claude plugin install`.
install_skills() {
  [ -d "$DOTFILES_DIR/skills" ] || return 0
  mkdir -p "$CLAUDE_DIR/skills"
  local count=0
  for skill_dir in "$DOTFILES_DIR"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    local name
    name=$(basename "$skill_dir")
    rm -rf "$CLAUDE_DIR/skills/$name"
    cp -R "$skill_dir" "$CLAUDE_DIR/skills/$name"
    ((count++))
  done
  ok "$count skill(s) installed to ~/.claude/skills/"
}

# ── CLAUDE.md assembly ───────────────────────────────────────────
assemble_claude_md() {
  local profile="$1" github_user="${2:-}" hide_ai="${3:-no}"
  local output="$CLAUDE_DIR/CLAUDE.md"

  # Start with base
  cp "$DOTFILES_DIR/base/CLAUDE.md" "$output"

  # Replace git commit policy placeholder
  local policy
  if [ "$hide_ai" = "yes" ] && [ -n "$github_user" ]; then
    policy=$(cat <<POLICY
**CRITICAL**: For all repositories owned by @${github_user}:

- **NEVER** include AI attribution in commit messages
- **NEVER** add "Generated with Claude Code" footers
- **NEVER** add "Co-Authored-By: Claude <noreply@anthropic.com>"
- Keep all commits appearing as natural developer work
- Use clean, professional commit messages only

This policy applies to all git operations including:

- Direct commits via Bash tool
- Pull request creation via gh pr create
- Commit message suggestions
- Any automated git workflows
POLICY
    )
  elif [ -n "$github_user" ]; then
    policy="Use clean, professional commit messages. Follow the repository's existing commit style."
  else
    policy="Use clean, professional commit messages. Follow the repository's existing commit style."
  fi

  # Use awk to replace the placeholder (handles multiline)
  local escaped_policy
  escaped_policy=$(echo "$policy" | awk '{printf "%s\\n", $0}' | sed 's/&/\\&/g')
  awk -v policy="$escaped_policy" '{
    if ($0 ~ /\{\{GIT_COMMIT_POLICY\}\}/) {
      # Split policy on \n and print each line
      n = split(policy, lines, "\\n")
      for (i = 1; i <= n; i++) {
        print lines[i]
      }
    } else {
      print
    }
  }' "$output" > "${output}.tmp" && mv "${output}.tmp" "$output"

  # Append profile-specific CLAUDE.md
  local profile_md="$DOTFILES_DIR/profiles/$profile/CLAUDE.md"
  if [ -f "$profile_md" ]; then
    echo "" >> "$output"
    cat "$profile_md" >> "$output"
  fi

  # Append local overlay if it exists
  local local_md="$DOTFILES_DIR/.local/CLAUDE.md"
  if [ -f "$local_md" ]; then
    echo "" >> "$output"
    cat "$local_md" >> "$output"
  fi

  ok "CLAUDE.md assembled (base + $profile$([ -f "$local_md" ] && echo " + local"))"
}

# ── Commands ──────────────────────────────────────────────────────

cmd_setup() {
  echo ""
  echo -e "${BOLD}${CYAN}  Claude Code Dotfiles Setup${RESET}"
  echo -e "${DIM}  ─────────────────────────────────${RESET}"
  echo ""

  local os
  os=$(detect_os)
  ok "Detected: $os ($(uname -s))"
  check_prereq

  # Check if Claude Code is installed
  if command -v claude &>/dev/null; then
    ok "Claude Code installed"
  else
    warn "Claude Code not found - install it first, then re-run"
    echo "    npm install -g @anthropic-ai/claude-code"
  fi

  # ── Profile selection ──
  header "Machine type"
  echo -e "  ${BOLD}1${RESET}) Desktop (macOS / Linux GUI)"
  echo -e "  ${BOLD}2${RESET}) VPS / headless server"
  echo -n "  > "
  read -r profile_choice

  local profile
  case "${profile_choice:-1}" in
    2) profile="vps" ;;
    *) profile="desktop" ;;
  esac
  ok "Profile: $profile"

  # ── Personalization ──
  header "Personalization"

  echo -ne "  GitHub username (for commit policy, or Enter to skip): "
  read -r github_user

  local hide_ai="no"
  if [ -n "$github_user" ]; then
    ok "GitHub: @$github_user"
    echo -ne "  Hide AI attribution in commits? (y/N): "
    read -r hide_ai_choice
    case "${hide_ai_choice:-n}" in
      y|Y|yes) hide_ai="yes"; ok "AI attribution will be hidden" ;;
      *) hide_ai="no"; skip "Standard commit messages" ;;
    esac
  else
    skip "GitHub username skipped"
  fi

  # ── Link portable files ──
  header "Linking configuration files..."

  mkdir -p "$CLAUDE_DIR/scripts"
  mkdir -p "$CLAUDE_DIR/.backups"
  mkdir -p "$CLAUDE_DIR/.changelog"
  mkdir -p "$CLAUDE_DIR/references"

  # Copy reference files
  for ref in "$DOTFILES_DIR"/references/*.md; do
    [ -f "$ref" ] || continue
    cp "$ref" "$CLAUDE_DIR/references/$(basename "$ref")"
  done
  ok "Reference files copied to ~/.claude/references/"

  # Install repo-owned skills
  install_skills

  # Assemble CLAUDE.md from layers
  assemble_claude_md "$profile" "$github_user" "$hide_ai"

  # Link profile-specific settings.json
  link_file "$DOTFILES_DIR/profiles/$profile/settings.json" "$CLAUDE_DIR/settings.json"

  # Link statusline
  link_file "$DOTFILES_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  chmod +x "$CLAUDE_DIR/statusline.sh"

  # Link scripts
  for script in "$DOTFILES_DIR"/scripts/*.sh; do
    [ -f "$script" ] || continue
    link_file "$script" "$CLAUDE_DIR/scripts/$(basename "$script")"
    chmod +x "$CLAUDE_DIR/scripts/$(basename "$script")"
  done

  # ── Create .env if missing ──
  if [ ! -f "$CLAUDE_DIR/.env" ]; then
    cp "$DOTFILES_DIR/.env.example" "$CLAUDE_DIR/.env"
    chmod 600 "$CLAUDE_DIR/.env"
    ok "Created ~/.claude/.env (add API keys here)"
  else
    skip ".env already exists (kept as-is)"
  fi

  # ── Create .local/CLAUDE.md from template if missing ──
  if [ ! -f "$DOTFILES_DIR/.local/CLAUDE.md" ]; then
    cp "$DOTFILES_DIR/examples/local-CLAUDE.md" "$DOTFILES_DIR/.local/CLAUDE.md"
    ok ".local/CLAUDE.md created from template (customize it!)"
  else
    skip ".local/CLAUDE.md already exists"
  fi

  # ── Save profile choice for future updates ──
  echo "$profile" > "$DOTFILES_DIR/.local/.profile"
  echo "$github_user" > "$DOTFILES_DIR/.local/.github-user"
  echo "$hide_ai" > "$DOTFILES_DIR/.local/.hide-ai"

  # ── Projects workspace ──
  # A home for the user's code, so newcomers have somewhere to build.
  header "Projects workspace"
  local projects_dir="$HOME/Developer/Git"
  if [ -d "$projects_dir" ]; then
    skip "Projects directory exists: $projects_dir"
  else
    mkdir -p "$projects_dir"
    ok "Created projects directory: $projects_dir (your code lives here)"
  fi

  # ── MCP Integration selection ──
  header "MCP Integrations"
  echo -e "  These extend Claude Code with external tools."
  echo -e "  ${DIM}Press Enter to skip all, or pick by number.${RESET}"
  echo ""

  local i=1
  local names=()
  local visible_indices=()
  for idx in "${!INTEGRATIONS[@]}"; do
    local entry="${INTEGRATIONS[$idx]}"
    local name desc needs_key desktop_only
    name=$(get_field "$entry" 1)
    desc=$(get_field "$entry" 2)
    needs_key=$(get_field "$entry" 3)
    desktop_only=$(get_field "$entry" 7)

    # Skip desktop-only integrations on VPS
    if [ "$profile" = "vps" ] && [ "$desktop_only" = "yes" ]; then
      continue
    fi

    names+=("$name")
    visible_indices+=("$idx")

    local tag=""
    if [ "$needs_key" = "yes" ]; then
      tag="${DIM}[needs API key]${RESET}"
    else
      tag="${GREEN}[ready]${RESET}"
    fi

    printf "  ${BOLD}%2d${RESET}) %-20s %s %s\n" "$i" "$name" "$desc" "$tag"
    ((i++))
  done

  echo ""
  echo -e "  ${DIM}Examples: 1,2,3  |  1-5  |  all  |  Enter to skip${RESET}"
  echo -n "  > "
  read -r selection

  # ── Parse selection ──
  local selected=()
  if [ -z "$selection" ]; then
    skip "Skipped integrations (run './setup.sh add <name>' later)"
  elif [ "$selection" = "all" ]; then
    for ((j=0; j<${#visible_indices[@]}; j++)); do
      selected+=("$j")
    done
  else
    # Parse comma-separated numbers and ranges like "1,2,5-8"
    IFS=',' read -ra parts <<< "$selection"
    for part in "${parts[@]}"; do
      part=$(echo "$part" | tr -d ' ')
      if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
        for ((n=start; n<=end; n++)); do
          [ "$n" -ge 1 ] && [ "$n" -le "${#visible_indices[@]}" ] && selected+=("$((n-1))")
        done
      elif [[ "$part" =~ ^[0-9]+$ ]]; then
        [ "$part" -ge 1 ] && [ "$part" -le "${#visible_indices[@]}" ] && selected+=("$((part-1))")
      fi
    done
  fi

  # ── Configure selected integrations ──
  if [ ${#selected[@]} -gt 0 ]; then
    ensure_claude_json
    echo ""
    local enabled_count=0

    for sel_idx in "${selected[@]}"; do
      local real_idx="${visible_indices[$sel_idx]}"
      local entry="${INTEGRATIONS[$real_idx]}"
      local name desc needs_key key_var disabled_default extra_vars
      name=$(get_field "$entry" 1)
      desc=$(get_field "$entry" 2)
      needs_key=$(get_field "$entry" 3)
      key_var=$(get_field "$entry" 4)
      disabled_default=$(get_field "$entry" 5)
      extra_vars=$(get_field "$entry" 6)

      local key_val="" extra_val="" should_disable="false"

      if [ "$needs_key" = "yes" ]; then
        echo -ne "  ${BOLD}${name}${RESET} - ${key_var}: "
        read -r key_val

        if [ -z "$key_val" ]; then
          # No key provided - install disabled
          should_disable="true"
          local json
          json=$(mcp_json_for "$name" "PLACEHOLDER" "")
          set_mcp_server "$name" "$json" "true"
          skip "${name} added (disabled - no key yet)"
          continue
        fi

        # Check for extra vars (URL etc)
        if [ -n "$extra_vars" ]; then
          echo -ne "  ${BOLD}${name}${RESET} - ${extra_vars}: "
          read -r extra_val
        fi
      fi

      local json
      json=$(mcp_json_for "$name" "$key_val" "$extra_val")

      if [ "$disabled_default" = "yes" ] && [ "$needs_key" != "yes" ]; then
        should_disable="true"
      fi

      set_mcp_server "$name" "$json" "$should_disable"

      if [ "$should_disable" = "true" ]; then
        ok "${name} added (disabled by default - enable in ~/.claude.json)"
      else
        ok "${name} enabled"
        ((enabled_count++))
      fi
    done

    echo ""
    ok "${enabled_count} integration(s) active. Others added as disabled."
  fi

  # ── Plugin stack ──
  header "Agentic plugin stack"
  echo -e "  Installs the plugins that power the workflow (superpowers, ui-ux-pro-max,"
  echo -e "  feature-dev, code-review, claude-mem, agent-browser, codex, and more)."
  echo -e "  ${DIM}Core auto-installs; optional plugins are opt-in. Reversible anytime.${RESET}"
  echo -ne "  Install the plugin stack now? (Y/n): "
  read -r plugins_choice
  case "${plugins_choice:-y}" in
    n|N|no) skip "Skipped (run ./scripts/bootstrap-plugins.sh later)" ;;
    *) "$DOTFILES_DIR/scripts/bootstrap-plugins.sh" || warn "Plugin bootstrap had issues — re-run ./scripts/bootstrap-plugins.sh" ;;
  esac

  # ── Summary ──
  header "Setup complete!"
  echo ""
  echo -e "  Profile:  ${CYAN}${profile}${RESET}"
  echo -e "  Config:   ${CYAN}${DOTFILES_DIR}${RESET}"
  echo -e "  ${DIM}Edit the source files in the repo, changes reflect immediately.${RESET}"
  echo -e "  ${DIM}Note: CLAUDE.md is assembled (not symlinked). Run './setup.sh update' after edits.${RESET}"
  echo ""
  echo -e "  ${BOLD}${CYAN}New here? Open Claude Code and say: ${RESET}${BOLD}help me get started${RESET}"
  echo -e "  ${DIM}Or read GETTING-STARTED.md for the full walkthrough.${RESET}"
  echo ""
  echo -e "  ${BOLD}Next steps:${RESET}"
  echo -e "    ${DIM}Add API keys:${RESET}    ./setup.sh add firecrawl"
  echo -e "    ${DIM}List status:${RESET}     ./setup.sh list"
  echo -e "    ${DIM}Edit env vars:${RESET}   vim ~/.claude/.env"
  echo -e "    ${DIM}Local config:${RESET}    vim .local/CLAUDE.md"
  echo -e "    ${DIM}Rebuild config:${RESET}  ./setup.sh update"
  echo ""
}

cmd_add() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "Usage: ./setup.sh add <integration-name>"
    echo "Run './setup.sh list' to see available integrations."
    exit 1
  fi

  # Find the integration
  local found=""
  for entry in "${INTEGRATIONS[@]}"; do
    local entry_name
    entry_name=$(get_field "$entry" 1)
    if [ "$entry_name" = "$name" ]; then
      found="$entry"
      break
    fi
  done

  if [ -z "$found" ]; then
    fail "Unknown integration: $name"
    echo "  Run './setup.sh list' to see available integrations."
    exit 1
  fi

  local desc needs_key key_var extra_vars
  desc=$(get_field "$found" 2)
  needs_key=$(get_field "$found" 3)
  key_var=$(get_field "$found" 4)
  extra_vars=$(get_field "$found" 6)

  ensure_claude_json

  local key_val="" extra_val=""

  if [ "$needs_key" = "yes" ]; then
    echo -ne "${BOLD}${name}${RESET} - ${desc}\n"
    echo -ne "  ${key_var}: "
    read -r key_val

    if [ -z "$key_val" ]; then
      fail "API key required for $name"
      exit 1
    fi

    if [ -n "$extra_vars" ]; then
      echo -ne "  ${extra_vars}: "
      read -r extra_val
    fi
  fi

  local json
  json=$(mcp_json_for "$name" "$key_val" "$extra_val")
  set_mcp_server "$name" "$json" "false"
  ok "${name} enabled!"
}

cmd_list() {
  header "MCP Integrations"

  # Read saved profile
  local profile="desktop"
  if [ -f "$DOTFILES_DIR/.local/.profile" ]; then
    profile=$(cat "$DOTFILES_DIR/.local/.profile")
  fi

  local i=1
  for entry in "${INTEGRATIONS[@]}"; do
    local name desc needs_key desktop_only
    name=$(get_field "$entry" 1)
    desc=$(get_field "$entry" 2)
    needs_key=$(get_field "$entry" 3)
    desktop_only=$(get_field "$entry" 7)

    # Mark desktop-only on VPS
    local profile_tag=""
    if [ "$profile" = "vps" ] && [ "$desktop_only" = "yes" ]; then
      profile_tag=" ${DIM}(desktop only)${RESET}"
    fi

    local mcp_key status_icon
    mcp_key=$(mcp_key_for "$name")

    if [ -f "$CLAUDE_JSON" ]; then
      local exists disabled
      exists=$(jq -r --arg k "$mcp_key" '.mcpServers[$k] // empty' "$CLAUDE_JSON")
      if [ -n "$exists" ]; then
        disabled=$(jq -r --arg k "$mcp_key" '.mcpServers[$k].disabled // false' "$CLAUDE_JSON")
        if [ "$disabled" = "true" ]; then
          status_icon="${YELLOW}○${RESET} disabled"
        else
          status_icon="${GREEN}●${RESET} active  "
        fi
      else
        status_icon="${DIM}·${RESET} not added"
      fi
    else
      status_icon="${DIM}·${RESET} not added"
    fi

    printf "  %2d) %-20s %s  %b%b\n" "$i" "$name" "$desc" "$status_icon" "$profile_tag"
    ((i++))
  done

  echo ""
  echo -e "  ${DIM}Profile: ${profile}${RESET}"
  echo -e "  ${DIM}Enable:  ./setup.sh add <name>${RESET}"
  echo -e "  ${DIM}Config:  ~/.claude.json${RESET}"
}

cmd_update() {
  header "Updating..."
  cd "$DOTFILES_DIR"
  git pull --rebase 2>/dev/null && ok "Pulled latest changes" || warn "Git pull failed (not a git repo?)"

  # Read saved preferences
  local profile="desktop" github_user="" hide_ai="no"
  if [ -f "$DOTFILES_DIR/.local/.profile" ]; then
    profile=$(cat "$DOTFILES_DIR/.local/.profile")
  fi
  if [ -f "$DOTFILES_DIR/.local/.github-user" ]; then
    github_user=$(cat "$DOTFILES_DIR/.local/.github-user")
  fi
  if [ -f "$DOTFILES_DIR/.local/.hide-ai" ]; then
    hide_ai=$(cat "$DOTFILES_DIR/.local/.hide-ai")
  fi

  # Update reference files
  mkdir -p "$CLAUDE_DIR/references"
  for ref in "$DOTFILES_DIR"/references/*.md; do
    [ -f "$ref" ] || continue
    cp "$ref" "$CLAUDE_DIR/references/$(basename "$ref")"
  done
  ok "Reference files updated"

  # Re-install repo-owned skills
  install_skills

  # Reassemble CLAUDE.md
  assemble_claude_md "$profile" "$github_user" "$hide_ai"

  # Re-link settings and scripts
  link_file "$DOTFILES_DIR/profiles/$profile/settings.json" "$CLAUDE_DIR/settings.json"
  link_file "$DOTFILES_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  chmod +x "$CLAUDE_DIR/statusline.sh"

  for script in "$DOTFILES_DIR"/scripts/*.sh; do
    [ -f "$script" ] || continue
    link_file "$script" "$CLAUDE_DIR/scripts/$(basename "$script")"
    chmod +x "$CLAUDE_DIR/scripts/$(basename "$script")"
  done

  ok "Update complete (profile: $profile)"
}

cmd_env() {
  local key="${1:-}" val="${2:-}"
  if [ -z "$key" ]; then
    echo "Usage: ./setup.sh env KEY_NAME [value]"
    echo "  If no value given, prompts for it."
    exit 1
  fi

  if [ -z "$val" ]; then
    echo -ne "  ${BOLD}${key}${RESET}: "
    read -r val
  fi

  if [ -z "$val" ]; then
    fail "No value provided"
    exit 1
  fi

  local env_file="$CLAUDE_DIR/.env"
  touch "$env_file"
  chmod 600 "$env_file"

  # Update or append
  if grep -q "^${key}=" "$env_file" 2>/dev/null; then
    sed_inplace "s|^${key}=.*|${key}=${val}|" "$env_file"
    ok "Updated ${key} in ~/.claude/.env"
  else
    echo "${key}=${val}" >> "$env_file"
    ok "Added ${key} to ~/.claude/.env"
  fi
}

# ── Main ──────────────────────────────────────────────────────────
case "${1:-}" in
  add)    cmd_add "${2:-}" ;;
  list)   cmd_list ;;
  update) cmd_update ;;
  env)    cmd_env "${2:-}" "${3:-}" ;;
  help|--help|-h)
    echo "Claude Code Dotfiles Setup"
    echo ""
    echo "Usage:"
    echo "  ./setup.sh              Initial setup (profile + integrations)"
    echo "  ./setup.sh add <name>   Add/enable a single MCP integration"
    echo "  ./setup.sh list         Show all integrations and their status"
    echo "  ./setup.sh env KEY [v]  Add an API key to ~/.claude/.env"
    echo "  ./setup.sh update       Pull latest and reassemble config"
    echo "  ./setup.sh help         Show this help"
    ;;
  *)      cmd_setup ;;
esac
