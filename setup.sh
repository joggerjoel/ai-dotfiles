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

# ── Asset registry ───────────────────────────────────────────────
# shellcheck source=lib/integrations.sh
source "$DOTFILES_DIR/lib/integrations.sh"

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
      local url="${extra_val:-https://REPLACE-ME.invalid/mcp-server/http}"
      echo "{\"type\":\"http\",\"url\":\"${url}\",\"headers\":{\"Authorization\":\"Bearer ${key_val}\"}}";;
    crawl4ai)
      local url="${extra_val:-https://REPLACE-ME.invalid/mcp/sse}"
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
  # Darwin does not imply Homebrew. A stock Mac has none, and claiming brew
  # here made ensure_node report "Package manager: brew" and then die on
  # `brew: command not found` one line later.
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew &>/dev/null; then
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
  # cli/cli publishes Linux as .tar.gz but macOS only as .zip. This built a
  # macOS .tar.gz URL that 404s; it stayed hidden because ensure_gh only reaches
  # this fallback from the apt branch, so it has never run on a Mac.
  local ext tmp
  os="linux"; ext="tar.gz"
  [ "$(uname -s)" = "Darwin" ] && { os="macOS"; ext="zip"; }
  tag=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name')
  [ -n "$tag" ] && [ "$tag" != "null" ] || return 1
  ver="${tag#v}"
  mkdir -p "$HOME/.local/bin"
  # mktemp, not a fixed /tmp name: a predictable path is clobberable by any
  # other user on a shared box.
  tmp="$(mktemp -d)" || return 1
  curl -fsSL "https://github.com/cli/cli/releases/download/${tag}/gh_${ver}_${os}_${arch}.${ext}" \
    -o "$tmp/gh.${ext}" || { rm -rf "$tmp"; return 1; }
  case "$ext" in
    tar.gz) tar xzf "$tmp/gh.${ext}" -C "$tmp" ;;
    zip)    unzip -q "$tmp/gh.${ext}" -d "$tmp" ;;
  esac || { rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/gh_${ver}_${os}_${arch}/bin/gh" "$HOME/.local/bin/gh" \
    || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
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

  # Fall back to nvm when no system package manager can supply node: a Mac
  # without Homebrew matches neither branch above. nvm needs no sudo, and the
  # fleet's provisioning playbook already installs node this way.
  if ! command -v node &>/dev/null; then
    [ -s "$HOME/.nvm/nvm.sh" ] || curl -fsSL \
      https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash >/dev/null 2>&1
    # shellcheck disable=SC1091
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
      . "$HOME/.nvm/nvm.sh"
      nvm install --lts >/dev/null 2>&1
    fi
  fi

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

# zsh is a nicety, not a prerequisite: the script's own hard requirements are
# git/curl/jq (see check_prereq). So this warns and returns 0 on every failure
# path — a host that cannot get a zsh must still receive its skills, settings
# and CLI updates. install_zsh_modules re-checks and skips the modules.
ensure_zsh() {
  command -v zsh &>/dev/null && { ok "zsh present"; return 0; }
  # "" and "unknown" both mean "nothing here can install a package". Testing
  # only for "unknown" missed the empty case that cmd_update used to produce.
  if [ -z "$PKG_MANAGER" ] || [ "$PKG_MANAGER" = "unknown" ]; then
    warn "zsh missing and no package manager — install it manually"
    return 0
  fi
  warn "zsh missing — installing..."
  # The `||` must sit on THIS line. As a bare command it is a set -e abort, and
  # the recovery below never runs — which is precisely how the fleet died.
  pkg_install zsh >/dev/null 2>&1 || warn "zsh install command failed"
  command -v zsh &>/dev/null && ok "zsh installed" \
    || warn "zsh install failed — install manually, then re-run"
  return 0
}

# Shared clone-or-pull for git-checkout dependencies (zinit, oh-my-zsh,
# powerlevel10k, and the omz custom plugins below): `git pull --ff-only` on
# an existing checkout is the upgrade path, and a fresh clone is the install
# path. A failed pull (local edits, diverged history) warns and leaves the
# checkout as-is instead of discarding anything.
# Usage: git_clone_or_pull <dir> <url> <label> [extra `git clone` args...]
git_clone_or_pull() {
  local dir="$1" url="$2" label="$3"
  shift 3
  if [ -d "$dir/.git" ]; then
    ok "$label present"
    git -C "$dir" pull --ff-only >/dev/null 2>&1 \
      || warn "$label: git pull --ff-only failed — left as-is (local changes?)"
    return 0
  fi
  warn "$label missing — installing..."
  mkdir -p "$(dirname "$dir")"
  git clone "$@" "$url" "$dir" >/dev/null 2>&1 \
    && ok "$label installed" \
    || fail "$label install failed — git clone $url $dir"
}

ensure_zinit() {
  local dir="$HOME/.local/share/zinit/zinit.git"
  # chmod g-rwX on the parent dir is zinit's own hardening step (it refuses
  # to load from a group-writable path); harmless to re-apply every run, not
  # just on a fresh install.
  mkdir -p "$(dirname "$dir")" && chmod g-rwX "$(dirname "$dir")"
  git_clone_or_pull "$dir" "https://github.com/zdharma-continuum/zinit" "zinit"
}

ensure_omz() {
  local dir="$HOME/.oh-my-zsh"
  git_clone_or_pull "$dir" "https://github.com/ohmyzsh/ohmyzsh.git" "oh-my-zsh" --depth=1
}

ensure_p10k() {
  local dir="$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
  git_clone_or_pull "$dir" "https://github.com/romkatv/powerlevel10k.git" "powerlevel10k" --depth=1
}

# The three third-party oh-my-zsh plugins zsh/modules/plugins.zsh's `plugins=()`
# list depends on (zsh-autosuggestions, zsh-syntax-highlighting,
# zsh-completions — see the comment there for which of the six are bundled
# with omz core vs. third-party). Table-driven so a new plugin is one line,
# not a copy-pasted function. Must run after ensure_omz — it writes into
# oh-my-zsh's custom/ dir — which modules.conf's row order (40, after omz's
# 20 and p10k's 30) guarantees via install_zsh_modules.
ensure_omz_plugins() {
  local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    warn "oh-my-zsh not present — skipping custom plugin install"
    return 0
  fi
  local name url
  while IFS='|' read -r name url; do
    [ -n "$name" ] || continue
    git_clone_or_pull "$custom/plugins/$name" "$url" "$name" --depth=1
  done <<'PLUGINS'
zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions
zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting
zsh-completions|https://github.com/zsh-users/zsh-completions
PLUGINS
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

# agy (Google Antigravity) — a sibling agent CLI, installed here so a fresh
# `./setup.sh` lands it rather than waiting for the first update run. Upgrades
# are NOT handled here: scripts/agents-update.sh owns those for every agent CLI
# (`agy update`), and ansible-ai/provision-ai.yml installs it on the fleet.
#
# Not a package — a flat native binary. The bootstrapper picks the platform
# manifest, verifies the payload's published sha512, writes ~/.local/bin/agy,
# then runs `agy install` to put ~/.local/bin on PATH in the shell profile.
#
# Resolved with an explicit ~/.local/bin fallback, not just `command -v`:
# provision-ai.yml runs setup.sh through ansible, whose non-login shell leaves
# ~/.local/bin off PATH — the same reason ensure_skillspector does this.
# Fail-soft: a missing agy never blocks setup.
ensure_agy() {
  if command -v agy &>/dev/null || [ -x "$HOME/.local/bin/agy" ]; then
    ok "agy present"
    return 0
  fi
  warn "agy missing — installing (Antigravity bootstrapper → ~/.local/bin)..."
  mkdir -p "$HOME/.local/bin"
  curl -fsSL https://antigravity.google/cli/install.sh | bash >/dev/null 2>&1 \
    && ok "agy installed (~/.local/bin)" \
    || warn "agy install failed — see https://antigravity.google (non-fatal)"
}

# Shared npm-global installer for the agent-workflow CLIs below. Deliberately
# NOT used by ensure_claude above: that one is on the critical path for every
# fresh machine and stays untouched. Fail-soft — a missing npm or a failed
# install warns and continues; only git/curl/jq may abort setup.
npm_install_global() {   # <pkg> <binary> <label>
  local pkg="$1" bin="$2" label="$3"
  command -v "$bin" &>/dev/null && { ok "$label present"; return 0; }
  command -v npm &>/dev/null || { warn "$label skipped — npm unavailable"; return 0; }
  warn "$label missing — installing via npm..."
  npm install -g "$pkg@latest" >/dev/null 2>&1 \
    || $SUDO npm install -g "$pkg@latest" >/dev/null 2>&1
  command -v "$bin" &>/dev/null && ok "$label installed" \
    || warn "$label install failed — npm install -g $pkg (non-fatal)"
}

# OpenSpec + Beads — spec-driven change proposals and agent issue tracking.
# Cross-platform, unlike ensure_herdr below: useful on any host, so they follow
# the herdr-renderers precedent and run wherever setup.sh runs. npm is the only
# path that covers the Linux fleet — beads ships no apt package, and brew there
# is not a given. Both CLIs are inert until a project runs `openspec init` /
# `bd init`, so installing unconditionally costs one npm package each.
# Rationale: references/openspec-beads-plan.md
ensure_openspec() {
  # OpenSpec needs node >= 20.19. ensure_node accepts whatever node is already
  # present, so without this guard an older host fails deep inside npm's
  # EBADENGINE instead of saying why.
  local ver major minor
  ver="$(node -v 2>/dev/null)" && ver="${ver#v}" || ver=""
  if [ -z "$ver" ]; then
    warn "OpenSpec skipped — node unavailable"; return 0
  fi
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
  if [ "$major" -lt 20 ] || { [ "$major" -eq 20 ] && [ "$minor" -lt 19 ]; }; then
    warn "OpenSpec skipped — needs node >= 20.19 (have v${ver})"; return 0
  fi
  npm_install_global "@fission-ai/openspec" openspec "OpenSpec"
}

ensure_beads() {
  npm_install_global "@beads/bd" bd "Beads (bd)"
}

# herdr — agent-aware terminal session manager, the firstmate session backend
# (better than cmux: verified secondmate liveness probes). macOS/brew ONLY by
# design: firstmate runs on the Mac control nodes (macstudio/this laptop), not
# the Linux aorus fleet — so this is deliberately absent from the ansible CLI
# roster and provisioner. On Linux it no-ops (see herdr.dev/docs/install for the
# curl installer if a Linux host ever needs it).
ensure_herdr() {
  [ "$PKG_MANAGER" = "brew" ] || { skip "herdr skipped (macOS/brew only — firstmate backend)"; return 0; }
  command -v herdr &>/dev/null && { ok "herdr present"; return 0; }
  warn "herdr missing — installing via brew (firstmate session backend)..."
  brew install herdr >/dev/null 2>&1 \
    && ok "herdr installed" \
    || warn "herdr install failed — brew install herdr (non-fatal)"
}

# Charm's apt repo — glow is absent from Ubuntu's archives, so it needs the
# vendor repo. Mirrors the keyring + sources.list dance ensure_gh does for the
# GitHub CLI, and like that one it needs root or sudo.
add_charm_apt_repo() {
  [ -f /etc/apt/keyrings/charm.gpg ] && return 0
  [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ] || return 1
  $SUDO mkdir -p -m 755 /etc/apt/keyrings || return 1
  curl -fsSL https://repo.charm.sh/apt/gpg.key \
    | $SUDO gpg --dearmor -o /etc/apt/keyrings/charm.gpg || return 1
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
    | $SUDO tee /etc/apt/sources.list.d/charm.list >/dev/null || return 1
  $SUDO apt-get update -y >/dev/null 2>&1 || true
}

# Content renderers for the herdr-file-viewer plugin. The viewer pipes file
# content to bat / delta / glow on stdin and silently degrades that pane to
# plain text when one is absent — so the plugin "works" while losing syntax
# highlighting, colorized diffs and rendered markdown.
#
# Cross-platform, and the per-OS naming is the whole trap:
#   package      brew binary   apt binary
#   bat          bat           batcat   <- Debian renamed it (bacula-console clash)
#   git-delta    delta         delta
#   glow         glow          glow     <- not in Ubuntu; needs Charm's apt repo
# The viewer's default syntax command invokes `bat`, so on apt we expose a shim
# in ~/.local/bin rather than rewrite the plugin's own config.
ensure_herdr_renderers() {
  local pair missing_pkgs=""
  case "$PKG_MANAGER" in
    brew)
      for pair in bat:bat git-delta:delta glow:glow; do
        command -v "${pair#*:}" &>/dev/null || missing_pkgs="$missing_pkgs ${pair%%:*}"
      done
      if [ -n "$missing_pkgs" ]; then
        warn "herdr renderers missing —${missing_pkgs} (viewer panes fall back to plain text)"
        # shellcheck disable=SC2086
        brew install $missing_pkgs >/dev/null 2>&1 \
          && ok "herdr renderers installed —${missing_pkgs}" \
          || warn "renderer install failed — brew install${missing_pkgs} (non-fatal)"
      else
        ok "herdr renderers present (bat, delta, glow)"
      fi
      ;;
    apt)
      command -v batcat &>/dev/null || command -v bat &>/dev/null || missing_pkgs="$missing_pkgs bat"
      command -v delta &>/dev/null || missing_pkgs="$missing_pkgs git-delta"
      if ! command -v glow &>/dev/null; then
        add_charm_apt_repo && missing_pkgs="$missing_pkgs glow" \
          || warn "glow skipped — Charm apt repo needs root (non-fatal)"
      fi
      if [ -n "$missing_pkgs" ]; then
        warn "herdr renderers missing —${missing_pkgs} (viewer panes fall back to plain text)"
        apt_update_once
        # shellcheck disable=SC2086
        $SUDO apt-get install -y $missing_pkgs >/dev/null 2>&1 \
          && ok "herdr renderers installed —${missing_pkgs}" \
          || warn "renderer install failed — apt-get install${missing_pkgs} (non-fatal)"
      else
        ok "herdr renderers present (bat/batcat, delta, glow)"
      fi
      # Debian's binary is batcat; the viewer calls `bat`. Shim it, no sudo needed.
      if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
        mkdir -p "$HOME/.local/bin"
        ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat" \
          && ok "linked batcat → ~/.local/bin/bat (viewer invokes it as 'bat')"
      fi
      ;;
    *)
      skip "herdr renderers skipped (no supported package manager)"
      ;;
  esac
}

# cass — searches this machine's local coding-agent session history (Codex,
# Claude Code, Cursor, Aider and ~20 more) from one index. Every host gets it:
# the archive is per-machine, so a worker's history is only searchable on that
# worker.
#
# Two install paths because the fleet has no Homebrew: brew has a tap with
# bottles for macOS, and the Linux boxes take the upstream installer, which
# fetches a prebuilt cass-linux-amd64 release asset (--verify checks the
# published sha256, so no source build and no Rust toolchain).
#
# The agent-facing SKILL.md is fetched at install time rather than vendored
# into skills/. cass is MIT with a rider forbidding making the software or
# derivative works available to OpenAI/Anthropic, and this repo is public —
# so the file lands on the host and never in git. See references/cass.md.
ensure_cass() {
  # Judge cass by whether it RUNS, not by whether it is on PATH. The prebuilt
  # linux-amd64 asset is built against glibc 2.39 (Ubuntu 24.04); on 22.04 it
  # installs cleanly and then dies with "GLIBC_2.39 not found" on every call.
  # `command -v` is true for that corpse, so a presence check would report
  # success forever and update.sh would keep upgrading a binary that cannot
  # start. Remove it instead and say why.
  if cass --version &>/dev/null; then
    ok "cass present ($(cass --version 2>/dev/null | head -1))"
  elif command -v cass &>/dev/null; then
    warn "cass is installed but will not run here — removing"
    cass --version 2>&1 | head -1 | sed 's/^/    /'
    rm -f "$HOME/.local/bin/cass"
    warn "cass unavailable on this host (prebuilt binary needs glibc >= 2.39)"
    warn "  build once on a same-release host and copy the binary over —"
    warn "  see 'Ubuntu 22.04' in references/cass.md"
    return 0
  elif [ "$PKG_MANAGER" = "brew" ]; then
    warn "cass missing — installing via brew tap..."
    brew tap dicklesworthstone/tap >/dev/null 2>&1 || true
    brew install dicklesworthstone/tap/cass >/dev/null 2>&1 \
      && ok "cass installed" \
      || warn "cass install failed — brew install dicklesworthstone/tap/cass (non-fatal)"
  else
    warn "cass missing — installing (upstream installer → ~/.local/bin)..."
    mkdir -p "$HOME/.local/bin"
    curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh" \
      | bash -s -- --easy-mode --verify >/dev/null 2>&1 \
      && ok "cass installed (~/.local/bin)" \
      || warn "cass install failed — see github.com/Dicklesworthstone/coding_agent_session_search (non-fatal)"
  fi

  # Same test after installing: a fresh install can still be unrunnable.
  if ! cass --version &>/dev/null; then
    if command -v cass &>/dev/null; then
      warn "cass installed but will not run — removing (glibc too old?)"
      rm -f "$HOME/.local/bin/cass"
    fi
    return 0
  fi
  fetch_cass_skill
}

# Pull the agent-facing skill straight from upstream onto this host. Deliberately
# NOT committed to skills/ — see the licence note on ensure_cass above.
fetch_cass_skill() {
  local dest="$CLAUDE_DIR/skills/cass"
  mkdir -p "$dest"
  if curl -fsSL --max-time 20 \
    "https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/SKILL.md" \
    -o "$dest/SKILL.md.tmp" 2>/dev/null && [ -s "$dest/SKILL.md.tmp" ]; then
    mv "$dest/SKILL.md.tmp" "$dest/SKILL.md"
    ok "cass skill fetched → ~/.claude/skills/cass/"
  else
    rm -f "$dest/SKILL.md.tmp"
    [ -f "$dest/SKILL.md" ] \
      && warn "cass skill fetch failed — keeping the existing copy" \
      || warn "cass skill fetch failed — agents lose the usage guide (non-fatal)"
  fi
}

# skillspector — NVIDIA's security scanner for agent skills. Scans a skill
# bundle for prompt injection, data exfiltration, over-broad permissions and
# supply-chain risk BEFORE it gets installed. Every host gets it: skills arrive
# per-machine (a plugin install, a clone into ~/.claude/skills), so the gate has
# to sit where the install happens.
#
# Python, so it rides on `uv tool` — ensure_uv runs earlier in
# ensure_dependencies, and the guard below keeps this a no-op if that failed.
# CLI only: the `[mcp]` extra pulls in FastMCP to serve `skillspector mcp`, and
# nothing in this stack calls it. Add it here if that changes.
#
# The agent-facing SKILL.md is fetched at install time rather than vendored into
# skills/, same as cass — but for a different reason. SkillSpector is Apache-2.0,
# so committing it would be perfectly legal; it would just rot. Upstream revises
# the skill in lockstep with the scanner, and a stale vendored copy would tell
# agents to run checks the installed binary no longer has.
# Both binaries are resolved with an explicit ~/.local/bin fallback, not just
# `command -v`: provision-ai.yml runs this through ansible, whose non-login shell
# leaves ~/.local/bin off PATH — the same reason agents-update.sh has resolve_tool.
ensure_skillspector() {
  local uv_bin
  uv_bin="$(command -v uv 2>/dev/null || true)"
  [ -n "$uv_bin" ] || { [ -x "$HOME/.local/bin/uv" ] && uv_bin="$HOME/.local/bin/uv"; }

  if command -v skillspector &>/dev/null || [ -x "$HOME/.local/bin/skillspector" ]; then
    ok "skillspector present"
  elif [ -z "$uv_bin" ]; then
    warn "skillspector skipped — uv unavailable (non-fatal)"
    return 0
  else
    warn "skillspector missing — installing via uv tool..."
    if "$uv_bin" tool install "git+https://github.com/NVIDIA/skillspector.git" >/dev/null 2>&1; then
      ok "skillspector installed (~/.local/bin)"
    else
      warn "skillspector install failed — uv tool install git+https://github.com/NVIDIA/skillspector.git (non-fatal)"
      return 0
    fi
  fi
  fetch_skillspector_skill
}

# Pull the agent-facing skill straight from upstream onto this host. The
# directory is named for the skill's own frontmatter `name:` (skill-inspector),
# NOT for the CLI — Claude Code warns when a skill directory and its declared
# name disagree.
fetch_skillspector_skill() {
  local dest="$CLAUDE_DIR/skills/skill-inspector"
  mkdir -p "$dest"
  if curl -fsSL --max-time 20 \
    "https://raw.githubusercontent.com/NVIDIA/SkillSpector/main/skills/skill-inspector/SKILL.md" \
    -o "$dest/SKILL.md.tmp" 2>/dev/null && [ -s "$dest/SKILL.md.tmp" ]; then
    mv "$dest/SKILL.md.tmp" "$dest/SKILL.md"
    ok "skillspector skill fetched → ~/.claude/skills/skill-inspector/"
  else
    rm -f "$dest/SKILL.md.tmp"
    [ -f "$dest/SKILL.md" ] \
      && warn "skillspector skill fetch failed — keeping the existing copy" \
      || warn "skillspector skill fetch failed — agents lose the usage guide (non-fatal)"
  fi
}

ensure_just() {
  command -v just &>/dev/null && { ok "just present"; return 0; }
  if [ "$PKG_MANAGER" = "brew" ]; then
    warn "just missing — installing via brew (fleet command runner)..."
    brew install just >/dev/null 2>&1 \
      && ok "just installed" \
      || warn "just install failed — brew install just (non-fatal)"
  else
    warn "just missing — installing (official installer → ~/.local/bin)..."
    mkdir -p "$HOME/.local/bin"
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
      | bash -s -- --to "$HOME/.local/bin" >/dev/null 2>&1 \
      && ok "just installed (~/.local/bin — open a new shell to pick it up)" \
      || warn "just install failed — see https://just.systems (non-fatal)"
  fi
}

# Serena opens a browser dashboard tab on every `start-mcp-server` launch by
# default. The global config is the single control point that all launchers
# (the serena plugin included) honor, so disable it there — this is what stops
# the popup reproducibly on a fresh machine. Serena fills every other key with
# its own defaults, so a minimal seed file is safe.
# Tools this repo's own entry points hard-require but nothing ever installed.
# bin/herdr-new-project exits with "fzf not found" if fzf is absent — and
# link_bin_tools deploys that launcher regardless — while `just lint` aborts
# without shellcheck. Same package name on brew and apt, so pkg_install covers
# both; failures warn rather than abort, matching the rest of the chain.
ensure_repo_tools() {
  local tool
  for tool in fzf shellcheck; do
    if command -v "$tool" &>/dev/null; then
      ok "$tool present"
    else
      warn "$tool missing — installing..."
      # Check the outcome, not the package manager's exit code: brew and apt
      # both exit 0 on no-ops that leave nothing on PATH.
      pkg_install "$tool" >/dev/null 2>&1 || true
      command -v "$tool" &>/dev/null && ok "$tool installed" \
        || warn "$tool install failed — install manually (non-fatal)"
    fi
  done
}

# The tmuxp session configs in tmux/ are inert without their runtime: tmuxp
# reads the YAML, tmux hosts the panes, and the panes run the monitors. Same
# package name on brew and apt for tmux/htop/glances, so pkg_install covers
# both; failures warn rather than abort, matching ensure_repo_tools. A host
# without a metrics session is still a working dotfiles install.
ensure_tmux_stack() {
  local tool
  for tool in tmux htop glances; do
    if command -v "$tool" &>/dev/null; then
      ok "$tool present"
    else
      warn "$tool missing — installing..."
      # Check the outcome, not the package manager's exit code: brew and apt
      # both exit 0 on no-ops that leave nothing on PATH.
      pkg_install "$tool" >/dev/null 2>&1 || true
      command -v "$tool" &>/dev/null && ok "$tool installed" \
        || warn "$tool install failed — install manually (non-fatal)"
    fi
  done

  # tmuxp gets its own branch: apt's package lags upstream and is missing on
  # some releases, so fall back to the uv-managed install (ensure_uv has
  # already run, and uv drops the binary in ~/.local/bin).
  if command -v tmuxp &>/dev/null; then
    ok "tmuxp present"
  else
    warn "tmuxp missing — installing (tmux session manager)..."
    pkg_install tmuxp >/dev/null 2>&1 || true
    if ! command -v tmuxp &>/dev/null && command -v uv &>/dev/null; then
      uv tool install tmuxp >/dev/null 2>&1 || true
    fi
    command -v tmuxp &>/dev/null && ok "tmuxp installed" \
      || warn "tmuxp install failed — uv tool install tmuxp (non-fatal)"
  fi
}

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
  ensure_zsh     # login shell the zsh/ module registry targets
  ensure_node    # Claude Code + npx MCP servers
  ensure_gh      # GitHub CLI (tool-priority default)
  ensure_bun     # JS/TS package manager
  ensure_uv      # Python package manager (serena runs via uvx)
  ensure_claude  # Claude Code itself
  ensure_agy     # Google Antigravity CLI (native binary → ~/.local/bin)
  ensure_openspec # spec-driven change proposals (npm; needs node >= 20.19)
  ensure_beads   # agent issue tracking + dependency memory (npm, all hosts)
  ensure_cass    # search this host's coding-agent session history (brew or installer)
  ensure_skillspector  # scan agent skills for malicious patterns before install (uv tool)
  ensure_herdr   # firstmate session backend (macOS/brew only — no-ops on Linux)
  ensure_herdr_renderers  # bat/delta/glow — herdr-file-viewer content panes
  ensure_just    # fleet command runner (cross-platform: brew or install.sh)
  ensure_repo_tools  # fzf (herdr launcher pickers) + shellcheck (just lint)
  ensure_tmux_stack  # tmux + tmuxp + monitors for the tmux/ session configs
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
    local backup_dir
    backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
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
    local backup_dir
    backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
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
#
# A skill retired from skills/ used to keep its stale copy in ~/.claude/skills/
# forever — nothing ever removed it. A manifest (SKILLS_MANIFEST, one name per
# line, dotfile so it never matches a `skills/*/` glob) records exactly which
# names THIS script installed last run. Pruning only ever consults that list:
# a name that drops out of the repo AND is in the manifest gets removed; a
# directory never listed in the manifest (plugin-provided, user-local) is
# never touched, even if it's absent from the repo. A missing manifest (first
# run, or an install from before this fix) prunes nothing.
SKILLS_MANIFEST_NAME=".installed-by-setup"

install_skills() {
  [ -d "$DOTFILES_DIR/skills" ] || return 0
  mkdir -p "$CLAUDE_DIR/skills"
  local manifest="$CLAUDE_DIR/skills/$SKILLS_MANIFEST_NAME"

  if [ -f "$manifest" ]; then
    local prev_name
    while IFS= read -r prev_name; do
      [ -n "$prev_name" ] || continue
      if [ ! -d "$DOTFILES_DIR/skills/$prev_name" ] && [ -d "$CLAUDE_DIR/skills/$prev_name" ]; then
        rm -rf "${CLAUDE_DIR:?}/skills/${prev_name:?}"
      fi
    done < "$manifest"
  fi

  local count=0
  local new_manifest
  new_manifest=$(mktemp)
  for skill_dir in "$DOTFILES_DIR"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    local name
    name=$(basename "$skill_dir")
    rm -rf "$CLAUDE_DIR/skills/$name"
    cp -R "$skill_dir" "$CLAUDE_DIR/skills/$name"
    echo "$name" >> "$new_manifest"
    count=$((count+1))
  done
  mv "$new_manifest" "$manifest"
  ok "$count skill(s) installed to ~/.claude/skills/"
}

# Copies the agent-agnostic subset of repo skills into ~/.codex/skills/<name>/,
# so Codex gets them too. Deliberately an allowlist, not a mirror of skills/:
# most skills here assume Claude Code's tools, hooks, or plugin stack and would
# only mislead Codex. A skill earns a place in CODEX_SKILLS by working in both.
# skills/unlazy/scripts/ is gitignored — it is third-party Node that runs shell
# from CHECK: lines, so it is not carried in this repo (see .gitignore). A fresh
# clone, or any fleet host that pulled from origin, therefore has the skill's
# prose but not its checker. Restore it at the commit pinned in .upstream before
# installing; otherwise every command the skill documents is missing there.
ensure_unlazy_payload() {
  [ -f "$DOTFILES_DIR/skills/unlazy/.upstream" ] || return 0
  [ -f "$DOTFILES_DIR/skills/unlazy/scripts/gate-check.mjs" ] && return 0
  if [ -x "$DOTFILES_DIR/scripts/vendor-unlazy-skill.sh" ] \
     && "$DOTFILES_DIR/scripts/vendor-unlazy-skill.sh" --payload >/dev/null 2>&1; then
    ok "unlazy checker restored at its pinned commit"
  else
    warn "unlazy checker missing and restore failed — the skill installs without its gate checker (run ./scripts/vendor-unlazy-skill.sh --payload)"
  fi
  return 0
}

CODEX_SKILLS=(unlazy)

install_codex_skills() {
  [ -d "$DOTFILES_DIR/skills" ] || return 0
  local count=0
  for name in "${CODEX_SKILLS[@]}"; do
    [ -d "$DOTFILES_DIR/skills/$name" ] || continue
    mkdir -p "$HOME/.codex/skills"
    rm -rf "${HOME:?}/.codex/skills/$name"
    cp -R "$DOTFILES_DIR/skills/$name" "$HOME/.codex/skills/$name"
    count=$((count+1))
  done
  [ "$count" -gt 0 ] && ok "$count skill(s) installed to ~/.codex/skills/"
  return 0
}

# Copies repo commands/<name>.md into ~/.claude/commands/<name>.md (copy model,
# like skills). Only touches command files the repo owns; leaves user-local
# commands untouched. These are thin slash-command wrappers that typically just
# invoke a repo-owned skill.
install_commands() {
  [ -d "$DOTFILES_DIR/commands" ] || return 0
  mkdir -p "$CLAUDE_DIR/commands"
  local count=0
  for cmd_file in "$DOTFILES_DIR"/commands/*.md; do
    [ -f "$cmd_file" ] || continue
    cp "$cmd_file" "$CLAUDE_DIR/commands/$(basename "$cmd_file")"
    count=$((count+1))
  done
  ok "$count command(s) installed to ~/.claude/commands/"
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
    local backup_dir
    backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
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
  sync_pstack
  link_claude_hooks
  link_bin_tools
}

# pstack for the shared-skills runtimes (Codex, Prime Agent, opencode, Gemini
# CLI): clones michael-denyer/pstack-claude and links its 52 skills into
# ~/.agents/skills plus its 31 Codex slash-command stubs into ~/.codex/prompts,
# and enables codex multi_agent. Lives here rather than in install_skills
# because nothing lands in ~/.claude/skills — Claude Code gets pstack as a
# plugin via bootstrap-plugins.sh (OPT_AUTOMATION). Non-fatal offline: an
# existing clone is relinked as-is, a missing one is skipped.
sync_pstack() {
  [ -x "$DOTFILES_DIR/scripts/sync-pstack.sh" ] || return 0
  "$DOTFILES_DIR/scripts/sync-pstack.sh" || warn "pstack sync had issues (non-fatal — check network)"
}

# Repo CLI helpers (bin/* -> ~/.local/bin/<name>). Symlinked so a repo pull
# updates the live tools. Current roster: isolate (clean-room single-shot
# model call for cold-eyes reviews).
link_bin_tools() {
  [ -d "$DOTFILES_DIR/bin" ] || return 0
  local f
  for f in "$DOTFILES_DIR"/bin/*; do
    [ -f "$f" ] || continue
    chmod +x "$f"
    link_file "$f" "$HOME/.local/bin/$(basename "$f")"
  done
}

# Claude Code hooks (hooks/*.{sh,py} -> ~/.claude/hooks/<name>). The shared
# profile settings.json references these by $HOME path, so a machine that
# skips this step gets a "No such file or directory" PreToolUse error on
# every Bash call. Symlinked so a repo pull updates the live hooks.
# Both extensions are linked: the glob was .sh-only until injection-guard.py
# arrived, which meant a registered .py hook silently never got installed.
link_claude_hooks() {
  [ -d "$DOTFILES_DIR/hooks" ] || return 0
  local f
  for f in "$DOTFILES_DIR"/hooks/*.sh "$DOTFILES_DIR"/hooks/*.py; do
    [ -f "$f" ] || continue
    # A real hook is <name>.<ext>. Anything with a dotted stem (foo.test.sh,
    # foo.backtest.py) is a repo-side helper and must not be linked as a hook.
    case "$(basename "$f")" in *.*.*) continue ;; esac
    link_file "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"
  done
}

# Repo scripts (scripts/*.sh -> ~/.claude/scripts/<name>). Symlinked so a repo
# pull updates the live script. Same dotted-stem filter as link_claude_hooks:
# a real script is <name>.sh; foo.test.sh is a repo-side test helper, not
# something to deploy fleet-wide. Shared by cmd_setup and cmd_update — it used
# to be a copy-pasted loop in both places, missing the filter in each.
link_repo_scripts() {
  [ -d "$DOTFILES_DIR/scripts" ] || return 0
  mkdir -p "$CLAUDE_DIR/scripts"
  local f
  for f in "$DOTFILES_DIR"/scripts/*.sh; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in *.*.*) continue ;; esac
    link_file "$f" "$CLAUDE_DIR/scripts/$(basename "$f")"
    chmod +x "$CLAUDE_DIR/scripts/$(basename "$f")"
  done
}

# tmuxp session configs (tmux/*.yaml -> ~/.tmuxp/<name>.yaml). Symlinked so a
# repo pull updates the live session definition. ~/.tmuxp/ is tmuxp's own
# workspace dir, so these load by bare name:
#   tmuxp load server-metrics
# Legacy installs deployed to ~/.tmux/ (tmux's plugin dir, which tmuxp never
# searched); those symlinks are cleaned up below.
link_tmux_sessions() {
  [ -d "$DOTFILES_DIR/tmux" ] || return 0
  mkdir -p "$HOME/.tmuxp"
  local f legacy
  for f in "$DOTFILES_DIR"/tmux/*.yaml; do
    [ -f "$f" ] || continue
    link_file "$f" "$HOME/.tmuxp/$(basename "$f")"
    # Remove the legacy ~/.tmux/ symlink, but only if it still points at this
    # repo -- never touch a real file or a link the user placed there.
    legacy="$HOME/.tmux/$(basename "$f")"
    if [ -L "$legacy" ] && [ "$(readlink "$legacy")" = "$f" ]; then
      rm -f "$legacy"
    fi
  done
  rmdir "$HOME/.tmux" 2>/dev/null || true
}

# ── zsh module registry ──────────────────────────────────────────
# zsh/modules.conf is the single source of truth for load order, runtime
# guard, OS applicability, and install action — both this generator and each
# module's install step (install_fn) read the same table, nothing here
# hardcodes the module list.
generate_zshrc() {
  local os_filter
  case "$(detect_os)" in
    macOS) os_filter="darwin" ;;
    *)     os_filter="linux" ;;   # Linux, or an unrecognized OS: best-effort
  esac

  local dst="$HOME/.zshrc"
  if [ -e "$dst" ]; then
    local backup
    backup="$HOME/.zshrc.backup.$(date +%Y%m%d_%H%M%S)"
    cp -L "$dst" "$backup" 2>/dev/null || cp "$dst" "$backup"
    ok "Backed up existing ~/.zshrc -> $backup"
  fi

  local tmp
  tmp="$(mktemp)"
  {
    echo "# Generated by ai-dotfiles/setup.sh from zsh/modules.conf — DO NOT EDIT BY HAND."
    echo "# Edit zsh/modules.conf and the files under zsh/modules/, then run: ./setup.sh update"
    echo "# Personal, machine-specific additions go in ~/.zshrc.local (see zsh/zshrc.local.example)."
  } > "$tmp"

  local order name guard os install_fn
  while IFS='|' read -r order name os install_fn guard; do
    [[ "$order" =~ ^[0-9]+$ ]] || continue
    [ "$os" = "both" ] || [ "$os" = "$os_filter" ] || continue
    {
      echo ""
      echo "# --- $name ---"
      if [ "$guard" = "-" ]; then
        echo "source \"$DOTFILES_DIR/zsh/modules/$name.zsh\""
      else
        echo "if $guard; then"
        echo "  source \"$DOTFILES_DIR/zsh/modules/$name.zsh\""
        echo "fi"
      fi
    } >> "$tmp"
  done < <(grep -vE '^\s*#|^\s*$' "$DOTFILES_DIR/zsh/modules.conf")

  mv "$tmp" "$dst"
  ok "Generated ~/.zshrc from zsh/modules.conf ($(wc -l < "$dst" | tr -d ' ') lines)"
}

# Runs each module's install/upgrade step (the install_fn column), then
# regenerates ~/.zshrc. Table-driven: a new module with an installer needs
# only a modules.conf row and a matching ensure_* function, no change here.
install_zsh_modules() {
  header "zsh modules"
  ensure_zsh

  # Every module below is a zsh plugin: zinit, oh-my-zsh, powerlevel10k. Cloning
  # them for a shell that is not installed writes ~40MB of checkouts nothing can
  # load, and generate_zshrc would author a .zshrc for an absent interpreter.
  # Skip the section, keep the update going — the caller is mid-convergence.
  if ! command -v zsh &>/dev/null; then
    skip "zsh unavailable — shell modules skipped (rest of the update continues)"
    return 0
  fi

  local order name guard os install_fn
  while IFS='|' read -r order name os install_fn guard; do
    [[ "$order" =~ ^[0-9]+$ ]] || continue
    [ "$install_fn" = "-" ] && continue
    if declare -f "$install_fn" >/dev/null; then
      "$install_fn"
    else
      warn "modules.conf: '$name' references unknown install_fn '$install_fn'"
    fi
  done < <(grep -vE '^\s*#|^\s*$' "$DOTFILES_DIR/zsh/modules.conf")

  generate_zshrc
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

  ensure_unlazy_payload
  # Install repo-owned skills
  install_skills

  # Mirror the agent-agnostic ones into Codex
  install_codex_skills

  # Install repo-owned slash commands
  install_commands

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
  link_repo_scripts

  # Link tmuxp session configs (tmux/*.yaml -> ~/.tmuxp/)
  link_tmux_sessions

  # Install/upgrade the zsh module registry and generate ~/.zshrc
  install_zsh_modules

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

          if [ -z "$extra_val" ]; then
            # No URL provided - install disabled rather than enabled against
            # the unreachable placeholder host
            should_disable="true"
          fi
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

      if [ -z "$extra_val" ]; then
        fail "${extra_vars} required for $name"
        exit 1
      fi
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

  # update skips the full dependency pass, and detect_pkg_manager lives inside
  # ensure_dependencies — so every install below this line used to run against
  # an empty PKG_MANAGER, which is neither "apt" nor "unknown" and so matched
  # pkg_install's silent `*) return 1`. That killed `setup.sh update` on six
  # Linux hosts at ensure_zsh with no apt output at all. Must run BEFORE any
  # ensure_* call. Cheap and side-effect-free: two `command -v` probes.
  detect_pkg_manager

  # uv joined ensure_dependencies after the early hosts were set up, and
  # update (unlike setup) skips the full dependency pass — so converge it
  # here. headroom's install/upgrade (agents-update.sh) rides on `uv tool`
  # wherever pipx is absent, which is most of the fleet. Idempotent: no-ops
  # when uv is already present.
  ensure_uv

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

  ensure_unlazy_payload
  # Re-install repo-owned skills
  install_skills

  # Re-mirror the agent-agnostic ones into Codex
  install_codex_skills

  # skillspector's skill is fetched from upstream, not vendored, so install_skills
  # above never sees it — and ensure_dependencies (which would) doesn't run on an
  # update. Without this the fleet gets the scanner binary from agents-update.sh
  # but no guide telling agents to run it, which is how it shipped the first time.
  # Deliberately NOT guarded on the CLI being present. update.yml runs this
  # step BEFORE agents-update.sh, which is what installs skillspector — so on a
  # host's first pass the guard saw no binary, skipped, and the CLI landed
  # seconds later, leaving the fleet with a scanner and no skill until someone
  # updated twice. Fetching unconditionally converges in a single pass; the
  # worst case is a 7KB guide on a host whose install failed.
  fetch_skillspector_skill

  # Re-install repo-owned slash commands
  install_commands

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

  link_repo_scripts

  # Link tmuxp session configs (tmux/*.yaml -> ~/.tmuxp/)
  link_tmux_sessions

  # Re-run each zsh module's install/upgrade step and regenerate ~/.zshrc
  install_zsh_modules

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

# ── cache-guard policy (.local/.cache-policy, gitignored) ─────────
# Declares this machine's prompt-cache TTL for hooks/cache-guard.sh. A setup
# choice, never detection: auth is not inferred from env vars or secrets.
# Non-destructive — rewrites only the keys it owns and preserves the rest
# (mode/profile survive each other's updates). Never sets
# ENABLE_PROMPT_CACHING_1H: that raises write costs and stays a user call.
cmd_cache() {
  local arg="${1:-}" ttl="${2:-}" pf="$DOTFILES_DIR/.local/.cache-policy"
  local cur_profile="" cur_mode="" cur_ttl="" cur_margin=""
  if [ -f "$pf" ]; then
    cur_profile=$(sed -n 's/^profile=//p' "$pf" | head -n1)
    cur_mode=$(sed -n 's/^mode=//p' "$pf" | head -n1)
    cur_ttl=$(sed -n 's/^ttl_seconds=//p' "$pf" | head -n1)
    cur_margin=$(sed -n 's/^warning_margin_seconds=//p' "$pf" | head -n1)
  fi

  case "$arg" in
    subscription) cur_profile=subscription; cur_ttl=3600; cur_margin=600 ;;
    api)          cur_profile=api;          cur_ttl=300;  cur_margin=60 ;;
    custom)
      case "$ttl" in '' | *[!0-9]*)
        fail "Usage: ./setup.sh cache custom <ttl_seconds>"; exit 1 ;;
      esac
      cur_profile=custom; cur_ttl="$ttl"
      cur_margin=$((ttl / 6)); [ "$cur_margin" -gt 600 ] && cur_margin=600
      [ "$cur_margin" -lt 30 ] && cur_margin=30
      ;;
    off)          cur_profile=off ;;
    warn | protect | observe) cur_mode="$arg" ;;
    '')
      header "cache-guard policy"
      if [ -f "$pf" ]; then
        sed 's/^/    /' "$pf"
      else
        skip "No policy yet — defaults apply (subscription: 1h TTL, warn mode)"
      fi
      echo ""
      echo "  Usage: ./setup.sh cache subscription|api|off      TTL profile"
      echo "         ./setup.sh cache custom <ttl_seconds>      explicit TTL"
      echo "         ./setup.sh cache observe|warn|protect      prompt-time mode"
      return 0
      ;;
    *) fail "Unknown cache option: $arg (subscription|api|custom <s>|off|observe|warn|protect)"; exit 1 ;;
  esac

  mkdir -p "$DOTFILES_DIR/.local"
  {
    echo "profile=${cur_profile:-subscription}"
    echo "mode=${cur_mode:-warn}"
    [ -n "$cur_ttl" ] && echo "ttl_seconds=$cur_ttl"
    [ -n "$cur_margin" ] && echo "warning_margin_seconds=$cur_margin"
    # Carry through any hand-tuned keys this command does not manage.
    # (|| true: grep exits 1 on no match, which would trip set -e.)
    { [ -f "$pf" ] && grep -E '^(protect_threshold_tokens|warn_threshold_tokens|notify)=' "$pf"; } || true
  } > "$pf.new"
  mv "$pf.new" "$pf"
  ok "cache-guard policy written to .local/.cache-policy"
  sed 's/^/    /' "$pf"
}

# ── Main ──────────────────────────────────────────────────────────
case "${1:-}" in
  add)      cmd_add "${2:-}" ;;
  list)     cmd_list ;;
  update)   cmd_update "${2:-}" ;;
  env)      cmd_env "${2:-}" "${3:-}" ;;
  cache)    cmd_cache "${2:-}" "${3:-}" ;;
  supabase) configure_supabase "${2:-}" ;;
  # Install/upgrade only the zsh module registry. Re-running is the upgrade
  # path, so repeating this is safe and it never touches the agent CLIs.
  zsh)      detect_os >/dev/null; detect_pkg_manager; install_zsh_modules ;;
  # Hold a sibling agent CLI at its installed version. Pins are plain state,
  # not a prompt, so one set here also holds on unattended upgrade runs
  # (ansible-ai/update.yml, cron) — configure them before those run.
  pin)      exec bash "$DOTFILES_DIR/scripts/pin.sh" "${2:-}" "${3:-}" ;;
  # Opt-in: stand up THIS machine as a firstmate node (herdr + source toolchain
  # + firstmate clone). Never part of `setup.sh` or `setup.sh update`.
  provision-firstmate) exec bash "$DOTFILES_DIR/scripts/provision-firstmate.sh" ;;
  # Opt-in: make THIS machine a firstmate worker (herdr + harnesses; persistent
  # attachable sessions). Lighter than a node — no orchestrator toolchain.
  provision-firstmate-worker) exec bash "$DOTFILES_DIR/scripts/provision-firstmate-worker.sh" ;;
  help|--help|-h)
    echo "Claude Code Dotfiles Setup"
    echo ""
    echo "Usage:"
    echo "  ./setup.sh              Initial setup (profile + integrations)"
    echo "  ./setup.sh add <name>   Add/enable a single MCP integration"
    echo "  ./setup.sh list         Show all integrations and their status"
    echo "  ./setup.sh zsh          Install or upgrade only the zsh module registry"
    echo "  ./setup.sh env KEY [v]  Add an API key to ~/.claude/.env"
    echo "  ./setup.sh cache [p]    cache-guard policy (subscription|api|custom <s>|off,"
    echo "                          or mode: observe|warn|protect; no arg shows current)"
    echo "  ./setup.sh supabase [m] Configure Supabase MCP (m = cloud|internal, or prompt)"
    echo "  ./setup.sh pin [c]      Hold an agent CLI at its version, incl. on unattended"
    echo "                          runs (list|add <name>|remove <name>)"
    echo "  ./setup.sh update       Pull latest and reassemble config"
    echo "                          (--no-pull: reassemble without touching git)"
    echo "  ./setup.sh help         Show this help"
    ;;
  *)      cmd_setup ;;
esac
