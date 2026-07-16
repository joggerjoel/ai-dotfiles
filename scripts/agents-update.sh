#!/bin/bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────
# agents-update.sh — upgrade the sibling agent CLIs, when installed:
#   codex (OpenAI), cursor-agent (Cursor), opencode, gemini (Google),
#   cortex (Snowflake Cortex Code).
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
# stay unattended, so missing CLIs are skipped there.
INTERACTIVE="no"
[ -t 0 ] && [ -e /dev/tty ] && INTERACTIVE="yes"

# offer_install <name> <install command>
# Interactive runs get a y/N offer to install a missing CLI; anything
# else (no tty, no install command) just reports the skip.
offer_install() {
  local name="$1" cmd="${2:-}" answer="" ver=""
  if [ "$INTERACTIVE" != "yes" ] || [ -z "$cmd" ]; then
    skip "$name not installed"
    return 0
  fi
  printf "  ${DIM}○${RESET} %s not installed — install it? [y/N] " "$name"
  IFS= read -r answer </dev/tty || answer=""   # EOF-tolerant
  case "$answer" in
    y | Y | yes | YES) ;;
    *) skip "$name skipped"; return 0 ;;
  esac
  if bash -c "$cmd" >"$LOG" 2>&1; then
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
# they fail).
update_cli() {
  local name="$1" bin="$2" cmd="$3" install_cmd="${4:-}" before="" after=""
  if [ ! -x "$bin" ]; then
    bin="$(command -v "$bin" 2>/dev/null || true)"
    [ -n "$bin" ] || { offer_install "$name" "$install_cmd"; return 0; }
  fi
  before="$("$bin" --version 2>/dev/null | head -1)"
  if bash -c "$cmd" >"$LOG" 2>&1; then
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

update_cli "cursor-agent" "$HOME/.local/bin/cursor-agent" \
  "\"$HOME/.local/bin/cursor-agent\" update" \
  "curl $CURL_RETRY -fsSL https://cursor.com/install | bash"

# https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code-cli
update_cli "cortex" "$HOME/.local/bin/cortex" \
  "\"$HOME/.local/bin/cortex\" update" \
  "curl $CURL_RETRY -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh"

# opencode's installer dir varies between versions.
OPENCODE_INSTALL="curl $CURL_RETRY -fsSL https://opencode.ai/install | bash"
OPENCODE_BIN=""
for p in "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"; do
  [ -x "$p" ] && { OPENCODE_BIN="$p"; break; }
done
[ -z "$OPENCODE_BIN" ] && OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
if [ -n "$OPENCODE_BIN" ]; then
  update_cli "opencode" "$OPENCODE_BIN" "\"$OPENCODE_BIN\" upgrade || $OPENCODE_INSTALL"
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

if [ -n "$FAILED" ]; then
  warn "Upgrades failed for:${FAILED}"
  exit 1
fi
