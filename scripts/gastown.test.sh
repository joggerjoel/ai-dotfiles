#!/usr/bin/env bash
# Tests for scripts/gastown.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# The pure half (the tool table, the install plan, the commit parser) is what
# decides the script's behaviour, so the suite drives that against stub tools
# on PATH. Nothing clones, nothing builds, nothing reaches the network.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=gastown.sh
. "$ROOT/scripts/gastown.sh"
set +e
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gastown-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ (${2})}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

# A PATH holding only the named tools, so every assertion is about this
# script's table rather than about what this machine happens to carry.
fake_tools() {
  local dir="$TMP/$1"; shift
  mkdir -p "$dir"
  local t
  for t in "$@"; do printf '#!/bin/sh\n' >"$dir/$t"; chmod +x "$dir/$t"; done
  printf '%s\n' "$dir"
}
with_path() { PATH="$1" "${@:2}"; }

# --- the commit parser --------------------------------------------------------

eq "a dev build names its commit after the @" \
   "649b832" "$(parse_gt_commit 'gt version 649b832 (dev: main@649b832)')"
eq "a tagged build names the commit, not the tag" \
   "abc1234" "$(parse_gt_commit 'gt version v0.9.0 (main@abc1234, built 2026-09-15)')"
eq "no @ means no commit" "" "$(parse_gt_commit 'gt version unknown')"

# --- which commits count as the same -----------------------------------------

same_commit 649b832 649b832 && ok "equal hashes match" || ko "equal hashes match"
same_commit 649b832 649b832abcdef && ok "a short hash matches its long form" || ko "a short hash matches its long form"
same_commit 649b832abcdef 649b832 && ok "a long hash matches its short form" || ko "a long hash matches its short form"
same_commit 649b832 1111111 && ko "different hashes do not match" || ok "different hashes do not match"

# --- missing tools -------------------------------------------------------------

dir=$(fake_tools all git go make sqlite3 tmux dolt bd claude)
eq "a complete machine is missing nothing" "" "$(with_path "$dir" missing_tools | tr '\n' ' ')"

dir=$(fake_tools some git go make sqlite3 claude)
eq "the runtime tools gt up needs are reported in table order" \
   "tmux dolt bd " "$(with_path "$dir" missing_tools | tr '\n' ' ')"

# --- the install plan ----------------------------------------------------------
# tmux and dolt come from brew, bd from go install, and the agent CLI is owned
# by agents-update.sh, so the plan only reports it.

eq "each missing tool maps to how it is obtained" \
   "brew tmux|brew dolt|go bd|manual claude|" \
   "$(install_plan tmux dolt bd claude | tr '\n' '|')"
eq "an empty missing list is an empty plan" "" "$(install_plan)"

# --- check against a machine with nothing -------------------------------------
# Every failure is counted; nothing exits early, so the report is complete.

GASTOWN_DIR="$TMP/no-checkout"
dir=$(fake_tools bare)
out=$(with_path "$dir" cmd_check 2>&1); rc=$?
eq "check exits 1 on a bare machine" "1" "$rc"
printf '%s' "$out" | grep -q 'gastown is not checked out' && ok "check reports the missing checkout" || ko "check reports the missing checkout"
printf '%s' "$out" | grep -q 'gt is not on PATH' && ok "check reports the missing binary" || ko "check reports the missing binary"
printf '%s' "$out" | grep -q 'dolt is not on PATH' && ok "check reports a missing host tool" || ko "check reports a missing host tool"
printf '%s' "$out" | grep -q '10 problem' && ok "check counts every problem" || ko "check counts every problem" "$(printf '%s' "$out" | tail -1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
