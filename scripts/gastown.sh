#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# gastown.sh — put Gas Town (the `gt` multi-agent workspace manager) on this
# machine from source and keep it current.
#
#   install   (default) clone or fast-forward the checkout, install the host
#             tools gt needs, then build and install gt through the upstream
#             Makefile. Safe to re-run; every step converges.
#   check     Read-only. Print the checkout HEAD, the installed gt commit, and
#             each host tool. Exit 1 if a tool is missing or gt is not built
#             from the checkout's HEAD.
#
# A checkout, not a release, like the other tools under AI_3RDPARTY_ROOT: the
# source tree is the version of record and `check` compares the binary to it.
# `make install` is the upstream install path and does more than `go build`:
# it restarts the gt daemon and syncs the plugin directory, both of which drift
# silently when skipped.
#
# The herdr side lives in herdr-orchestrator at ops/gastown/gt-herdr.sh. That
# launcher puts a town's agents in herdr's sidebar; this script only makes it
# possible.
#
# Environment:
#   AI_3RDPARTY_ROOT   where the checkout lives (default ~/Developer/3rdparty)
#   GT_INSTALL_DIR     where the Makefile puts gt (default ~/.local/bin, its own)
# ─────────────────────────────────────────────────────────────────

AI_3RDPARTY_ROOT="${AI_3RDPARTY_ROOT:-$HOME/Developer/3rdparty}"
GT_INSTALL_DIR="${GT_INSTALL_DIR:-$HOME/.local/bin}"

GASTOWN_URL="https://github.com/gastownhall/gastown.git"
GASTOWN_DIR="$AI_3RDPARTY_ROOT/gastown"
BEADS_MODULE="github.com/steveyegge/beads/cmd/bd@latest"

# shellcheck source=../lib/checkout.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/checkout.sh"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'
RED='\033[31m'; RESET='\033[0m'
ok()     { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()   { echo -e "  ${YELLOW}!${RESET} $1"; }
fail()   { echo -e "  ${RED}✗${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

# ── Host tools (pure) ────────────────────────────────────────────
# Everything gt needs at runtime, per its README prerequisites table, plus
# what the source build needs. One row per tool: name|how this script gets it.
#   brew    a Homebrew formula of the same name (macOS)
#   go      `go install` of BEADS_MODULE
#   manual  reported only; agents-update.sh owns the agent CLIs
TOOLS="git|manual
go|manual
make|manual
sqlite3|manual
tmux|brew
dolt|brew
bd|go
claude|manual"

missing_tools() {
  local row name
  for row in $TOOLS; do
    name="${row%%|*}"
    command -v "$name" >/dev/null 2>&1 || printf '%s\n' "$name"
  done
}

# The action for each missing tool, one "<how> <name>" per line, so the tests
# can assert on the plan without installing anything.
install_plan() {
  local name row
  for name in "$@"; do
    for row in $TOOLS; do
      [ "${row%%|*}" = "$name" ] && printf '%s %s\n' "${row#*|}" "$name"
    done
  done
}

# `gt version --verbose` prints the build commit after an @, in both the dev
# ("main@649b832") and the tagged ("v0.9.0 (main@abc1234)") formats. The
# Makefile's own forward-only check reads it the same way.
parse_gt_commit() {
  printf '%s\n' "$1" | grep -o '@[a-f0-9]*' | head -1 | tr -d '@'
}

installed_gt_commit() {
  command -v gt >/dev/null 2>&1 || return 1
  parse_gt_commit "$(gt version --verbose 2>/dev/null || true)"
}

# ── install ──────────────────────────────────────────────────────

install_tools() {
  local plan how name problems=0
  plan="$(install_plan "$@")"
  [ -n "$plan" ] || { ok "every host tool is present"; return 0; }
  while read -r how name; do
    case "$how" in
      brew)
        if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
          if brew install "$name" >/dev/null 2>&1; then ok "$name installed with brew"
          else fail "brew install $name failed"; problems=$((problems + 1)); fi
        else
          fail "$name is missing; install it with your package manager"
          problems=$((problems + 1))
        fi ;;
      go)
        if go install "$BEADS_MODULE" >/dev/null 2>&1; then ok "$name installed with go install"
        else fail "go install $BEADS_MODULE failed"; problems=$((problems + 1)); fi ;;
      *)
        fail "$name is missing and this script does not install it"
        problems=$((problems + 1)) ;;
    esac
  done <<< "$plan"
  return "$problems"
}

cmd_install() {
  header "Checkout"
  command -v git >/dev/null 2>&1 || { fail "git is not on PATH"; exit 1; }
  clone_or_pull "$GASTOWN_URL" "$GASTOWN_DIR" gastown
  # A shallow clone has no tags, so the Makefile stamps the binary with a bare
  # commit and its forward-only check cannot walk history. Deepen it once.
  if [ -f "$GASTOWN_DIR/.git/shallow" ]; then
    git -C "$GASTOWN_DIR" fetch --unshallow --tags --quiet && ok "history deepened for version stamping"
  fi

  header "Host tools"
  local missing
  missing="$(missing_tools | tr '\n' ' ')"
  # shellcheck disable=SC2086
  install_tools $missing || exit 1
  if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1 \
     && ! brew --prefix icu4c >/dev/null 2>&1; then
    # Keg-only, so nothing but the Makefile's CGo flags ever finds it; gt's
    # query layer will not link without it.
    brew install icu4c >/dev/null 2>&1 && ok "icu4c installed for the source build"
  fi

  header "Build and install"
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/gastown-make.XXXXXX")"
  if make -C "$GASTOWN_DIR" install INSTALL_DIR="$GT_INSTALL_DIR" >"$log" 2>&1; then
    ok "gt $(installed_gt_commit || echo '?') installed to ${GT_INSTALL_DIR#"$HOME"/}"
    rm -f "$log"
  else
    fail "make install failed; last lines:"
    tail -20 "$log" | sed 's/^/      /'
    rm -f "$log"
    exit 1
  fi

  header "Next"
  echo -e "  ${DIM}gt install ~/gt        create a town${RESET}"
  echo -e "  ${DIM}ops/gastown/gt-herdr.sh up   (herdr-orchestrator) start it with its agents in herdr${RESET}"
}

# ── check ────────────────────────────────────────────────────────

# Short hashes come in different lengths (git describe, rev-parse --short,
# the Makefile stamp), so two commits match when either is a prefix of the other.
same_commit() {
  [ "${1#"$2"}" != "$1" ] || [ "${2#"$1"}" != "$2" ]
}

cmd_check() {
  local problems=0 missing=0 head="" binary name

  header "Checkout"
  if [ -d "$GASTOWN_DIR/.git" ]; then
    head="$(git -C "$GASTOWN_DIR" rev-parse --short HEAD)"
    ok "gastown $head on $(git -C "$GASTOWN_DIR" rev-parse --abbrev-ref HEAD)"
  else
    fail "gastown is not checked out at $GASTOWN_DIR"
    problems=$((problems + 1))
  fi

  header "gt"
  if binary="$(installed_gt_commit)" && [ -n "$binary" ]; then
    if [ -z "$head" ] || same_commit "$binary" "$head"; then
      ok "$(gt version 2>/dev/null | head -1) at $(command -v gt)"
    else
      fail "gt is built from $binary but the checkout is at $head"
      problems=$((problems + 1))
    fi
  else
    fail "gt is not on PATH"
    problems=$((problems + 1))
  fi

  header "Host tools"
  for name in $(missing_tools); do
    fail "$name is not on PATH"
    missing=$((missing + 1))
  done
  [ "$missing" -eq 0 ] && ok "git, go, make, sqlite3, tmux, dolt, bd and claude present"
  problems=$((problems + missing))

  echo
  if [ "$problems" -eq 0 ]; then
    ok "gt is built from the checkout and every host tool is present"
  else
    fail "$problems problem(s); run: scripts/gastown.sh install"
    return 1
  fi
}

usage() {
  echo "Usage: gastown.sh [install|check]"
  echo "  install  clone/update the checkout, install host tools, build and install gt (default)"
  echo "  check    read-only report of what is on this machine; exits 1 if anything is off"
}

# Guarded so the tests can source this file and drive the pure functions
# without cloning or building anything.
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
