#!/bin/bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────
# agents-update.sh — upgrade the sibling agent CLIs, when installed:
#   codex (OpenAI), cursor-agent (Cursor), opencode, gemini (Google).
#
# Single source of truth for "update every AI CLI besides claude":
# called by ./update.sh locally and by ansible-ai/update.yml on the
# fleet. Missing CLIs are skipped; a failed upgrade warns and moves
# on to the next. Exits non-zero if any upgrade failed.
#
# Deliberately NOT `set -e` — one broken installer must not block
# the remaining CLIs; failures are collected and reported instead.
# ─────────────────────────────────────────────────────────────────

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
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

echo -e "${BOLD}Sibling agent CLIs${RESET}"

# update_cli <name> <binary path or command name> <upgrade command>
# Skips when the binary is absent; otherwise runs the upgrade and
# reports old → new version (installers are quiet unless they fail).
update_cli() {
  local name="$1" bin="$2" cmd="$3" before="" after=""
  if [ ! -x "$bin" ]; then
    bin="$(command -v "$bin" 2>/dev/null || true)"
    [ -n "$bin" ] || { skip "$name not installed"; return 0; }
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

update_cli "codex" "$HOME/.local/bin/codex" \
  "curl $CURL_RETRY -fsSL https://chatgpt.com/codex/install.sh | sh"

update_cli "cursor-agent" "$HOME/.local/bin/cursor-agent" \
  "\"$HOME/.local/bin/cursor-agent\" update"

# opencode's installer dir varies between versions.
OPENCODE_BIN=""
for p in "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode"; do
  [ -x "$p" ] && { OPENCODE_BIN="$p"; break; }
done
[ -z "$OPENCODE_BIN" ] && OPENCODE_BIN="$(command -v opencode 2>/dev/null || true)"
if [ -n "$OPENCODE_BIN" ]; then
  update_cli "opencode" "$OPENCODE_BIN" \
    "\"$OPENCODE_BIN\" upgrade || curl $CURL_RETRY -fsSL https://opencode.ai/install | bash"
else
  skip "opencode not installed"
fi

# gemini is npm-installed on the fleet but may be brew-managed locally;
# upgrading the wrong way would leave two copies fighting over PATH.
GEMINI_CMD="npm install -g @google/gemini-cli@latest"
if command -v brew >/dev/null 2>&1 && brew list --formula gemini-cli >/dev/null 2>&1; then
  GEMINI_CMD="brew upgrade gemini-cli"
fi
update_cli "gemini" "gemini" "$GEMINI_CMD"

if [ -n "$FAILED" ]; then
  warn "Upgrades failed for:${FAILED}"
  exit 1
fi
