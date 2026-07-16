#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# deploy.sh — publish local changes and propagate to every target.
#
#   1. Commit (only when -m is given), then push main to origin.
#   2. Run ansible-ai/update.yml — every host (servers + this
#      machine) pulls the repo and re-applies its saved profile.
#
# Works from ANY directory: every path is resolved from this
# script's own location, never from $PWD — so a stray `cd /tmp`
# can't break the deploy.
#
# Usage:
#   ./deploy.sh                        # push what's committed + fleet update
#   ./deploy.sh -m "fix: thing"        # git add -A + commit + push + update
#   ./deploy.sh --check                # unknown args pass to ansible-playbook
#   ./deploy.sh -m "msg" --limit aorus7
# ─────────────────────────────────────────────────────────────────

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DOTFILES_DIR"

MSG=""
PLAYBOOK_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message)
      [ $# -ge 2 ] || { fail "-m needs a commit message"; exit 1; }
      MSG="$2"; shift 2 ;;
    -h|--help)
      sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) PLAYBOOK_ARGS+=("$1"); shift ;;
  esac
done

header "Deploy: publish"

# ── 1. Commit (opt-in via -m) + push ─────────────────────────────
if [ -n "$MSG" ]; then
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -m "$MSG"
    ok "Committed: $MSG"
  else
    skip "Nothing to commit"
  fi
elif [ -n "$(git status --porcelain)" ]; then
  fail "Uncommitted changes in $DOTFILES_DIR"
  echo -e "  ${DIM}Commit them with:  ./deploy.sh -m \"your message\"   (runs git add -A)${RESET}"
  exit 1
fi

if git push origin main; then
  ok "Pushed to origin/main"
else
  fail "Push failed — if history was rewritten, re-sync first:"
  echo -e "  ${DIM}git fetch origin && git checkout -B main origin/main${RESET}"
  exit 1
fi

# ── 2. Propagate to the fleet ────────────────────────────────────
header "Deploy: propagate (ansible-ai/update.yml)"
INV="$DOTFILES_DIR/ansible-ai/inventory.local.yml"
if [ ! -f "$INV" ]; then
  fail "No inventory at ansible-ai/inventory.local.yml"
  echo -e "  ${DIM}Bootstrap it:  cp ansible-ai/inventory.example.yml ansible-ai/inventory.local.yml${RESET}"
  exit 1
fi

cd "$DOTFILES_DIR/ansible-ai"
# bash 3.2-safe expansion of a possibly-empty array under set -u:
exec ansible-playbook update.yml ${PLAYBOOK_ARGS[@]+"${PLAYBOOK_ARGS[@]}"}
