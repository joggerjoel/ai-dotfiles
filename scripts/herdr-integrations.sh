#!/bin/bash
# herdr-integrations.sh — install or refresh herdr's agent integrations for the
# harnesses this repo deploys: pi, claude, codex, cursor, antigravity-cli, grok.
#
# `herdr integration install <target>` drops a hook script into the harness's
# config dir and registers it (claude: ~/.claude/settings.json SessionStart;
# codex: ~/.codex/hooks.json plus `[features] hooks = true`; cursor:
# ~/.cursor/hooks.json; antigravity-cli: ~/.gemini/config/hooks.json; grok:
# ~/.grok/hooks/herdr.json; pi: an extension .ts). herdr probes for the harness
# itself and exits 0 with "<x> directory not found ... install <x> first" when
# it is absent, so a host without a harness is a skip, never a failure.
#
# Install runs for every target on every pass, even when `herdr integration
# status` already says current. Status inspects only the hook SCRIPT, while the
# claude registration lives in settings.json — which here is the profile file
# behind a symlink. Fleet (vps) checkouts hard-reset that file on every
# `setup.sh update`, wiping the entry while the script still reads "current".
# Re-running install re-registers it; herdr dedupes its own entry, so repeated
# runs converge instead of stacking hooks.
#
# Single source of truth for the target list. Callers: setup.sh
# (ensure_herdr_integrations), ./update.sh, ansible-ai/provision-herdr.yml.
#
# Output: one line per target, then a summary line ansible's changed_when reads:
#   herdr-integrations: installed=N updated=N current=N skipped=N failed=N
# Exits 1 when any target failed, 0 otherwise. A missing herdr is a skip.

set -uo pipefail

HERDR_INTEGRATION_TARGETS="pi claude codex cursor antigravity-cli grok"

if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; DIM=""; RESET=""
fi
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
skip() { printf '  %s○ %s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }

installed=0 updated=0 current=0 skipped=0 failed=0

summary() {
  printf 'herdr-integrations: installed=%d updated=%d current=%d skipped=%d failed=%d\n' \
    "$installed" "$updated" "$current" "$skipped" "$failed"
}

if ! command -v herdr >/dev/null 2>&1; then
  skip "herdr not installed — integrations skipped"
  summary
  exit 0
fi

# One `herdr integration status` call covers every target. A line reads
#   claude: current (v11) (/path/to/hook)
#   omp: not installed (/path/to/hook)
#   letta (experimental): not installed (/path/to/hook)
# so the state is the text between ": " and the first " (", and the version is
# the first vN token when there is one.
status_snapshot() { herdr integration status 2>/dev/null; }

state_of() { # <snapshot> <target> → "current" | "not installed" | "outdated" | ...
  printf '%s\n' "$1" | awk -v t="$2" '
    index($0, t ": ") == 1 || index($0, t " (") == 1 {
      line = $0; sub(/^[^:]*: /, "", line); sub(/ \(.*$/, "", line); print line; exit
    }'
}

version_of() { # <snapshot> <target> → "v11" or ""
  printf '%s\n' "$1" | awk -v t="$2" '
    index($0, t ": ") == 1 || index($0, t " (") == 1 {
      if (match($0, /v[0-9]+/)) print substr($0, RSTART, RLENGTH); exit
    }'
}

before="$(status_snapshot)"

for target in $HERDR_INTEGRATION_TARGETS; do
  state_before="$(state_of "$before" "$target")"
  ver_before="$(version_of "$before" "$target")"
  out="$(herdr integration install "$target" 2>&1)"
  rc=$?
  last_line="$(printf '%s\n' "$out" | tail -n 1)"
  if [ "$rc" -ne 0 ]; then
    fail "$target: failed — ${last_line:-herdr exited $rc}"
    failed=$((failed + 1))
  elif printf '%s\n' "$out" | grep -q "not found"; then
    # "pi extension directory not found at ~/.pi/agent/extensions. install pi first"
    skip "$target: skipped (${last_line##*. })"
    skipped=$((skipped + 1))
  else
    after="$(status_snapshot)"
    ver_after="$(version_of "$after" "$target")"
    if [ "$state_before" = "not installed" ] || [ -z "$state_before" ]; then
      ok "$target: installed (${ver_after:-version unknown})"
      installed=$((installed + 1))
    elif [ "$ver_before" != "$ver_after" ]; then
      ok "$target: updated ${ver_before:-?} → ${ver_after:-?}"
      updated=$((updated + 1))
    else
      ok "$target: current (${ver_after:-version unknown})"
      current=$((current + 1))
    fi
  fi
done

summary
[ "$failed" -eq 0 ]
