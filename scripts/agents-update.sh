#!/bin/bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────
# agents-update.sh — upgrade the sibling agent CLIs, when installed:
#   codex (OpenAI), cursor-agent (Cursor), opencode, gemini (Google),
#   cortex (Snowflake Cortex Code), headroom (context-optimization proxy).
# Also reports (but never updates) the 9router gateway — a Docker
# service on the fleet, not a local CLI; see the block at the bottom.
#
# Single source of truth for "update every AI CLI besides claude":
# called by ./update.sh locally and by ansible-ai/update.yml on the
# fleet. A failed upgrade warns and moves on to the next; exits
# non-zero if any upgrade failed. Missing CLIs: interactive runs get
# an install offer (y/N, default no); unattended runs (Ansible, cron)
# skip them silently.
#
# Deliberately NOT `set -e` — one broken installer must not block
# the remaining CLIs; failures are collected and reported instead.
# ─────────────────────────────────────────────────────────────────

# Colors only on a terminal — Ansible captures this output, and ANSI
# escapes would garble the per-host report.
if [ -t 1 ]; then
  BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; RESET=""
fi
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }

# npm-installed CLIs (gemini) need node on PATH in non-login shells.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

CURL_RETRY="--retry 5 --retry-delay 2 --retry-connrefused"
FAILED=""
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# Prompt only when a human is attached — Ansible and cron runs must
# stay unattended, so missing CLIs are skipped there (unless
# AGENTS_AUTO_INSTALL=1, which the fleet playbook sets so the CLI
# roster converges on hosts provisioned before a CLI was added).
INTERACTIVE="no"
[ -t 0 ] && [ -e /dev/tty ] && INTERACTIVE="yes"

# A hung vendor updater must not stall the whole fleet play.
RUN_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then RUN_TIMEOUT="timeout 300"
elif command -v gtimeout >/dev/null 2>&1; then RUN_TIMEOUT="gtimeout 300"; fi

# offer_install <name> <install command>
# Interactive runs get a y/N offer to install a missing CLI;
# AGENTS_AUTO_INSTALL=1 installs without asking; anything else
# (no tty, no install command) just reports the skip.
offer_install() {
  local name="$1" cmd="${2:-}" answer="" ver=""
  if [ -z "$cmd" ]; then
    skip "$name not installed"
    return 0
  fi
  if [ "${AGENTS_AUTO_INSTALL:-0}" = "1" ]; then
    answer="y"
  elif [ "$INTERACTIVE" = "yes" ]; then
    printf "  ${DIM}○${RESET} %s not installed — install it? [y/N] " "$name"
    IFS= read -r answer </dev/tty || answer=""   # EOF-tolerant
  else
    skip "$name not installed"
    return 0
  fi
  case "$answer" in
    y | Y | yes | YES) ;;
    *) skip "$name skipped"; return 0 ;;
  esac
  if $RUN_TIMEOUT bash -c "$cmd" >"$LOG" 2>&1; then
    command -v "$name" >/dev/null 2>&1 && ver="$("$name" --version 2>/dev/null | head -1)"
    ok "$name installed${ver:+ (${ver})}"
  else
    warn "$name install failed — last output:"
    tail -n 5 "$LOG" | sed 's/^/      /'
    FAILED="$FAILED $name"
  fi
}

echo -e "${BOLD}Sibling agent CLIs${RESET}"

# update_cli <name> <binary path or command name> <upgrade command> [install command]
# Offers to install when the binary is absent; otherwise runs the
# upgrade and reports old → new version (installers are quiet unless
# they fail). "%BIN%" in the upgrade command is replaced with the
# RESOLVED binary path, so a CLI found outside ~/.local/bin still
# upgrades itself rather than a hardcoded path that doesn't exist.
update_cli() {
  local name="$1" bin="$2" cmd="$3" install_cmd="${4:-}" before="" after=""
  if [ ! -x "$bin" ]; then
    bin="$(command -v "$bin" 2>/dev/null || true)"
    [ -n "$bin" ] || { offer_install "$name" "$install_cmd"; return 0; }
  fi
  cmd="${cmd//%BIN%/$bin}"
  before="$("$bin" --version 2>/dev/null | head -1)"
  if $RUN_TIMEOUT bash -c "$cmd" >"$LOG" 2>&1; then
    after="$("$bin" --version 2>/dev/null | head -1)"
    if [ -n "$after" ] && [ "$after" = "$before" ]; then
      ok "$name: already latest (${after})"
    else
      ok "$name: ${before:-?} → ${after:-?}"
    fi
  else
    warn "$name upgrade failed — last output:"
    tail -n 5 "$LOG" | sed 's/^/      /'
    FAILED="$FAILED $name"
  fi
}

# CODEX_NON_INTERACTIVE=1 answers "no" to the installer's tty prompts
# ("Start Codex now?") — otherwise it grabs /dev/tty, and launching
# Codex makes the launch's exit status masquerade as an install failure.
# The installer doubles as the updater.
CODEX_INSTALL="curl $CURL_RETRY -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"
update_cli "codex" "$HOME/.local/bin/codex" "$CODEX_INSTALL" "$CODEX_INSTALL"

# cursor-agent needs the macOS login keychain, which is locked over
# SSH — a doomed attempt would just pollute the report every run.
if [ "$(uname -s)" = "Darwin" ] && [ -n "${SSH_CONNECTION:-}" ] \
   && ! security show-keychain-info >/dev/null 2>&1; then
  skip "cursor-agent: login keychain locked over SSH — update from a local session"
else
  update_cli "cursor-agent" "$HOME/.local/bin/cursor-agent" \
    "\"%BIN%\" update" \
    "curl $CURL_RETRY -fsSL https://cursor.com/install | bash"
fi

# https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli
# NON_INTERACTIVE + SKIP_PATH_PROMPT: the installer otherwise prompts
# "add .local/bin to PATH? [y/N]" on /dev/tty and dies without one.
update_cli "cortex" "$HOME/.local/bin/cortex" \
  "\"%BIN%\" update" \
  "curl $CURL_RETRY -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | NON_INTERACTIVE=1 SKIP_PATH_PROMPT=1 sh"

# opencode's installer dir varies between versions.
OPENCODE_INSTALL="curl $CURL_RETRY -fsSL https://opencode.ai/install | bash"
OPENCODE_BIN=""
for p in "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"; do
  [ -x "$p" ] && { OPENCODE_BIN="$p"; break; }
done
[ -z "$OPENCODE_BIN" ] && OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
if [ -n "$OPENCODE_BIN" ]; then
  update_cli "opencode" "$OPENCODE_BIN" "\"%BIN%\" upgrade || $OPENCODE_INSTALL"
else
  offer_install "opencode" "$OPENCODE_INSTALL"
fi

# gemini is npm-installed on the fleet but may be brew-managed locally;
# upgrading the wrong way would leave two copies fighting over PATH.
# Fresh installs prefer brew when it exists, npm otherwise.
GEMINI_UPGRADE="npm install -g @google/gemini-cli@latest"
GEMINI_INSTALL="npm install -g @google/gemini-cli@latest"
if command -v brew >/dev/null 2>&1; then
  GEMINI_INSTALL="brew install gemini-cli"
  brew list --formula gemini-cli >/dev/null 2>&1 && GEMINI_UPGRADE="brew upgrade gemini-cli"
fi
update_cli "gemini" "gemini" "$GEMINI_UPGRADE" "$GEMINI_INSTALL"

# headroom is pipx-managed; `headroom update` confirms on a tty, so
# drive pipx directly. Resolve pipx by absolute path — Ansible/cron
# shells are non-login, so brew's bin dir may be off PATH. An
# already-running proxy keeps serving the old code after an upgrade —
# warn instead of restarting it, since other CLIs may be mid-stream
# through it.
PIPX="$(command -v pipx 2>/dev/null || true)"
if [ -z "$PIPX" ]; then
  for p in /opt/homebrew/bin/pipx /usr/local/bin/pipx "$HOME/.local/bin/pipx"; do
    [ -x "$p" ] && { PIPX="$p"; break; }
  done
fi
if [ -n "$PIPX" ]; then
  update_cli "headroom" "$HOME/.local/bin/headroom" \
    "\"$PIPX\" upgrade headroom-ai" \
    "\"$PIPX\" install 'headroom-ai[all]'"
elif [ -x "$HOME/.local/bin/headroom" ]; then
  warn "headroom installed but pipx not found — can't upgrade it"
else
  skip "headroom skipped (pipx not available)"
fi
HEADROOM_BIN="$HOME/.local/bin/headroom"
[ -x "$HEADROOM_BIN" ] || HEADROOM_BIN="$(command -v headroom 2>/dev/null || true)"
if [ -n "$HEADROOM_BIN" ]; then
  HEADROOM_PORT="${HEADROOM_PORT:-8787}"
  proxy_ver="$(curl -m 2 -fsS "http://127.0.0.1:${HEADROOM_PORT}/health" 2>/dev/null \
    | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)"
  cli_ver="$("$HEADROOM_BIN" --version 2>/dev/null | awk '{print $NF}')"
  if [ -n "$proxy_ver" ] && [ -n "$cli_ver" ] && [ "$proxy_ver" != "$cli_ver" ]; then
    warn "headroom proxy on :${HEADROOM_PORT} still runs ${proxy_ver} — restart it to load ${cli_ver}"
  fi
fi

# 9router is not a local CLI — it's a Docker service (decolua/9router) on
# the aorus fleet, bound to 127.0.0.1:20128 there. Status report only:
# reachable directly on a fleet host, or via an SSH tunnel
# (ssh -N -L 20128:127.0.0.1:20128 <host>) from elsewhere. Updating it
# means re-running ansible-ai/deploy-9router.yml — never from here, since
# other CLIs may be mid-stream through the gateway.
NINEROUTER_PORT="${NINEROUTER_PORT:-20128}"
nine_ver_json="$(curl -m 2 -fsS "http://127.0.0.1:${NINEROUTER_PORT}/api/version" 2>/dev/null)"
if [ -n "$nine_ver_json" ]; then
  nine_cur="$(printf '%s' "$nine_ver_json" | grep -o '"currentVersion":"[^"]*"' | cut -d'"' -f4)"
  nine_latest="$(printf '%s' "$nine_ver_json" | grep -o '"latestVersion":"[^"]*"' | cut -d'"' -f4)"
  if printf '%s' "$nine_ver_json" | grep -q '"hasUpdate":true'; then
    warn "9router gateway on :${NINEROUTER_PORT} runs ${nine_cur:-?} — ${nine_latest:-newer} available (re-run ansible-ai/deploy-9router.yml)"
  else
    ok "9router: gateway up on :${NINEROUTER_PORT} (${nine_cur:-?}, latest)"
  fi
elif curl -m 2 -fsS "http://127.0.0.1:${NINEROUTER_PORT}/api/health" >/dev/null 2>&1; then
  ok "9router: gateway up on :${NINEROUTER_PORT}"
else
  skip "9router: not reachable on :${NINEROUTER_PORT} — Docker service on the fleet; update via ansible-ai/deploy-9router.yml"
fi

if [ -n "$FAILED" ]; then
  warn "Upgrades failed for:${FAILED}"
  exit 1
fi
