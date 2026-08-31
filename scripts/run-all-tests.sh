#!/usr/bin/env bash
# run-all-tests.sh — every test suite in this repo, one command.
#
# The single source of truth for "did I break anything": `just test-all` and CI
# both call this, so the two cannot drift. The suite list is globbed rather than
# written down: it was a hand-kept transcription of exactly that glob, and
# herdr-tabwatch.test.sh sat outside it from the day it was written, passing
# locally and guarding nothing. A list someone has to remember to append is a
# convention, and this repo has already proved the convention does not hold.
#
# Deliberately NOT `set -e`: one failing suite must not hide the others. Results
# are collected and the exit status is set at the end.
#
# Runs under bash 3.2 (stock macOS) as well as bash 5 — no associative arrays,
# no mapfile. Keep it that way; contributors on a stock Mac are the common case.
set -uo pipefail

DOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DOT" || exit 1

# preflight names itself; every other suite is a *.test.sh and is found. Left as
# patterns for the loop below to expand, not captured through `ls`: an unmatched
# pattern then survives as itself, misses the -f test, and is reported as a
# missing suite. Captured output would collapse to the empty string and the
# runner would exit 0 having run only preflight.
SUITES="tests/preflight/run.sh hooks/*.test.sh scripts/*.test.sh"

if [ -t 1 ]; then BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else BOLD=""; RED=""; GREEN=""; DIM=""; RESET=""; fi

total_pass=0
total_fail=0
failed_suites=""
missing=""

printf '%s\n' "${BOLD}Test suites${RESET}"

for suite in $SUITES; do
  if [ ! -f "$suite" ]; then
    missing="$missing $suite"
    printf '  %s?%s  %-34s %s\n' "$RED" "$RESET" "$(basename "$suite")" "${DIM}not found${RESET}"
    continue
  fi

  out="$(bash "$suite" 2>&1)"
  rc=$?

  # Suites report "N passed, M failed" on their last summary line.
  p="$(printf '%s' "$out" | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+')"
  f="$(printf '%s' "$out" | grep -oE '[0-9]+ failed' | tail -1 | grep -oE '[0-9]+')"
  total_pass=$((total_pass + ${p:-0}))
  total_fail=$((total_fail + ${f:-0}))

  if [ "$rc" -eq 0 ]; then
    printf '  %s✓%s  %-34s %s passed\n' "$GREEN" "$RESET" "$(basename "$suite")" "${p:-?}"
  else
    failed_suites="$failed_suites $suite"
    printf '  %s✗%s  %-34s %s passed, %s failed\n' "$RED" "$RESET" "$(basename "$suite")" "${p:-?}" "${f:-?}"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

echo
printf '%s\n' "${BOLD}${total_pass} passed, ${total_fail} failed${RESET}"

if [ -n "$missing" ]; then
  printf '%s\n' "${RED}missing suites:${RESET}$missing"
  exit 1
fi
if [ -n "$failed_suites" ]; then
  printf '%s\n' "${RED}failed:${RESET}$failed_suites"
  exit 1
fi
exit 0
