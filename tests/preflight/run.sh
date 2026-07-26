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
# the weaker check above. render_class collapses passes onto one line under
# the "MCP SERVERS" header, so count words on that line rather than grepping
# one "✔ mcp <name>" line per server.
mcp_pass_line=$(sed -n '/MCP SERVERS/,/^$/p' <<<"$out" | grep '✔')
mcp_pass_count=$(( $(wc -w <<<"$mcp_pass_line") - 1 ))
if [ "$mcp_pass_count" -eq 3 ]; then
  report pass "healthy fixture produces exactly 3 passing MCP findings"
else
  report fail "healthy fixture produces exactly 3 passing MCP findings" "got $mcp_pass_count, output: $out"
fi

for want in context7 github firecrawl-mcp; do
  if grep -qE "✔ .*\b$want\b" <<<"$mcp_pass_line"; then
    report pass "healthy fixture reports $want as a passing MCP finding"
  else
    report fail "healthy fixture reports $want as a passing MCP finding" "$out"
  fi
done

# probe_env must be gated on $CLAUDE_JSON: the healthy fixture's claude.json
# only configures context7/github/firecrawl-mcp, so apify, digitalocean, n8n,
# and crawl4ai — all needs_key=yes but never wired up — must produce no
# finding at all (neither pass nor fail). An unconditional check would flag
# all four as permanent failures regardless of whether they're configured.
for unconfigured in apify digitalocean n8n crawl4ai; do
  if ! grep -q "$unconfigured" <<<"$out"; then
    report pass "healthy fixture emits no finding for unconfigured $unconfigured"
  else
    report fail "healthy fixture emits no finding for unconfigured $unconfigured" "$out"
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

# render_class marks unknown findings with a "!" prefix (never "(unknown)"
# text — that suffix belonged to the old flat per-line report format).
if grep -qE '! *ghost-server' <<<"$out"; then
  report pass "ghost fixture classifies ghost-server unknown"
else
  report fail "ghost fixture classifies ghost-server unknown" "$out"
fi

# --- env-var services -------------------------------------------------------
out=$(run_preflight regression 2>&1)
if grep -q 'CRAWL4AI_URL' <<<"$out"; then
  report pass "reports unset CRAWL4AI_URL"
else
  report fail "reports unset CRAWL4AI_URL" "$out"
fi

# --- repo skills ------------------------------------------------------------
if grep -q 'references/rubric.md' <<<"$out"; then
  report pass "reports skill referencing a missing file"
else
  report fail "reports skill referencing a missing file" "$out"
fi

# --- mandated CLIs: jq is definitely installed, so it must pass --------------
out=$(run_preflight healthy 2>&1)
cli_pass_line=$(sed -n '/MANDATED CLIS/,/^$/p' <<<"$out" | grep '✔')
if grep -qE "✔ .*\bjq\b" <<<"$cli_pass_line"; then
  report pass "reports jq as a passing CLI"
else
  report fail "reports jq as a passing CLI" "$out"
fi

# --- exit 2: the checker itself could not run -------------------------------
# An empty stub dir plus a PATH with no `claude` must report "could not run",
# NOT "everything failed". Distinguishing 2 from 1 is what stops a green cron
# job from hiding a checker that has been crashing for a month.
out=$(PATH="$TESTS_DIR/stubs-noclaude:/usr/bin:/bin" \
      PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/healthy" \
      PREFLIGHT_CLAUDE_JSON="$TESTS_DIR/fixtures/healthy/claude.json" \
      PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/healthy/settings.json" \
      PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/healthy/env" \
      PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/healthy/skills" \
      bash "$REPO_DIR/scripts/preflight.sh" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
  report pass "missing claude yields exit 2, not 1"
else
  report fail "missing claude yields exit 2, not 1" "got rc=$rc: $out"
fi

# --- summary line -----------------------------------------------------------
out=$(run_preflight regression 2>&1)
if grep -qE '[0-9]+ assets · [0-9]+ pass · [0-9]+ fail' <<<"$out"; then
  report pass "prints a summary line"
else
  report fail "prints a summary line" "$out"
fi

if grep -q 'just preflight --quarantine' <<<"$out"; then
  report pass "suggests --quarantine when containable failures exist"
else
  report fail "suggests --quarantine when containable failures exist" "$out"
fi


# --- JSON output ------------------------------------------------------------
out=$(run_preflight regression --json 2>/dev/null)
if jq -e '.schema == 1' <<<"$out" >/dev/null 2>&1; then
  report pass "--json emits schema 1"
else
  report fail "--json emits schema 1" "$out"
fi

if jq -e '[.assets[] | select(.verdict=="fail")] | length >= 3' <<<"$out" >/dev/null 2>&1; then
  report pass "--json lists the failing assets"
else
  report fail "--json lists the failing assets" "$out"
fi

if jq -e '[.assets[] | select(.name=="plugin:stripe:stripe" and .verdict=="unknown")] | length == 1' <<<"$out" >/dev/null 2>&1; then
  report pass "--json marks stripe unknown"
else
  report fail "--json marks stripe unknown" "$out"
fi

# --json must not print the human report alongside the JSON — a caller piping
# stdout into `jq` needs parseable output with nothing else mixed in.
if [ "$(jq -e '.' <<<"$out" >/dev/null 2>&1; echo $?)" -eq 0 ] && ! grep -q '✘\|PREFLIGHT ' <<<"$out"; then
  report pass "--json does not also print the human report"
else
  report fail "--json does not also print the human report" "$out"
fi

# --- exit codes are unchanged by --json --------------------------------------
run_preflight regression --json >/dev/null 2>&1; rc_json=$?
run_preflight regression >/dev/null 2>&1; rc_human=$?
if [ "$rc_json" -eq 1 ] && [ "$rc_json" -eq "$rc_human" ]; then
  report pass "--json exits 1 same as human output"
else
  report fail "--json exits 1 same as human output" "json rc=$rc_json human rc=$rc_human"
fi

# --- unknown option: checker could not run, exit 2, not 1 --------------------
out=$(run_preflight healthy --bogus-flag 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then
  report pass "unknown option yields exit 2, not 1"
else
  report fail "unknown option yields exit 2, not 1" "got rc=$rc: $out"
fi

# --- quarantine -------------------------------------------------------------
# Work on a copy so the fixture stays pristine.
QDIR=$(mktemp -d)
cp "$TESTS_DIR/fixtures/regression/claude.json" "$QDIR/claude.json"

PATH="$TESTS_DIR/stubs:$PATH" \
PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/regression" \
PREFLIGHT_CLAUDE_JSON="$QDIR/claude.json" \
PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/regression/settings.json" \
PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/regression/env" \
PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/regression/skills" \
  bash "$REPO_DIR/scripts/preflight.sh" --quarantine >/dev/null 2>&1

if jq -e '.mcpServers.magic.disabled == true' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine disables a failing server"
else
  report fail "quarantine disables a failing server" "$(cat "$QDIR/claude.json")"
fi

if jq -e '.mcpServers.magic._preflight.reason | length > 0' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine records provenance"
else
  report fail "quarantine records provenance" "$(cat "$QDIR/claude.json")"
fi

# UNKNOWN must never be quarantined — stripe is plugin-supplied and absent from
# claude.json, so assert nothing was invented for it.
if ! jq -e '.mcpServers | has("plugin:stripe:stripe")' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine never touches unknown assets"
else
  report fail "quarantine never touches unknown assets" "$(cat "$QDIR/claude.json")"
fi

# Non-containable failures must be left alone.
if ! jq -e '.mcpServers | has("agent-browser")' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine leaves non-containable failures alone"
else
  report fail "quarantine leaves non-containable failures alone"
fi

# PASSING servers must never be touched. This is the guard the reviewer of
# 4fe3ff4 broke by replacing `[ "$c" = "mcp" ] && [ "$v" = "fail" ] &&
# [ "$cont" = "yes" ] || continue` with bare `[ "$c" = "mcp" ] || continue` —
# the suite still reported 37/0 because the only servers exercised above are
# either fail+containable or entirely absent from mcpServers. context7 and
# github are both PASS and present in the regression fixture's claude.json,
# so they catch exactly this regression.
if jq -e '.mcpServers.context7 | has("disabled") | not' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine leaves a passing server (context7) untouched"
else
  report fail "quarantine leaves a passing server (context7) untouched" "$(cat "$QDIR/claude.json")"
fi

if jq -e '.mcpServers.github | has("disabled") | not' "$QDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine leaves a passing server (github) untouched"
else
  report fail "quarantine leaves a passing server (github) untouched" "$(cat "$QDIR/claude.json")"
fi

# Idempotent re-run: quarantining an already-quarantined server must preserve
# the original quarantinedAt timestamp, not stamp a new one each time.
first_ts=$(jq -r '.mcpServers.magic._preflight.quarantinedAt' "$QDIR/claude.json")
sleep 1
PATH="$TESTS_DIR/stubs:$PATH" \
PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/regression" \
PREFLIGHT_CLAUDE_JSON="$QDIR/claude.json" \
PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/regression/settings.json" \
PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/regression/env" \
PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/regression/skills" \
  bash "$REPO_DIR/scripts/preflight.sh" --quarantine >/dev/null 2>&1
second_ts=$(jq -r '.mcpServers.magic._preflight.quarantinedAt' "$QDIR/claude.json")
if [ "$first_ts" = "$second_ts" ]; then
  report pass "quarantine is idempotent: quarantinedAt unchanged on re-run"
else
  report fail "quarantine is idempotent: quarantinedAt unchanged on re-run" "first=$first_ts second=$second_ts"
fi

rm -rf "$QDIR"

# --- quarantine: unknown-verdict server present in mcpServers must survive --
# ghost-server is configured (present in mcpServers) but classified `unknown`
# (absent from `claude mcp list` output). Unlike agent-browser/stripe above,
# this checks a server that IS in mcpServers with verdict=unknown, so a guard
# regression that drops the `[ "$v" = "fail" ]` clause would catch it too.
GDIR=$(mktemp -d)
cp "$TESTS_DIR/fixtures/ghost/claude.json" "$GDIR/claude.json"

PATH="$TESTS_DIR/stubs:$PATH" \
PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/ghost" \
PREFLIGHT_CLAUDE_JSON="$GDIR/claude.json" \
PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/ghost/settings.json" \
PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/ghost/env" \
PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/ghost/skills" \
  bash "$REPO_DIR/scripts/preflight.sh" --quarantine >/dev/null 2>&1

if jq -e '.mcpServers["ghost-server"] | has("disabled") | not' "$GDIR/claude.json" >/dev/null 2>&1; then
  report pass "quarantine leaves an unknown-verdict server (ghost-server) untouched"
else
  report fail "quarantine leaves an unknown-verdict server (ghost-server) untouched" "$(cat "$GDIR/claude.json")"
fi

rm -rf "$GDIR"

# --- tier 3 smoke -----------------------------------------------------------
out=$(run_preflight regression --smoke 2>&1)
if grep -q 'mcp-github' <<<"$out"; then
  report pass "smoke reports the failing test"
else
  report fail "smoke reports the failing test" "$out"
fi

if grep -qi 'untested' <<<"$out"; then
  report pass "smoke reports untested assets by name"
else
  report fail "smoke reports untested assets by name" "$out"
fi

# A smoke failure is a fail like any other — it must flip the run's exit code
# to 1. Requirement 5 (run_smoke must append its findings BEFORE the final
# `count_verdict fail` in main()) is easy to break by reordering main(), and
# the regression-fixture assertions above can't catch that: regression
# already exits 1 on its own (magic/n8n-mcp/crawl4ai), with or without smoke.
# The healthy fixture exits 0 with no smoke tests involved, so wiring a
# failing smoke script (fixtures/healthy/smoke/mcp-context7.sh) onto it
# isolates the ordering bug — this only passes if run_smoke's fail finding
# is counted before main() computes the exit code.
run_preflight healthy >/dev/null 2>&1; rc_no_smoke=$?
run_preflight healthy --smoke >/dev/null 2>&1; rc_smoke=$?
if [ "$rc_no_smoke" -eq 0 ] && [ "$rc_smoke" -eq 1 ]; then
  report pass "a smoke failure causes exit 1"
else
  report fail "a smoke failure causes exit 1" "no-smoke rc=$rc_no_smoke smoke rc=$rc_smoke"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
