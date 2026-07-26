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

# The healthy fixture's mcp-list.txt has exactly 3 servers (context7, github,
# firecrawl-mcp), all connected. Assert on the exact count and identity of
# passing MCP findings, not merely the absence of a "FAIL" string — a
# regression that makes probe_mcp silently emit nothing would still pass
# the weaker check above.
mcp_pass_count=$(grep -c '✔ mcp ' <<<"$out")
if [ "$mcp_pass_count" -eq 3 ]; then
  report pass "healthy fixture produces exactly 3 passing MCP findings"
else
  report fail "healthy fixture produces exactly 3 passing MCP findings" "got $mcp_pass_count, output: $out"
fi

for want in context7 github firecrawl-mcp; do
  if grep -q "✔ mcp $want\$" <<<"$out"; then
    report pass "healthy fixture reports $want as a passing MCP finding"
  else
    report fail "healthy fixture reports $want as a passing MCP finding" "$out"
  fi
done

# --- regression corpus: the four real failures of 2026-07-26 ----------------
out=$(run_preflight regression 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then
  report pass "regression fixture exits 1"
else
  report fail "regression fixture exits 1" "got rc=$rc"
fi

for broken in magic n8n-mcp crawl4ai; do
  if grep -q "$broken" <<<"$out"; then
    report pass "regression reports $broken"
  else
    report fail "regression reports $broken" "$out"
  fi
done

# "Needs authentication" is UNKNOWN, never FAIL — stripe must not be a failure.
if grep -qE 'stripe.*(unknown|needs authentication)' <<<"$out"; then
  report pass "stripe classified unknown, not fail"
else
  report fail "stripe classified unknown, not fail" "$out"
fi

# --- timeout: every server becomes UNKNOWN, never FAIL ----------------------
out=$(run_preflight timeout 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  report pass "timeout yields no failures"
else
  report fail "timeout yields no failures" "got rc=$rc, output: $out"
fi

if grep -qi 'timed out' <<<"$out"; then
  report pass "timeout is reported to the user"
else
  report fail "timeout is reported to the user" "$out"
fi

# --- ghost: a configured server absent from `claude mcp list` output --------
# ghost-server is configured in claude.json but never appears in mcp-list.txt.
# It must still be reported — as unknown, never silently dropped — and must
# not fail the run (unknown is never a failure).
out=$(run_preflight ghost 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  report pass "ghost fixture exits 0"
else
  report fail "ghost fixture exits 0" "got rc=$rc, output: $out"
fi

if grep -q 'ghost-server' <<<"$out"; then
  report pass "ghost fixture reports ghost-server"
else
  report fail "ghost fixture reports ghost-server" "$out"
fi

if grep -qE 'ghost-server.*\(unknown\)' <<<"$out"; then
  report pass "ghost fixture classifies ghost-server unknown"
else
  report fail "ghost fixture classifies ghost-server unknown" "$out"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
