#!/usr/bin/env bash
# provision-firstmate-worker.sh — turn a host into a firstmate WORKER: a place
# to run persistent, attachable agent sessions (herdr) that a crewmate reaches
# over SSH, or that you attach to hands-on. NOT a node: no orchestrator toolchain
# (treehouse/no-mistakes/axi), no firstmate clone. Just herdr + the harnesses.
#
# Idempotent, fail-loud, PATH-hardened for non-login shells (ansible/cron).
#
#   ./scripts/provision-firstmate-worker.sh
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
header(){ echo -e "\n${BOLD}$1${RESET}"; }

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_BIN="$HOME/.local/bin"; mkdir -p "$LOCAL_BIN"
MISSING=""
IS_MAC=no; [ "$(uname -s)" = "Darwin" ] && IS_MAC=yes
# PATH hardening (see provision-firstmate.sh): brew, ~/.local/bin, bun, opencode, npm globals.
export PATH="$LOCAL_BIN:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.bun/bin:$HOME/.opencode/bin:$PATH"
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
need() { command -v "$1" >/dev/null 2>&1; }

# ── herdr (persistent attachable sessions — the point of a worker) ──
header "herdr"
if need herdr; then ok "herdr present ($(herdr --version 2>/dev/null | awk '{print $NF}'))"
elif [ "$IS_MAC" = yes ] && need brew; then
  brew install herdr >/dev/null 2>&1 && ok "herdr installed (brew)" || { fail "herdr brew install failed"; MISSING="$MISSING herdr"; }
else
  # Linux (aorus): official curl installer → ~/.local/bin (or /usr/local/bin).
  curl -fsSL https://herdr.dev/install.sh | sh >/dev/null 2>&1
  hash -r 2>/dev/null || true
  if need herdr; then ok "herdr installed (curl)"; else fail "herdr install failed — see https://herdr.dev/docs/install"; MISSING="$MISSING herdr"; fi
fi

# ── Harnesses (ensure current; direct-install the npm ones) ──────
header "Harnesses"
if [ -x "$DOTFILES_DIR/scripts/agents-update.sh" ]; then
  AGENTS_AUTO_INSTALL=1 "$DOTFILES_DIR/scripts/agents-update.sh" >/dev/null 2>&1 || true
fi
ensure_harness() { local name="$1" cmd="$2"; if need "$name"; then ok "$name present"; return 0; fi; warn "$name missing — installing…"; eval "$cmd" >/dev/null 2>&1 || true; hash -r 2>/dev/null || true; if need "$name"; then ok "$name installed"; else warn "$name unavailable (non-fatal)"; fi; }
need claude && ok "claude present" || { fail "claude missing (provision ai-dotfiles first)"; MISSING="$MISSING claude"; }
need codex  && ok "codex present"  || warn "codex missing (non-fatal)"
ensure_harness pi   "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
ensure_harness grok "npm install -g @xai-official/grok@latest"

# ── Verify + report ──────────────────────────────────────────────
header "Verification"
for t in herdr claude; do need "$t" && ok "$t" || { fail "$t MISSING"; MISSING="$MISSING $t"; }; done

echo
if [ -n "$MISSING" ]; then
  fail "Worker NOT ready — missing:${MISSING}"
  exit 1
fi
ok "firstmate worker ready. Attach a persistent session: 'ssh <host>' then 'herdr'."
