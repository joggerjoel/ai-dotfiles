#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# observability-tools.sh — put the two agent-observability tools on this
# machine and keep them buildable.
#
#   install   (default) clone or fast-forward both checkouts, build the
#             agenttrail Kitchen, install claude-tap as an editable uv tool.
#             Safe to re-run; every step converges rather than duplicating.
#   check     Read-only. Print the git HEAD of each checkout, the installed
#             claude-tap version, and whether the Kitchen graphics build
#             exists. Exit 1 if anything is missing.
#
# These are checkouts, not releases. Neither tool publishes a package this
# fleet can install, so the source tree on disk is the install, and `check`
# has to report a commit rather than a version number for them.
#
# The two are separate concerns that arrive together: claude-tap records what
# agents send to the model, agenttrail renders what they did with the answer.
# The launcher that runs them both lives in the herdr-orchestrator repository
# at ops/observability/obs.sh; this script only makes that launcher possible.
#
# Environment:
#   AI_3RDPARTY_ROOT   where both checkouts live (default ~/Developer/3rdparty)
# ─────────────────────────────────────────────────────────────────

AI_3RDPARTY_ROOT="${AI_3RDPARTY_ROOT:-$HOME/Developer/3rdparty}"

# shellcheck source=../lib/checkout.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/checkout.sh"

AGENTTRAIL_URL="https://github.com/sodiumsun/agenttrail.git"
CLAUDE_TAP_URL="https://github.com/liaohch3/claude-tap.git"
AGENTTRAIL_DIR="$AI_3RDPARTY_ROOT/agenttrail"
CLAUDE_TAP_DIR="$AI_3RDPARTY_ROOT/claude-tap"
KITCHEN_DIR="$AGENTTRAIL_DIR/packages/kitchen"
KITCHEN_BUILD="$KITCHEN_DIR/public/build"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'
RED='\033[31m'; RESET='\033[0m'
ok()     { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()   { echo -e "  ${YELLOW}!${RESET} $1"; }
fail()   { echo -e "  ${RED}✗${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "$1 is not on PATH; install it first"
    return 1
  }
}

# ── The uv invocation (pure) ─────────────────────────────────────
# Printed one argv element per line so the tests can assert on it without
# running an install.

# `uv` on PATH here is a pyenv shim, and claude-tap's .python-version asks for
# a 3.13 this machine does not have, so the shim refuses before uv ever runs.
# Pinning PYENV_VERSION to an installed interpreter gets past the shim, and
# --python tells uv which one to build the tool against. A machine with no
# pyenv has no shim and wants plain uv.
pyenv_python() {
  command -v pyenv >/dev/null 2>&1 || return 1
  local installed configured
  installed="$(pyenv versions --bare 2>/dev/null | grep -E '^3\.[0-9]+\.[0-9]+$' || true)"
  [ -n "$installed" ] || return 1
  configured="$(pyenv global 2>/dev/null | grep -m1 -E '^3\.[0-9]+\.[0-9]+$' || true)"
  # pyenv global can name a version that was never installed, which is exactly
  # the state that produces the shim failure this function exists to avoid.
  if [ -n "$configured" ] && printf '%s\n' "$installed" | grep -qx "$configured"; then
    printf '%s\n' "$configured"
  else
    printf '%s\n' "$installed" | tail -1
  fi
}

uv_install_cmd() {
  local version
  if version="$(pyenv_python)"; then
    printf '%s\n' env "PYENV_VERSION=$version" uv tool install \
      --python "${version%.*}" --editable . --reinstall
  else
    printf '%s\n' uv tool install --editable . --reinstall
  fi
}

# ── install ──────────────────────────────────────────────────────

cmd_install() {
  need git || exit 1
  need bun || exit 1
  need uv || exit 1

  header "Checkouts"
  clone_or_pull "$AGENTTRAIL_URL" "$AGENTTRAIL_DIR" agenttrail
  clone_or_pull "$CLAUDE_TAP_URL" "$CLAUDE_TAP_DIR" claude-tap

  header "Kitchen build"
  ( cd "$KITCHEN_DIR" && bun install && bun run build ) >/dev/null
  if [ -d "$KITCHEN_BUILD" ]; then
    ok "graphics build present at ${KITCHEN_BUILD#"$HOME"/}"
  else
    fail "bun run build left no $KITCHEN_BUILD"
    exit 1
  fi

  header "claude-tap"
  local argv=()
  while IFS= read -r line; do argv+=("$line"); done < <(uv_install_cmd)
  ( cd "$CLAUDE_TAP_DIR" && "${argv[@]}" ) >/dev/null
  ok "installed as an editable uv tool: $(claude-tap --version 2>&1 | head -1)"

  header "Next"
  echo -e "  ${DIM}Start the boards with herdr-orchestrator's ops/observability/obs.sh up${RESET}"
}

# ── check ────────────────────────────────────────────────────────

cmd_check() {
  local problems=0 dir name

  header "Checkouts"
  for dir in "$AGENTTRAIL_DIR" "$CLAUDE_TAP_DIR"; do
    name="$(basename "$dir")"
    if [ -d "$dir/.git" ]; then
      ok "$name $(git -C "$dir" rev-parse --short HEAD) on $(git -C "$dir" rev-parse --abbrev-ref HEAD)"
    else
      fail "$name is not checked out at $dir"
      problems=$((problems + 1))
    fi
  done

  header "Kitchen build"
  if [ -d "$KITCHEN_BUILD" ]; then
    ok "graphics build present"
  else
    fail "no graphics build at $KITCHEN_BUILD; the Kitchen will serve a blank page"
    problems=$((problems + 1))
  fi

  header "claude-tap"
  if command -v claude-tap >/dev/null 2>&1; then
    ok "$(claude-tap --version 2>&1 | head -1)"
  else
    fail "claude-tap is not on PATH"
    problems=$((problems + 1))
  fi

  echo
  if [ "$problems" -eq 0 ]; then
    ok "every observability tool is present and built"
  else
    fail "$problems problem(s); run: scripts/observability-tools.sh install"
    return 1
  fi
}

usage() {
  echo "Usage: observability-tools.sh [install|check]"
  echo "  install  clone/update both tools, build the Kitchen, install claude-tap (default)"
  echo "  check    read-only report of what is on this machine; exits 1 if anything is missing"
}

# Guarded so the tests can source this file and drive uv_install_cmd without
# cloning anything.
main() {
  case "${1:-install}" in
    install) cmd_install ;;
    check)   cmd_check ;;
    *)       usage; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
