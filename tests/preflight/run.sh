#!/bin/bash
# Pre-flight checker test harness. Runs offline: `claude` is stubbed on PATH
# and every filesystem path the checker reads is redirected at a fixture.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
PASS=0
FAIL=0

report() {
  if [ "$1" = "pass" ]; then
    PASS=$((PASS + 1)); echo "  ok   $2"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $2"
    [ -n "${3:-}" ] && echo "       $3"
  fi
}

# Run preflight.sh against a named fixture. Echoes stdout; returns its exit code.
run_preflight() {
  local fixture="$1"; shift
  PATH="$TESTS_DIR/stubs:$PATH" \
  PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/$fixture" \
  PREFLIGHT_CLAUDE_JSON="$TESTS_DIR/fixtures/$fixture/claude.json" \
  PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/$fixture/settings.json" \
  PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/$fixture/env" \
  PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/$fixture/skills" \
  PREFLIGHT_SMOKE_DIR="$TESTS_DIR/fixtures/$fixture/smoke" \
    bash "$REPO_DIR/scripts/preflight.sh" "$@"
}

echo "preflight tests"

# --- negative control -------------------------------------------------------
# An all-healthy fixture MUST produce exit 0 and zero findings. Without this,
# a checker that silently does nothing looks identical to a clean environment.
out=$(run_preflight healthy 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  report pass "healthy fixture exits 0"
else
  report fail "healthy fixture exits 0" "got rc=$rc, output: $out"
fi

if ! grep -qE '✘|FAIL' <<<"$out"; then
  report pass "healthy fixture reports no failures"
else
  report fail "healthy fixture reports no failures" "$out"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
