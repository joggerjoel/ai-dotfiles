#!/usr/bin/env bash
# install-orca.sh — converge Orca (Stably AI's IDE for orchestrating coding
# agents; Homebrew cask stablyai/orca/orca) to "brew-managed, at or above the
# cask's version, with its bundled agent skills installed". macOS only.
#
# One script because three callers need the same decision: setup.sh (this
# box), scripts/agents-update.sh (every update run, local and fleet) and
# ansible-ai/provision-orca.yml (first install on the fleet Macs, which ships
# this file over ssh through the script module).
#
# What the tap README's `brew install --cask stablyai/orca/orca` gets wrong:
#   - Homebrew 7 refuses casks from an untrusted third-party tap and reports
#     it as "invalid syntax in tap", so the tap is trusted first. Idempotent;
#     the command is absent on older Homebrew, hence best-effort.
#   - A Mac that installed Orca from the DMG already has /Applications/Orca.app,
#     which a plain cask install refuses to overwrite.
#   - --adopt is the flag for that, but the cask is marked auto_updates, and
#     for those brew skips its version comparison: --adopt takes ANY existing
#     Orca.app and writes the cask's version into the receipt. macstudio had a
#     hand-installed 1.4.188; adopt recorded it as 1.4.203, and from then on
#     `brew upgrade --greedy` saw receipt == cask and did nothing, forever.
#     So the app bundle's own Info.plist is the version of record here, and
#     brew's receipt never is.
#   - A bare `orca` token is homebrew/cask's orca, Plotly's chart exporter.
#     Every brew call names the full token.
#
# Decision table (app = the bundle's CFBundleShortVersionString, cask = tap):
#   no app                          brew install            fresh
#   app behind cask, not managed    brew install --force    replace the stale app
#   app behind cask, brew-managed   brew reinstall          the receipt lies
#   app at/ahead, not managed       brew install --adopt    take ownership
#   app at/ahead, brew-managed      nothing                 current
# "Ahead" is adopted, never replaced: the in-app updater or an RC build can be
# past the tap, and forcing the cask would roll it back.
#
# The skills are the half that makes the app matter to an agent: without
# `orca-cli` and `orchestration` in the skill dirs, Claude and Codex do not know
# Orca exists. `orca skills install --all` resolves to the community skills CLI
# (`npx skills add stablyai/orca ...`), lands the bundled set in
# ~/.agents/skills and symlinks it into every detected harness (~/.claude/skills
# and the rest). It runs when any bundled skill is missing, or when the app
# moved this run, because the guides are version-matched to the CLI. It needs
# npx, so nvm is sourced for the non-login shells that lack it.
#
#   scripts/install-orca.sh           # converge
#   scripts/install-orca.sh --check   # report the state and the pending action;
#                                     # exit 1 when one is pending, install nothing
#
# ORCA_APP overrides the app path (default /Applications/Orca.app) so this can
# be tested without touching a real machine. Prints one summary line on
# stdout; brew's own output goes to stderr only on failure.
set -uo pipefail

CASK="stablyai/orca/orca"
TAP="stablyai/orca"
APP="${ORCA_APP:-/Applications/Orca.app}"
CHECK=no
[ "${1:-}" = "--check" ] && CHECK=yes

# Non-login shells (ansible, cron, the script module) lack brew's bin dir.
# Appended, not prepended, so a caller's PATH still wins (the test suite puts
# stubs there; prepending once let the real brew run under the tests).
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1

[ "$(uname -s)" = "Darwin" ] || { echo "orca: macOS only (Homebrew cask)"; exit 1; }
command -v brew >/dev/null 2>&1 || { echo "orca: brew not found"; exit 1; }

brew trust --tap "$TAP" >/dev/null 2>&1 || true
brew tap "$TAP" >/dev/null 2>&1 || true
cask_ver="$(brew info --cask "$CASK" 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"
[ -n "$cask_ver" ] || { echo "orca: cannot resolve the cask version (is tap $TAP reachable?)"; exit 1; }

app_ver=""
[ -d "$APP" ] && app_ver="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
managed=no
brew list --cask "$CASK" >/dev/null 2>&1 && managed=yes

# behind A B: true when A sorts strictly below B as a version.
behind() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

if [ -z "$app_ver" ]; then
  action="install"; verb="installed"
elif behind "$app_ver" "$cask_ver"; then
  if [ "$managed" = yes ]; then action="reinstall"; verb="reinstalled"
  else action="install --force"; verb="replaced"; fi
elif [ "$managed" = yes ]; then
  action=""; verb="current"
else
  action="install --adopt"; verb="adopted"
fi

# skills_missing: the bundled skill names absent from ~/.agents/skills, the
# canonical dir the skills CLI writes before symlinking into each harness.
# Needs the CLI, so after a fresh install this runs against the new binary.
skills_missing() {
  local name
  for name in $(orca skills list --json 2>/dev/null | grep -oE '"name": *"[^"]+"' | cut -d'"' -f4); do
    [ -f "$HOME/.agents/skills/$name/SKILL.md" ] || printf '%s ' "$name"
  done
}

if [ "$CHECK" = yes ]; then
  missing="$(command -v orca >/dev/null 2>&1 && skills_missing || echo "(no CLI yet)")"
  if [ -z "$action" ] && [ -z "$missing" ]; then
    echo "orca current ($app_ver, brew-managed); skills current"
    exit 0
  fi
  echo "orca ${app_ver:-absent} (cask $cask_ver, brew-managed: $managed)${action:+ — would run: brew $action --cask $CASK}${missing:+ — skills missing: $missing}"
  exit 1
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
if [ -z "$action" ]; then
  summary="orca current ($app_ver, brew-managed)"
else
  # shellcheck disable=SC2086  # $action is a verb plus an optional flag, split on purpose
  if brew $action --cask "$CASK" >"$LOG" 2>&1; then
    new_ver="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
    summary="orca $verb (${app_ver:+$app_ver → }${new_ver:-$cask_ver})"
  else
    echo "orca install failed — brew $action --cask $CASK"
    tail -n 5 "$LOG" >&2
    exit 1
  fi
fi

if ! command -v orca >/dev/null 2>&1; then
  echo "$summary; skills skipped (orca CLI not on PATH)"
  exit 1
fi
missing="$(skills_missing)"
if [ -z "$missing" ] && [ "$verb" = current ]; then
  echo "$summary; skills current"
elif orca skills install --all >"$LOG" 2>&1; then
  echo "$summary; skills installed (~/.agents/skills → every detected harness)"
else
  echo "$summary; skills install failed — orca skills install --all"
  tail -n 5 "$LOG" >&2
  exit 1
fi
