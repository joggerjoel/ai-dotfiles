#!/usr/bin/env bash
# provision-firstmate.sh — stand up a firstmate NODE (the always-on box that
# runs first mate + crew). Installs the firstmate toolchain that ai-dotfiles'
# normal provisioning does NOT cover: herdr, the source-built Go/pnpm tools
# (treehouse, no-mistakes, the *-axi suite), and the firstmate clone itself.
# Harnesses (pi/grok/opencode/claude/codex) are delegated to agents-update.sh.
#
# Idempotent: skips anything already present at/above its version floor.
# Fail-loud: reports every gap; exits non-zero if a required tool is missing.
#
#   ./scripts/provision-firstmate.sh            # provision this machine as a node
#   FIRSTMATE_SRC_DIR=~/src ./scripts/provision-firstmate.sh
#
# Env:
#   FIRSTMATE_SRC_DIR   where toolchain source repos are cloned (default ~/Documents/Projects)
#   FIRSTMATE_DIR       firstmate clone path (default ~/firstmate)
#   NO_MISTAKES_TELEMETRY=off is exported for builds (opt out of vendor telemetry)
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
header(){ echo -e "\n${BOLD}$1${RESET}"; }

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${FIRSTMATE_SRC_DIR:-$HOME/Documents/Projects}"
FM_DIR="${FIRSTMATE_DIR:-$HOME/firstmate}"
LOCAL_BIN="$HOME/.local/bin"
GH_ORG="https://github.com/kunchenguid"
MISSING=""
mkdir -p "$LOCAL_BIN" "$SRC_DIR"
export NO_MISTAKES_TELEMETRY=off   # opt out of no-mistakes' Umami telemetry

# PATH hardening — ansible/cron/non-login shells miss brew, ~/.local/bin, bun,
# corepack, etc. Prepend the usual tool locations so `command -v` sees the real
# toolchain regardless of how this script was invoked (the fleet-proven fix).
export PATH="$LOCAL_BIN:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
# Load Homebrew's full shellenv when available (sets GOPATH-ish PATHs, etc.).
if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi

IS_MAC=no; [ "$(uname -s)" = "Darwin" ] && IS_MAC=yes

need() { command -v "$1" >/dev/null 2>&1; }

# ── Prerequisites ────────────────────────────────────────────────
header "Prerequisites"
for t in git node go; do
  need "$t" && ok "$t present" || { fail "$t missing — install it first (brew install $t)"; MISSING="$MISSING $t"; }
done
# pnpm via corepack (the axi tools ship pnpm lockfiles)
if need pnpm; then ok "pnpm present"
elif need corepack; then corepack enable pnpm >/dev/null 2>&1 && corepack prepare pnpm@latest --activate >/dev/null 2>&1 && need pnpm && ok "pnpm enabled via corepack" || { fail "pnpm unavailable (corepack failed)"; MISSING="$MISSING pnpm"; }
else fail "pnpm/corepack missing — install node with corepack"; MISSING="$MISSING pnpm"; fi
need gh && ok "gh present" || warn "gh missing — firstmate needs 'gh auth login' (install: brew install gh)"

# ── Harnesses (delegate to the ai-dotfiles roster) ───────────────
header "Harnesses (via agents-update.sh)"
if [ -x "$DOTFILES_DIR/scripts/agents-update.sh" ]; then
  AGENTS_AUTO_INSTALL=1 "$DOTFILES_DIR/scripts/agents-update.sh" >/dev/null 2>&1 \
    && ok "roster run (claude/codex/pi/grok/opencode…)" \
    || warn "agents-update.sh reported issues — re-run it directly to see them"
else
  warn "agents-update.sh not found — install pi/grok/opencode manually"
fi
for h in claude codex pi grok opencode; do
  need "$h" && ok "$h present" || { warn "$h missing"; MISSING="$MISSING $h"; }
done

# ── herdr (session backend the node runs) ────────────────────────
header "herdr (session backend)"
if need herdr; then ok "herdr present ($(herdr --version 2>/dev/null | awk '{print $NF}'))"
elif [ "$IS_MAC" = yes ] && need brew; then
  brew install herdr >/dev/null 2>&1 && ok "herdr installed (brew)" || { fail "herdr brew install failed"; MISSING="$MISSING herdr"; }
else
  curl -fsSL https://herdr.dev/install.sh | sh >/dev/null 2>&1 && need herdr && ok "herdr installed (curl)" || { fail "herdr install failed"; MISSING="$MISSING herdr"; }
fi

# ── Go tools: treehouse, no-mistakes (build from source) ─────────
# clone_build_go <repo> <bin-name> — clone/pull, `go build`, install to ~/.local/bin
clone_build_go() {
  local repo="$1" bin="$2" dir
  dir="$SRC_DIR/$repo"
  if need "$bin"; then ok "$bin present ($("$bin" --version 2>/dev/null | head -1 | awk '{print $NF}'))"; return 0; fi
  [ -d "$dir/.git" ] || git clone -q "$GH_ORG/$repo.git" "$dir" || { fail "$repo clone failed"; MISSING="$MISSING $bin"; return 1; }
  git -C "$dir" pull -q --ff-only 2>/dev/null || true
  ( cd "$dir" && { [ -f Makefile ] && make build || go build -o "bin/$bin" ./... ; } ) >/dev/null 2>&1
  local built; built="$(find "$dir/bin" -maxdepth 1 -name "$bin" -type f 2>/dev/null | head -1)"
  [ -z "$built" ] && built="$(find "$dir" -maxdepth 1 -name "$bin" -type f 2>/dev/null | head -1)"
  if [ -n "$built" ]; then cp "$built" "$LOCAL_BIN/$bin" && chmod +x "$LOCAL_BIN/$bin" && ok "$bin built + installed"; else fail "$repo build produced no '$bin' binary"; MISSING="$MISSING $bin"; fi
}

header "Go tools (treehouse, no-mistakes)"
clone_build_go treehouse   treehouse
clone_build_go no-mistakes no-mistakes

# ── pnpm axi tools: build from source, symlink dist bin ──────────
# clone_build_axi <repo> — clone/pull, pnpm install+build, symlink bin (path from package.json)
clone_build_axi() {
  local repo="$1" dir
  dir="$SRC_DIR/$repo"
  if need "$repo"; then ok "$repo present ($("$repo" --version 2>/dev/null | head -1))"; return 0; fi
  [ -d "$dir/.git" ] || git clone -q "$GH_ORG/$repo.git" "$dir" || { fail "$repo clone failed"; MISSING="$MISSING $repo"; return 1; }
  git -C "$dir" pull -q --ff-only 2>/dev/null || true
  ( cd "$dir" && pnpm install --frozen-lockfile && pnpm run build ) >/dev/null 2>&1 || { fail "$repo build failed"; MISSING="$MISSING $repo"; return 1; }
  local binpath; binpath="$(cd "$dir" && node -e "const b=require('./package.json').bin;process.stdout.write(typeof b==='string'?b:(b['$repo']||Object.values(b)[0]))" 2>/dev/null)"
  if [ -n "$binpath" ] && [ -f "$dir/$binpath" ]; then chmod +x "$dir/$binpath" && ln -sfn "$dir/$binpath" "$LOCAL_BIN/$repo" && ok "$repo built + linked"; else fail "$repo: no bin at package.json bin path"; MISSING="$MISSING $repo"; fi
}

header "axi tools (pnpm build)"
for a in tasks-axi quota-axi gh-axi chrome-devtools-axi lavish-axi; do clone_build_axi "$a"; done

# ── firstmate clone ──────────────────────────────────────────────
header "firstmate clone"
if [ -d "$FM_DIR/.git" ]; then ok "firstmate present at $FM_DIR"
else git clone -q "$GH_ORG/firstmate.git" "$FM_DIR" && ok "firstmate cloned → $FM_DIR" || { fail "firstmate clone failed"; MISSING="$MISSING firstmate"; }; fi

# ── Verify + report ──────────────────────────────────────────────
header "Verification"
for t in herdr treehouse no-mistakes tasks-axi quota-axi gh-axi chrome-devtools-axi lavish-axi jq; do
  need "$t" && ok "$t" || { fail "$t MISSING"; MISSING="$MISSING $t"; }
done
[ -d "$FM_DIR/.git" ] && ok "firstmate clone" || { fail "firstmate clone MISSING"; MISSING="$MISSING firstmate"; }

echo
if [ -n "$MISSING" ]; then
  fail "Node NOT ready — missing:${MISSING}"
  echo -e "  ${DIM}Fix the above, then re-run. gh auth: run 'gh auth login' if firstmate reports it.${RESET}"
  exit 1
fi
ok "firstmate node provisioned. Next: 'gh auth login' (if needed), then launch a harness inside $FM_DIR."
