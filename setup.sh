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
SERENA_CONFIG="$HOME/.serena/serena_config.yml"

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

# Postgres MCP package for self-hosted ("internal") Supabase. The old reference
# server @modelcontextprotocol/server-postgres is deprecated; this one is
# maintained and npx-native. Swap here if you ever need a different server.
SUPABASE_PG_MCP_PKG="@henkey/postgres-mcp-server"

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
    supabase)
      # Internal/self-hosted only — direct Postgres MCP; key_val = connection string.
      # (Cloud Supabase uses the plugin's hosted MCP instead — see configure_supabase.)
      echo "{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"${SUPABASE_PG_MCP_PKG}\"],\"env\":{\"POSTGRES_CONNECTION_STRING\":\"${key_val}\"}}";;
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

# ── Dependency installation (OS-aware) ───────────────────────────
# setup.sh assumes a handful of tools exist (jq/git/curl for the script itself;
# node/npm for Claude Code + npx MCP servers; gh/bun/uv per the tool-priority
# guide). Rather than fail when they're missing, install them for the two
# supported platforms: Ubuntu/Debian (apt) and macOS (Homebrew). Everything
# else is best-effort — a failed install warns and continues so the rest of
# setup still runs.
PKG_MANAGER=""          # apt | brew | unknown
SUDO=""                 # "sudo" when needed & available, else empty
APT_UPDATED="no"        # run `apt-get update` at most once

detect_pkg_manager() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    PKG_MANAGER="brew"
  elif command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
  else
    PKG_MANAGER="unknown"
  fi
  if [ "$(id -u)" -ne 0 ] && command -v sudo &>/dev/null; then
    SUDO="sudo"
  fi
}

apt_update_once() {
  if [ "$PKG_MANAGER" = "apt" ] && [ "$APT_UPDATED" = "no" ]; then
    $SUDO apt-get update -y >/dev/null 2>&1 || true
    APT_UPDATED="yes"
  fi
}

# Install one or more packages via the detected package manager.
pkg_install() {
  case "$PKG_MANAGER" in
    brew) brew install "$@" ;;
    apt)  apt_update_once; $SUDO apt-get install -y "$@" ;;
    *)    return 1 ;;
  esac
}

# No-sudo gh fallback: drop the release binary into ~/.local/bin.
gh_install_binary() {
  local arch os tag ver
  case "$(uname -m)" in
    x86_64)        arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)             arch="amd64" ;;
  esac
  os="linux"; [ "$(uname -s)" = "Darwin" ] && os="macOS"
  tag=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name')
  [ -n "$tag" ] && [ "$tag" != "null" ] || return 1
  ver="${tag#v}"
  mkdir -p "$HOME/.local/bin"
  curl -fsSL "https://github.com/cli/cli/releases/download/${tag}/gh_${ver}_${os}_${arch}.tar.gz" -o /tmp/gh.tgz || return 1
  tar xzf /tmp/gh.tgz -C /tmp || return 1
  cp "/tmp/gh_${ver}_${os}_${arch}/bin/gh" "$HOME/.local/bin/gh"
  chmod +x "$HOME/.local/bin/gh"
  rm -rf /tmp/gh.tgz "/tmp/gh_${ver}_${os}_${arch}"
}

ensure_node() {
  if command -v node &>/dev/null && command -v npm &>/dev/null; then
    ok "node $(node -v) present"; return 0
  fi
  warn "node/npm missing — installing..."
  case "$PKG_MANAGER" in
    brew) brew install node ;;
    apt)  # apt's nodejs is often stale; use NodeSource LTS.
      curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash - >/dev/null 2>&1 \
        && $SUDO apt-get install -y nodejs ;;
  esac
  command -v node &>/dev/null && ok "node $(node -v) installed" \
    || fail "node install failed — install manually, then re-run"
}

ensure_gh() {
  command -v gh &>/dev/null && { ok "gh present"; return 0; }
  warn "gh (GitHub CLI) missing — installing..."
  case "$PKG_MANAGER" in
    brew) brew install gh ;;
    apt)
      if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ]; then
        $SUDO mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        $SUDO apt-get update -y >/dev/null 2>&1 && $SUDO apt-get install -y gh
      else
        gh_install_binary   # no root: fall back to ~/.local/bin binary
      fi ;;
  esac
  command -v gh &>/dev/null || [ -x "$HOME/.local/bin/gh" ] \
    && ok "gh installed" || fail "gh install failed — install manually"
}

ensure_bun() {
  command -v bun &>/dev/null && { ok "bun present"; return 0; }
  warn "bun missing — installing (official installer → ~/.bun)..."
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 \
    && ok "bun installed (open a new shell to pick it up)" \
    || fail "bun install failed — see https://bun.sh"
}

ensure_uv() {
  command -v uv &>/dev/null && { ok "uv present"; return 0; }
  warn "uv missing — installing (official installer → ~/.local/bin)..."
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
    && ok "uv installed (open a new shell to pick it up)" \
    || fail "uv install failed — see https://astral.sh/uv"
}

ensure_claude() {
  command -v claude &>/dev/null && { ok "Claude Code installed"; return 0; }
  warn "Claude Code missing — installing via npm..."
  if command -v npm &>/dev/null; then
    npm install -g @anthropic-ai/claude-code >/dev/null 2>&1 \
      || $SUDO npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
    command -v claude &>/dev/null && ok "Claude Code installed" \
      || fail "Claude Code install failed — run: npm install -g @anthropic-ai/claude-code"
  else
    fail "npm unavailable — cannot install Claude Code"
  fi
}

# Serena opens a browser dashboard tab on every `start-mcp-server` launch by
# default. The global config is the single control point that all launchers
# (the serena plugin included) honor, so disable it there — this is what stops
# the popup reproducibly on a fresh machine. Serena fills every other key with
# its own defaults, so a minimal seed file is safe.
ensure_serena_dashboard_off() {
  mkdir -p "$(dirname "$SERENA_CONFIG")"

  if [ ! -f "$SERENA_CONFIG" ]; then
    cat > "$SERENA_CONFIG" <<'YAML'
# Seeded by setup.sh. Serena fills all other keys with defaults; edit freely.
gui_log_window: false
web_dashboard: false
web_dashboard_open_on_launch: false
YAML
    ok "Serena dashboard disabled (created $SERENA_CONFIG)"
    return 0
  fi

  local changed="no" key tmp
  for key in gui_log_window web_dashboard web_dashboard_open_on_launch; do
    grep -qE "^${key}:[[:space:]]*false" "$SERENA_CONFIG" && continue
    if grep -qE "^${key}:" "$SERENA_CONFIG"; then
      tmp=$(mktemp)
      sed -E "s/^${key}:.*/${key}: false/" "$SERENA_CONFIG" > "$tmp" && mv "$tmp" "$SERENA_CONFIG"
    else
      printf '%s: false\n' "$key" >> "$SERENA_CONFIG"
    fi
    changed="yes"
  done
  [ "$changed" = "yes" ] \
    && ok "Serena dashboard disabled ($SERENA_CONFIG)" \
    || ok "Serena dashboard already disabled"
}

# Ensure every tool the dotfiles assume is present, installing what's missing.
ensure_dependencies() {
  header "Dependencies"
  detect_pkg_manager

  if [ "$PKG_MANAGER" = "unknown" ]; then
    warn "Unsupported OS (only Ubuntu/Debian + macOS auto-install)."
    warn "Install manually: jq git curl gh node bun uv, then Claude Code."
    check_prereq   # still hard-fail if the script's own basics are absent
    return 0
  fi
  ok "Package manager: $PKG_MANAGER${SUDO:+ (using sudo)}"

  # Script's own hard requirements.
  for tool in git curl jq; do
    if command -v "$tool" &>/dev/null; then
      ok "$tool present"
    else
      warn "$tool missing — installing..."
      pkg_install "$tool" && ok "$tool installed" \
        || { fail "$tool is required and could not be installed"; exit 1; }
    fi
  done

  # Assumed tooling (best-effort; warns but continues on failure).
  ensure_node    # Claude Code + npx MCP servers
  ensure_gh      # GitHub CLI (tool-priority default)
  ensure_bun     # JS/TS package manager
  ensure_uv      # Python package manager (serena runs via uvx)
  ensure_claude  # Claude Code itself
  ensure_serena_dashboard_off  # suppress serena's browser dashboard popup
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

remove_mcp_server() {
  local mcp_key
  mcp_key=$(mcp_key_for "$1")
  [ -f "$CLAUDE_JSON" ] || return 0
  jq -e --arg k "$mcp_key" '.mcpServers[$k]' "$CLAUDE_JSON" &>/dev/null || return 0
  local tmp
  tmp=$(jq --arg k "$mcp_key" 'del(.mcpServers[$k])' "$CLAUDE_JSON")
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

# ── Settings installation ────────────────────────────────────────
# Claude Code refuses to read feature flags when any of DISABLE_TELEMETRY,
# DO_NOT_TRACK, or CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is set, which
# silently disables Remote Control (/rc) even for eligible accounts — see
# issue #4 and anthropics/claude-code#76748. When the user opts into Remote
# Control, install a stripped COPY of the profile settings instead of the
# usual symlink (stripping through the symlink would dirty the repo). The
# choice lives in .local/.remote-control and './setup.sh update' re-applies it.
install_settings() {
  local profile="$1" remote_control="${2:-no}"
  local src="$DOTFILES_DIR/profiles/$profile/settings.json"
  local dst="$CLAUDE_DIR/settings.json"

  if [ "$remote_control" != "yes" ]; then
    link_file "$src" "$dst"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  if [ -L "$dst" ]; then
    rm "$dst"
  elif [ -f "$dst" ]; then
    local backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_dir/settings.json"
    warn "Backed up existing settings.json to $backup_dir/"
    rm "$dst"
  fi
  jq 'del(.env.DISABLE_TELEMETRY, .env.DO_NOT_TRACK, .env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)' "$src" > "$dst"
  ok "settings.json copied with telemetry opt-out stripped (Remote Control works; re-run './setup.sh update' after profile edits)"
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
    count=$((count+1))
  done
  ok "$count skill(s) installed to ~/.claude/skills/"
}

# ── CLAUDE.md assembly ───────────────────────────────────────────
assemble_claude_md() {
  local profile="$1" github_user="${2:-}" hide_ai="${3:-no}"
  local final="$CLAUDE_DIR/CLAUDE.md"
  local output
  output="$(mktemp)"   # assemble off to the side, then swap in atomically

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

  # Finalize: back up an existing CLAUDE.md before replacing it — but only when
  # the regenerated content actually differs, so repeated `./setup.sh update`
  # runs don't spawn no-op backups. Mirrors the backup contract that link_file
  # and install_settings already honor for the other ~/.claude files.
  chmod 0644 "$output"
  mkdir -p "$CLAUDE_DIR"
  if [ -f "$final" ] && ! cmp -s "$output" "$final"; then
    local backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$final" "$backup_dir/CLAUDE.md"
    warn "Backed up existing CLAUDE.md to $backup_dir/"
  fi
  mv "$output" "$final"

  ok "CLAUDE.md assembled (base + $profile$([ -f "$local_md" ] && echo " + local"))"
}

# ── Unify agent instructions: AGENTS.md -> CLAUDE.md ─────────────
# Single source of truth for the agent CLIs we run alongside Claude Code
# (codex-cli, cursor-cli, opencode, gemini-cli). Claude and Cursor read CLAUDE.md
# natively; Codex and opencode read AGENTS.md; Gemini reads GEMINI.md. Symlinking
# each tool's global instructions file to CLAUDE.md shares the one assembled file
# with no duplication.
#   ~/.codex/AGENTS.md            Codex global instructions
#   ~/.config/opencode/AGENTS.md  opencode global instructions
#   ~/.gemini/GEMINI.md           Gemini global instructions
#   ~/AGENTS.md                   home-level file Cursor resolves when run near $HOME
# link_file backs up any existing real file to ~/.claude/.backups/ before linking
# and is idempotent (a stale symlink is replaced, not nested).
link_agent_instructions() {
  local canonical="$CLAUDE_DIR/CLAUDE.md"
  [ -f "$canonical" ] || { warn "CLAUDE.md not found; skipping agent-instruction symlinks"; return 0; }
  link_file "$canonical" "$HOME/.codex/AGENTS.md"
  link_file "$canonical" "$HOME/.config/opencode/AGENTS.md"
  link_file "$canonical" "$HOME/.gemini/GEMINI.md"
  link_file "$canonical" "$HOME/AGENTS.md"
  link_codex_prompts
  link_claude_hooks
}

# Claude Code hooks (hooks/*.sh -> ~/.claude/hooks/<name>). The shared
# profile settings.json references these by $HOME path, so a machine that
# skips this step gets a "No such file or directory" PreToolUse error on
# every Bash call. Symlinked so a repo pull updates the live hooks.
link_claude_hooks() {
  [ -d "$DOTFILES_DIR/hooks" ] || return 0
  local f
  for f in "$DOTFILES_DIR"/hooks/*.sh; do
    [ -f "$f" ] || continue
    link_file "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"
  done
}

# Codex custom prompts (codex/prompts/*.md -> ~/.codex/prompts/<name>.md,
# typed as /<name> in the Codex TUI). Symlinked, not copied, so a repo pull
# updates the live prompts — the Claude-side equivalents live in skills/.
link_codex_prompts() {
  [ -d "$DOTFILES_DIR/codex/prompts" ] || return 0
  local f
  for f in "$DOTFILES_DIR"/codex/prompts/*.md; do
    [ -f "$f" ] || continue
    link_file "$f" "$HOME/.codex/prompts/$(basename "$f")"
  done
}

# ── Supabase: Cloud vs internal (self-hosted) ────────────────────
# Cloud uses the `supabase` plugin's own hosted MCP (mcp.supabase.com, OAuth) —
# nothing for us to wire. Internal can't use that (it's Cloud-only), so we
# register a direct Postgres MCP against the self-hosted DB. The chosen mode is
# saved to .local/.supabase-mode so './setup.sh update' re-applies the same fork
# non-interactively (the connection string is preserved from ~/.claude.json).
configure_supabase() {
  local mode="${1:-}"   # ""→prompt; else cloud|internal|skip

  if [ -z "$mode" ]; then
    header "Supabase"
    echo -e "  Which Supabase does this machine use?"
    echo -e "    ${BOLD}1${RESET}) Cloud     ${DIM}supabase.com — uses the plugin's hosted MCP (OAuth)${RESET}"
    echo -e "    ${BOLD}2${RESET}) Internal  ${DIM}self-hosted — direct Postgres MCP to your DB${RESET}"
    echo -e "    ${BOLD}3${RESET}) Skip"
    echo -n "  > "
    read -r sb_choice || sb_choice=""
    case "${sb_choice:-3}" in
      1) mode="cloud" ;;
      2) mode="internal" ;;
      *) mode="skip" ;;
    esac
  fi

  ensure_claude_json

  case "$mode" in
    cloud)
      remove_mcp_server supabase   # drop any stale internal Postgres MCP
      ok "Supabase: Cloud (plugin's hosted MCP — run its OAuth once inside Claude Code)"
      ;;
    internal)
      # Reuse a stored connection string if present, else prompt for it.
      local db_url
      db_url=$(jq -r '.mcpServers.supabase.env.POSTGRES_CONNECTION_STRING // empty' "$CLAUDE_JSON" 2>/dev/null || true)
      if [ -z "$db_url" ]; then
        echo -ne "  ${BOLD}Connection string${RESET} ${DIM}(postgresql://postgres:<pw>@your-db-host:5432/postgres)${RESET}: "
        read -r db_url || db_url=""
      fi
      if [ -z "$db_url" ]; then
        warn "No connection string — internal Supabase MCP not configured."
        warn "Set it later:  ./setup.sh supabase internal"
      else
        local json
        json=$(mcp_json_for supabase "$db_url" "")
        set_mcp_server supabase "$json" "false"
        ok "Supabase: internal (Postgres MCP → self-hosted DB)"
      fi
      ;;
    skip)
      skip "Supabase configuration skipped"
      ;;
    *)
      warn "Unknown Supabase mode: '$mode' (expected cloud|internal|skip)"
      return 0
      ;;
  esac

  mkdir -p "$DOTFILES_DIR/.local"
  echo "$mode" > "$DOTFILES_DIR/.local/.supabase-mode"
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

  # Ensure prerequisites & assumed tooling are installed (OS-aware).
  ensure_dependencies

  # ── Profile selection ──
  header "Machine type"
  echo -e "  ${BOLD}1${RESET}) Desktop (macOS / Linux GUI)"
  echo -e "  ${BOLD}2${RESET}) VPS / headless server"
  echo -n "  > "
  read -r profile_choice || profile_choice=""

  local profile
  case "${profile_choice:-1}" in
    2) profile="vps" ;;
    *) profile="desktop" ;;
  esac
  ok "Profile: $profile"

  # ── Personalization ──
  header "Personalization"

  echo -ne "  GitHub username (for commit policy, or Enter to skip): "
  read -r github_user || github_user=""

  local hide_ai="no"
  if [ -n "$github_user" ]; then
    ok "GitHub: @$github_user"
    echo -ne "  Hide AI attribution in commits? (y/N): "
    read -r hide_ai_choice || hide_ai_choice=""
    case "${hide_ai_choice:-n}" in
      y|Y|yes) hide_ai="yes"; ok "AI attribution will be hidden" ;;
      *) hide_ai="no"; skip "Standard commit messages" ;;
    esac
  else
    skip "GitHub username skipped"
  fi

  # ── Remote Control vs telemetry opt-out (desktop profile only) ──
  local remote_control="no"
  if [ "$profile" = "desktop" ]; then
    header "Remote Control"
    echo -e "  The desktop profile disables Claude Code telemetry (DISABLE_TELEMETRY,"
    echo -e "  DO_NOT_TRACK, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC). Claude Code also"
    echo -e "  gates feature-flag reads behind these vars, which silently disables"
    echo -e "  Remote Control (/rc) and other flag-gated features. ${DIM}Details in README.${RESET}"
    echo -ne "  Do you use Remote Control? Strips the opt-out vars (y/N): "
    read -r rc_choice || rc_choice=""
    case "${rc_choice:-n}" in
      y|Y|yes) remote_control="yes"; ok "Remote Control enabled (telemetry opt-out will be stripped)" ;;
      *) skip "Keeping telemetry opt-out (Remote Control stays unavailable)" ;;
    esac
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

  # Point Codex/Cursor at the same instructions (AGENTS.md -> CLAUDE.md)
  link_agent_instructions

  # Install profile-specific settings.json (symlink, or stripped copy for Remote Control)
  install_settings "$profile" "$remote_control"

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
  mkdir -p "$DOTFILES_DIR/.local"
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
  echo "$remote_control" > "$DOTFILES_DIR/.local/.remote-control"

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
    i=$((i+1))
  done

  echo ""
  echo -e "  ${DIM}Examples: 1,2,3  |  1-5  |  all  |  Enter to skip${RESET}"
  echo -n "  > "
  read -r selection || selection=""

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
        read -r key_val || key_val=""

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
          read -r extra_val || extra_val=""
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
        enabled_count=$((enabled_count+1))
      fi
    done

    echo ""
    ok "${enabled_count} integration(s) active. Others added as disabled."
  fi

  # ── Supabase: Cloud vs internal ──
  configure_supabase ""

  # ── Plugin stack ──
  header "Agentic plugin stack"
  echo -e "  Installs the plugins that power the workflow (superpowers, ui-ux-pro-max,"
  echo -e "  feature-dev, code-review, claude-mem, agent-browser, codex, and more)."
  echo -e "  ${DIM}Core auto-installs; optional plugins are opt-in. Reversible anytime.${RESET}"
  echo -ne "  Install the plugin stack now? (Y/n): "
  read -r plugins_choice || plugins_choice=""
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
    read -r key_val || key_val=""

    if [ -z "$key_val" ]; then
      fail "API key required for $name"
      exit 1
    fi

    if [ -n "$extra_vars" ]; then
      echo -ne "  ${extra_vars}: "
      read -r extra_val || extra_val=""
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
    i=$((i+1))
  done

  echo ""
  echo -e "  ${DIM}Profile: ${profile}${RESET}"
  echo -e "  ${DIM}Enable:  ./setup.sh add <name>${RESET}"
  echo -e "  ${DIM}Config:  ~/.claude.json${RESET}"
}

cmd_update() {
  # --no-pull: re-apply config from the tree AS-IS. Used by the push-mode
  # deploy (ansible-ai/push-config.yml), which rsyncs the control node's
  # working tree here first — a git pull would immediately clobber it.
  local no_pull="no"
  [ "${1:-}" = "--no-pull" ] && no_pull="yes"
  header "Updating..."
  cd "$DOTFILES_DIR"
  # Fingerprint this script BEFORE the pull so we can tell if the pull rewrites
  # it (see the re-exec guard below). `if` (not `&& `) to stay set -e-safe.
  local self="$DOTFILES_DIR/setup.sh" before_hash=""
  if [ -f "$self" ]; then before_hash="$(cksum "$self" 2>/dev/null || true)"; fi

  # Sync with the remote. Fleet checkouts (vps profile) are deploy mirrors —
  # plugin installs write enabledPlugins through the settings.json symlink and
  # dirty the tree on every host, and `pull --rebase --autostash` against that
  # dirt eventually re-applies the stash with CONFLICT MARKERS in the live
  # settings file while git still exits 0. So vps hard-resets to upstream
  # (install_settings + the profile re-apply below regenerate everything).
  # Desktop checkouts are real working copies and keep rebase+autostash — but
  # failures are loud now: a host with stale config must never report OK.
  # "PULL-FAILED" is a sentinel ansible-ai/update.yml can grep for.
  local saved_profile="desktop" head_before="" pull_status="up-to-date"
  [ -f "$DOTFILES_DIR/.local/.profile" ] && saved_profile="$(cat "$DOTFILES_DIR/.local/.profile")"
  if [ "$no_pull" = "yes" ]; then
    skip "Git sync skipped (--no-pull — applying the tree as pushed)"
  elif ! git rev-parse --git-dir >/dev/null 2>&1; then
    skip "Not a git repo — skipping pull"
  else
    head_before="$(git rev-parse HEAD 2>/dev/null || true)"
    if [ "$saved_profile" = "vps" ]; then
      if git fetch origin && git reset --hard '@{u}'; then
        ok "Synced to upstream (deploy mirror — host-local edits discarded)"
      else
        fail "PULL-FAILED: git fetch/reset failed — config would go stale, aborting"
        exit 1
      fi
    else
      if git pull --rebase --autostash; then
        ok "Pulled latest changes (local edits preserved)"
      else
        fail "PULL-FAILED: git pull failed (see git's error above; check: git status)"
        exit 1
      fi
    fi
    # An autostash re-apply can conflict while the pull itself exits 0 — and
    # these files are what the live ~/.claude config symlinks point at.
    if [ -n "$(git ls-files -u)" ]; then
      fail "PULL-FAILED: unmerged files in the tree (fix: git status, then git stash drop or resolve)"
      exit 1
    fi
    [ "$head_before" != "$(git rev-parse HEAD 2>/dev/null || true)" ] && pull_status="updated"
    echo -e "  ${DIM}pull-status: ${pull_status}${RESET}"
  fi

  # Re-exec when the pull rewrote setup.sh itself. bash parsed the OLD file into
  # memory before the pull, so a change to cmd_update (or any helper it calls)
  # wouldn't take effect until the NEXT run — the "two-run lag" that bit the
  # fleet the first time the plugin refresh shipped. Re-running the new version
  # here makes every update single-pass. SETUP_REEXECED guards it to run once.
  if [ -z "${SETUP_REEXECED:-}" ] && [ -n "$before_hash" ] \
     && [ "$before_hash" != "$(cksum "$self" 2>/dev/null || true)" ]; then
    ok "setup.sh changed in the pull — re-running with the updated version"
    exec env SETUP_REEXECED=1 bash "$self" update
  fi

  # Read saved preferences
  local profile="desktop" github_user="" hide_ai="no" remote_control="no"
  if [ -f "$DOTFILES_DIR/.local/.profile" ]; then
    profile=$(cat "$DOTFILES_DIR/.local/.profile")
  else
    # A missing .local/ means NO answers were saved — updating with defaults
    # silently applies the desktop profile, which put two fleet servers on
    # the wrong profile once. Warn loudly; don't guess quietly.
    warn "No saved profile (.local/.profile) — defaulting to 'desktop'"
    warn "Fleet host? Fix with:  mkdir -p .local && echo vps > .local/.profile"
  fi
  if [ -f "$DOTFILES_DIR/.local/.github-user" ]; then
    github_user=$(cat "$DOTFILES_DIR/.local/.github-user")
  fi
  if [ -f "$DOTFILES_DIR/.local/.hide-ai" ]; then
    hide_ai=$(cat "$DOTFILES_DIR/.local/.hide-ai")
  fi
  if [ -f "$DOTFILES_DIR/.local/.remote-control" ]; then
    remote_control=$(cat "$DOTFILES_DIR/.local/.remote-control")
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

  # Refresh the plugin stack: pull latest marketplace catalogs (so installed
  # plugins update on next start) and install any newly-listed CORE plugins.
  # --core-only keeps it non-interactive — essential for the unattended fleet
  # update (ansible-ai/update.yml → `setup.sh update`). The script resolves
  # `claude` on PATH itself, so this works in a bare shell.
  if [ -x "$DOTFILES_DIR/scripts/bootstrap-plugins.sh" ]; then
    "$DOTFILES_DIR/scripts/bootstrap-plugins.sh" --core-only \
      || warn "Plugin refresh had issues — re-run ./scripts/bootstrap-plugins.sh"
  fi

  # Reassemble CLAUDE.md
  assemble_claude_md "$profile" "$github_user" "$hide_ai"

  # Refresh the Codex/Cursor instruction symlinks (AGENTS.md -> CLAUDE.md)
  link_agent_instructions

  # Re-install settings (honors saved Remote Control choice) and re-link scripts
  install_settings "$profile" "$remote_control"
  link_file "$DOTFILES_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  chmod +x "$CLAUDE_DIR/statusline.sh"

  for script in "$DOTFILES_DIR"/scripts/*.sh; do
    [ -f "$script" ] || continue
    link_file "$script" "$CLAUDE_DIR/scripts/$(basename "$script")"
    chmod +x "$CLAUDE_DIR/scripts/$(basename "$script")"
  done

  # Re-apply the saved Supabase fork (cloud/internal). Preserves the stored
  # connection string, so this stays non-interactive on update.
  if [ -f "$DOTFILES_DIR/.local/.supabase-mode" ]; then
    configure_supabase "$(cat "$DOTFILES_DIR/.local/.supabase-mode")"
  fi

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
    read -r val || val=""
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
  add)      cmd_add "${2:-}" ;;
  list)     cmd_list ;;
  update)   cmd_update "${2:-}" ;;
  env)      cmd_env "${2:-}" "${3:-}" ;;
  supabase) configure_supabase "${2:-}" ;;
  help|--help|-h)
    echo "Claude Code Dotfiles Setup"
    echo ""
    echo "Usage:"
    echo "  ./setup.sh              Initial setup (profile + integrations)"
    echo "  ./setup.sh add <name>   Add/enable a single MCP integration"
    echo "  ./setup.sh list         Show all integrations and their status"
    echo "  ./setup.sh env KEY [v]  Add an API key to ~/.claude/.env"
    echo "  ./setup.sh supabase [m] Configure Supabase MCP (m = cloud|internal, or prompt)"
    echo "  ./setup.sh update       Pull latest and reassemble config"
    echo "                          (--no-pull: reassemble without touching git)"
    echo "  ./setup.sh help         Show this help"
    ;;
  *)      cmd_setup ;;
esac
