#!/bin/bash
# Pre-flight checker test harness. Runs offline: `claude` is stubbed on PATH
# and every filesystem path the checker reads is redirected at a fixture.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/../.." && pwd)"
PASS=0
FAIL=0

# Every test-owned mktemp -d below is registered here instead of trailing a
# competing `trap ... EXIT` of its own (a second bare `trap ... EXIT` would
# just replace the first, silently un-registering earlier cleanups). One
# list, one trap, removed on normal exit AND on interrupt so a Ctrl-C mid-run
# can't leak a temp dir.
CLEANUP_DIRS=()
add_cleanup_dir() { CLEANUP_DIRS+=("$1"); }
cleanup_dirs() {
  local d
  for d in ${CLEANUP_DIRS+"${CLEANUP_DIRS[@]}"}; do
    rm -rf "$d"
  done
}
trap cleanup_dirs EXIT INT

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
  PREFLIGHT_LINK_DIRS="" \
  PREFLIGHT_LINK_FILES="" \
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

# --- probe_hooks: real coverage of an existing-and-executable hook vs a -----
# --- missing one -------------------------------------------------------------
# Every other fixture's settings.json is `{"hooks":{}}`, so a regression that
# emptied probe_hooks entirely would still pass every other check in this
# suite. This fixture wires one real, executing hook (hooks/exists.sh,
# reachable via a literal "$HOME/hooks/exists.sh" command string that
# probe_hooks expands using the *running* $HOME) and one hook pointing at a
# path that's never created. $HOME is overridden only for this one
# invocation, to the fixture directory itself — it never touches the real
# $HOME, and no other PREFLIGHT_* default depends on it since all of them are
# already set explicitly below.
HOOKS_DIR="$TESTS_DIR/fixtures/hooks"
out=$(HOME="$HOOKS_DIR" \
      PATH="$TESTS_DIR/stubs:$PATH" \
      PREFLIGHT_FIXTURE="$HOOKS_DIR" \
      PREFLIGHT_CLAUDE_JSON="$HOOKS_DIR/claude.json" \
      PREFLIGHT_SETTINGS_JSON="$HOOKS_DIR/settings.json" \
      PREFLIGHT_ENV_FILE="$HOOKS_DIR/env" \
      PREFLIGHT_SKILLS_DIR="$HOOKS_DIR/skills" \
      bash "$REPO_DIR/scripts/preflight.sh" 2>&1); rc=$?
hooks_section=$(sed -n '/HOOKS & SCRIPTS/,/^$/p' <<<"$out")

if grep '✔' <<<"$hooks_section" | grep -q 'exists.sh'; then
  report pass "probe_hooks reports an existing, executable hook as pass"
else
  report fail "probe_hooks reports an existing, executable hook as pass" "$out"
fi

if grep -qE '✘.*missing\.sh.*does not exist' <<<"$hooks_section"; then
  report pass "probe_hooks reports a missing hook path as fail"
else
  report fail "probe_hooks reports a missing hook path as fail" "$out"
fi

if [ "$rc" -eq 1 ]; then
  report pass "a missing hook path flips the run's exit code to 1"
else
  report fail "a missing hook path flips the run's exit code to 1" "got rc=$rc: $out"
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

# --- malformed config: a corrupt claude.json/settings.json must NOT report --
# --- green -------------------------------------------------------------------
# Before the fix, every jq call against these files was `2>/dev/null`, so a
# file that exists but fails to parse was swallowed exactly like a missing
# one: the mcp cross-reference and probe_env silently produced nothing and
# probe_hooks's class vanished, all while the run still exited 0. This is
# a checker-*ran* problem (exit 1), not a checker-*broken* problem (exit 2):
# `claude mcp list` itself still worked fine (context7 still connects below),
# only the config-derived probes were blind.
# Assert exit 1 exactly, not merely non-zero: `-ne 0` would also accept exit 2,
# which is the very distinction this block's comment claims to be testing.
out=$(run_preflight malformed 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then
  report pass "malformed claude.json exits 1 (ran, found a fault), not 2 (broken)"
else
  report fail "malformed claude.json exits 1 (ran, found a fault), not 2 (broken)" "got rc=$rc: $out"
fi

if grep -q 'claude.json' <<<"$out" && grep -qi 'malformed' <<<"$out"; then
  report pass "malformed claude.json is named explicitly in the report"
else
  report fail "malformed claude.json is named explicitly in the report" "$out"
fi

if grep -q 'settings.json' <<<"$out" && grep -qi 'malformed' <<<"$out"; then
  report pass "malformed settings.json is named explicitly in the report"
else
  report fail "malformed settings.json is named explicitly in the report" "$out"
fi

# The live `claude mcp list` output is independent of claude.json's own
# validity — context7 must still show up as a pass, proving this isn't a
# checker-broken (exit 2) situation, just a blind spot the fix now reports.
if grep -qE '✔.*\bcontext7\b' <<<"$out"; then
  report pass "malformed config still reports the live mcp probe (context7 pass)"
else
  report fail "malformed config still reports the live mcp probe (context7 pass)" "$out"
fi

out_json=$(run_preflight malformed --json 2>/dev/null)
if jq -e '[.assets[] | select(.class=="config" and .verdict=="fail")] | length == 2' <<<"$out_json" >/dev/null 2>&1; then
  report pass "--json reports both malformed config files as class=config fail"
else
  report fail "--json reports both malformed config files as class=config fail" "$out_json"
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
add_cleanup_dir "$QDIR"
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

# --- quarantine: unknown-verdict server present in mcpServers must survive --
# ghost-server is configured (present in mcpServers) but classified `unknown`
# (absent from `claude mcp list` output). Unlike agent-browser/stripe above,
# this checks a server that IS in mcpServers with verdict=unknown, so a guard
# regression that drops the `[ "$v" = "fail" ]` clause would catch it too.
GDIR=$(mktemp -d)
add_cleanup_dir "$GDIR"
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

# --- cross-reference recognizes preflight's own quarantine marker -----------
# Before the fix, the cross-reference branch had no way to tell "I disabled
# this on purpose" from "this vanished for some other reason" — a server
# quarantined last run came back next run reporting the same generic
# "configured but absent" line the marker exists to prevent. fixtures/
# quarantined/claude.json has magic pre-quarantined (disabled, with a stored
# _preflight.quarantinedAt/reason) and absent from mcp-list.txt, simulating a
# real `claude mcp list` that doesn't list a disabled server.
out=$(run_preflight quarantined 2>&1); rc=$?

if grep -q 'quarantined by preflight' <<<"$out"; then
  report pass "cross-reference recognizes preflight's own quarantine marker"
else
  report fail "cross-reference recognizes preflight's own quarantine marker" "$out"
fi

if grep -q '2026-07-20T10:00:00Z' <<<"$out"; then
  report pass "quarantine marker reports the stored quarantinedAt date"
else
  report fail "quarantine marker reports the stored quarantinedAt date" "$out"
fi

if grep -q 'Not authenticated' <<<"$out"; then
  report pass "quarantine marker reports the stored reason"
else
  report fail "quarantine marker reports the stored reason" "$out"
fi

if ! grep -q 'configured but absent' <<<"$out"; then
  report pass "quarantine marker replaces the generic 'configured but absent' line"
else
  report fail "quarantine marker replaces the generic 'configured but absent' line" "$out"
fi

if [ "$rc" -eq 0 ]; then
  report pass "a preflight-quarantined server does not fail the run"
else
  report fail "a preflight-quarantined server does not fail the run" "got rc=$rc: $out"
fi

out_json=$(run_preflight quarantined --json 2>/dev/null)
if jq -e '[.assets[] | select(.name=="magic" and .verdict=="unknown" and .containable==false)] | length == 1' <<<"$out_json" >/dev/null 2>&1; then
  report pass "quarantine marker keeps verdict unknown and non-containable"
else
  report fail "quarantine marker keeps verdict unknown and non-containable" "$out_json"
fi

# --- quarantine: a failing mv must not be reported as a success (item 1) ----
# Reproduced live: with mv failing, preflight printed false "disabled: true"
# success lines and a false "N contained" count, while claude.json stayed
# unmodified and temp files were left beside it. Shadow only `mv` with a stub
# that always fails; jq/cp/claude are untouched so the rest of quarantine
# still runs normally up to the final rename.
MVDIR=$(mktemp -d)
add_cleanup_dir "$MVDIR"
cp "$TESTS_DIR/fixtures/regression/claude.json" "$MVDIR/claude.json"
before_hash=$(shasum "$MVDIR/claude.json" | awk '{print $1}')

out=$(PATH="$TESTS_DIR/stubs-failmv:$TESTS_DIR/stubs:$PATH" \
PREFLIGHT_FIXTURE="$TESTS_DIR/fixtures/regression" \
PREFLIGHT_CLAUDE_JSON="$MVDIR/claude.json" \
PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/regression/settings.json" \
PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/regression/env" \
PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/regression/skills" \
  bash "$REPO_DIR/scripts/preflight.sh" --quarantine 2>&1)

after_hash=$(shasum "$MVDIR/claude.json" | awk '{print $1}')
if [ "$before_hash" = "$after_hash" ]; then
  report pass "a failing mv leaves claude.json byte-for-byte unmodified"
else
  report fail "a failing mv leaves claude.json byte-for-byte unmodified" "$out"
fi

if ! grep -q 'disabled: true' <<<"$out"; then
  report pass "a failing mv prints no false 'disabled: true' success line"
else
  report fail "a failing mv prints no false 'disabled: true' success line" "$out"
fi

mv_fail_count=$(grep -c 'mv failed while quarantining' <<<"$out")
if [ "$mv_fail_count" -eq 3 ]; then
  report pass "a failing mv is reported once per containable server (3)"
else
  report fail "a failing mv is reported once per containable server (3)" "count=$mv_fail_count; $out"
fi

if ! grep -q 'nothing containable' <<<"$out"; then
  report pass "a failing mv does not falsely report 'nothing containable'"
else
  report fail "a failing mv does not falsely report 'nothing containable'" "$out"
fi

if grep -qi 'write(s) failed' <<<"$out"; then
  report pass "closing summary reflects the write failures instead of lying"
else
  report fail "closing summary reflects the write failures instead of lying" "$out"
fi

banner_count=$(grep -c 'backed up' <<<"$out")
if [ "$banner_count" -eq 1 ]; then
  report pass "backup banner prints exactly once despite 3 failing writes"
else
  report fail "backup banner prints exactly once despite 3 failing writes" "count=$banner_count; $out"
fi

leftover=$(find "$MVDIR" -maxdepth 1 -name 'claude.json.??????' 2>/dev/null | wc -l | tr -d ' ')
if [ "$leftover" -eq 0 ]; then
  report pass "a failing mv does not leave temp files behind"
else
  report fail "a failing mv does not leave temp files behind" "leftover=$leftover in $MVDIR"
fi

# --- M4: apply_quarantine's containable guard is real, not decorative ------
# A reviewer showed that deleting *just* `[ "$cont" = "yes" ]` from the guard
# still leaves the suite green, because no fixture emits an mcp/fail finding
# with containable=no — the only emitter (probe_mcp's "Failed to connect"
# branch) always passes yes. Prove the guard by constructing that finding
# directly: source preflight.sh (never executed — the BASH_SOURCE guard added
# for this fix keeps `main` from running) and inject it into FINDINGS by
# hand, naming a server that DOES exist in a temp copy of a real claude.json.
#
# Sourced inside a `bash -c` subshell, not this script's own shell: sourcing
# preflight.sh pulls its globals (CLAUDE_JSON, FINDINGS, every function) into
# whatever shell runs `source`, and none of that belongs leaking into this
# test runner's own namespace.
#
# $0 is deliberately set to a value distinct from the real script path: the
# guard compares `${BASH_SOURCE[0]}` (always the sourced file's real path)
# against `$0` (unchanged by `source`) to tell "executed directly" from
# "pulled in by something else".
M4DIR=$(mktemp -d)
add_cleanup_dir "$M4DIR"
cp "$TESTS_DIR/fixtures/regression/claude.json" "$M4DIR/claude.json"

PREFLIGHT_CLAUDE_JSON="$M4DIR/claude.json" \
PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/regression/settings.json" \
PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/regression/env" \
PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/regression/skills" \
  bash -c '
    source "$1"
    FINDINGS+=("mcp|magic|fail|synthetic non-containable finding|no")
    apply_quarantine
  ' preflight-sourced-not-executed "$REPO_DIR/scripts/preflight.sh" >/dev/null 2>&1

if jq -e '.mcpServers.magic | has("disabled") | not' "$M4DIR/claude.json" >/dev/null 2>&1; then
  report pass "M4: containable=no guard leaves an mcp/fail finding untouched"
else
  report fail "M4: containable=no guard leaves an mcp/fail finding untouched" "$(cat "$M4DIR/claude.json")"
fi

# --- M7: a detail containing a literal '|' round-trips intact ---------------
# add_finding stores detail LAST (class|name|verdict|containable|detail) so a
# pipe embedded in a real failure detail can't shift containable out of
# position. fixtures/pipe-detail's mcp-list.txt gives `widget` a "Failed to
# connect" detail that itself contains " | " partway through.
out_json=$(run_preflight pipe-detail --json 2>/dev/null)

expected_detail='Failed to connect — token invalid | contact admin for reset — code 42'
if [ "$(jq -r '.assets[] | select(.name=="widget") | .detail' <<<"$out_json")" = "$expected_detail" ]; then
  report pass "a detail containing '|' survives intact in --json"
else
  report fail "a detail containing '|' survives intact in --json" "$out_json"
fi

if jq -e '[.assets[] | select(.name=="widget" and .verdict=="fail" and .containable==true)] | length == 1' <<<"$out_json" >/dev/null 2>&1; then
  report pass "a detail containing '|' does not corrupt containable"
else
  report fail "a detail containing '|' does not corrupt containable" "$out_json"
fi

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

# --- --json --smoke: the JSON-only-on-stdout contract under tier 3 ----------
# regression's smoke dir covers only its two tier-2 passes (context7,
# github); every other passing tier-1/2 asset (mandated CLIs, env services,
# hooks, skills) has no matching smoke script and becomes `untested`. This is
# the exact combination the c5048f5 review flagged: render_json ran before
# run_smoke, so the document claimed "tier":3 while carrying zero tier-3
# findings. stdout must still be exactly one JSON document, and that document
# must actually carry the smoke results.
out=$(run_preflight regression --json --smoke 2>/dev/null)
if jq -e . <<<"$out" >/dev/null 2>&1; then
  report pass "--json --smoke emits a single parseable JSON document"
else
  report fail "--json --smoke emits a single parseable JSON document" "$out"
fi

if jq -e '.summary.untested > 0' <<<"$out" >/dev/null 2>&1; then
  report pass "--json --smoke summary reports untested > 0"
else
  report fail "--json --smoke summary reports untested > 0" "$out"
fi

if jq -e '[.assets[] | select(.class=="smoke")] | length > 0' <<<"$out" >/dev/null 2>&1; then
  report pass "--json --smoke assets include smoke-class findings"
else
  report fail "--json --smoke assets include smoke-class findings" "$out"
fi

# --- --json --smoke: a failing smoke test still exits 1 with clean JSON ----
# healthy's mcp-context7.sh smoke script deliberately fails, isolating the
# ordering bug the same way the human-mode "a smoke failure causes exit 1"
# check above does. The old code also printed human SMOKE/UNTESTED text
# after the JSON document on the same stdout — assert that's gone too.
out=$(run_preflight healthy --json --smoke 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ]; then
  report pass "--json --smoke exits 1 on a failing smoke test"
else
  report fail "--json --smoke exits 1 on a failing smoke test" "got rc=$rc: $out"
fi

if jq -e . <<<"$out" >/dev/null 2>&1; then
  report pass "--json --smoke stdout still parses as JSON when a smoke test fails"
else
  report fail "--json --smoke stdout still parses as JSON when a smoke test fails" "$out"
fi

# --- links probe -----------------------------------------------------------
# A dangling link is the incident condition. A stale-but-resolving link is the
# condition that would have made the incident INVISIBLE had the old checkout
# survived the move — a dangling-only check reports nothing for it. A
# lookalike directory name must NOT be treated as ours — the case pattern in
# _probe_one_link must stay an anchored path-component match
# (*/ai-dotfiles/*), never a bare substring, since a later phase uses this
# same predicate to decide what to delete.
links_fixture="$TESTS_DIR/fixtures/links"

# The "not repo-owned" case can't be a fixture committed inside this repo:
# this checkout's own directory is literally named ai-dotfiles, so any
# resolved absolute path under tests/preflight/fixtures/ contains a real
# "/ai-dotfiles/" path component no matter what a fixture subdirectory is
# named. Build the lookalike (decoy) target outside the repo tree instead,
# and wire the fixture's decoy.sh symlink to it only for this test.
DECOY_DIR=$(mktemp -d)
add_cleanup_dir "$DECOY_DIR"
mkdir -p "$DECOY_DIR/ai-dotfiles-backup/scripts"
echo '#!/bin/bash' > "$DECOY_DIR/ai-dotfiles-backup/scripts/decoy.sh"
chmod +x "$DECOY_DIR/ai-dotfiles-backup/scripts/decoy.sh"
ln -sfn "$DECOY_DIR/ai-dotfiles-backup/scripts/decoy.sh" "$links_fixture/home/.claude/scripts/decoy.sh"

out=$(PATH="$TESTS_DIR/stubs:$PATH" \
  PREFLIGHT_CLAUDE_JSON="$TESTS_DIR/fixtures/healthy/claude.json" \
  PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/healthy/settings.json" \
  PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/healthy/env" \
  PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/healthy/skills" \
  PREFLIGHT_LINK_DIRS="$links_fixture/home/.claude/scripts" \
  PREFLIGHT_LINK_FILES="" \
  PREFLIGHT_DOTFILES_DIR="$links_fixture/checkout" \
  bash "$REPO_DIR/scripts/preflight.sh" --json 2>/dev/null); rc=$?

# Assert on verdict AND detail string, not just the name being present.
# render_class collapses every pass onto one bare-name line in human mode,
# so a name-only assertion can't tell "current checkout" apart from
# "not repo-owned" — both are pass. --json exposes the detail field.
link_detail() {
  jq -r --arg n "$1" '.assets[] | select(.class=="link" and .name==$n) | "\(.verdict) \(.detail)"' <<<"$out"
}

if grep -q "^pass current checkout$" <<<"$(link_detail healthy.sh)"; then
  report pass "links probe passes a correct link as 'current checkout'"
else
  report fail "links probe passes a correct link as 'current checkout'" "$(link_detail healthy.sh)"
fi

if grep -q "^fail dangling -> " <<<"$(link_detail dangling.sh)"; then
  report pass "links probe reports a dangling link as 'dangling'"
else
  report fail "links probe reports a dangling link as 'dangling'" "$(link_detail dangling.sh)"
fi

if grep -q "^fail stale but resolving -> " <<<"$(link_detail stale.sh)"; then
  report pass "links probe reports a stale-but-resolving link as 'stale but resolving'"
else
  report fail "links probe reports a stale-but-resolving link as 'stale but resolving'" "$(link_detail stale.sh)"
fi

if grep -q "^pass not repo-owned$" <<<"$(link_detail decoy.sh)"; then
  report pass "links probe passes a lookalike directory name as 'not repo-owned'"
else
  report fail "links probe passes a lookalike directory name as 'not repo-owned'" "$(link_detail decoy.sh)"
fi

if [ "$rc" -eq 1 ]; then
  report pass "links probe fails the run when drift is present"
else
  report fail "links probe fails the run when drift is present" "got rc=$rc"
fi

# The probe is read-only. Any write to the fixture is a defect.
links_tree_hash() {
  # names + link targets + sizes: catches a created, deleted, retargeted, or
  # rewritten file. `md5sum` on Linux, `md5` on macOS.
  # A dangling link has no size to read — `wc -c <"$p"` opens the redirect
  # before its own `2>/dev/null` takes effect, so the shell's "No such file
  # or directory" bypasses that redirect and lands on the suite's stderr.
  # Guard the read instead of relying on the command's own redirect.
  find "$links_fixture" | sort | while IFS= read -r p; do
    if [ -e "$p" ]; then
      printf '%s|%s|%s\n' "$p" "$(readlink "$p" 2>/dev/null)" "$(wc -c <"$p" 2>/dev/null)"
    else
      printf '%s|%s|%s\n' "$p" "$(readlink "$p" 2>/dev/null)" "-"
    fi
  done | { md5sum 2>/dev/null || md5; }
}
before=$(links_tree_hash)
# Same overrides as the JSON-assertion invocation above — omitting them
# (as the original brief's example did) let this probe the developer's
# real ~/.claude.json, real MCP servers, and real ~/.claude/statusline.sh,
# and on a machine without `claude`/`jq` on the real PATH, check_preconditions
# fails and main exits 2 before probe_links ever runs — the before/after
# hashes would then match trivially and this assertion would pass having
# proven nothing. Capture the output too, so that silent-exit-2 case fails
# the "did it actually run" check below instead of going unnoticed.
write_check_out=$(PATH="$TESTS_DIR/stubs:$PATH" \
  PREFLIGHT_CLAUDE_JSON="$TESTS_DIR/fixtures/healthy/claude.json" \
  PREFLIGHT_SETTINGS_JSON="$TESTS_DIR/fixtures/healthy/settings.json" \
  PREFLIGHT_ENV_FILE="$TESTS_DIR/fixtures/healthy/env" \
  PREFLIGHT_SKILLS_DIR="$TESTS_DIR/fixtures/healthy/skills" \
  PREFLIGHT_LINK_DIRS="$links_fixture/home/.claude/scripts" \
  PREFLIGHT_LINK_FILES="" \
  PREFLIGHT_DOTFILES_DIR="$links_fixture/checkout" \
  bash "$REPO_DIR/scripts/preflight.sh" --json 2>/dev/null)
after=$(links_tree_hash)
if [ "$before" = "$after" ]; then
  report pass "links probe writes nothing"
else
  report fail "links probe writes nothing" "fixture tree changed"
fi

if jq -e '[.assets[] | select(.class=="link")] | length >= 4' <<<"$write_check_out" >/dev/null 2>&1; then
  report pass "links probe writes-nothing check actually ran probe_links"
else
  report fail "links probe writes-nothing check actually ran probe_links" "$write_check_out"
fi

# decoy.sh is wired up dynamically for this test only — it targets a mktemp
# dir that add_cleanup_dir will remove, and isn't part of the committed
# fixture tree, so it must not linger as an untracked file afterward.
rm -f "$links_fixture/home/.claude/scripts/decoy.sh"

# --- lib/links.sh ----------------------------------------------------------
source "$REPO_DIR/tests/preflight/links_fixture.sh"

links_case() {  # links_case <name> <body-fn>
  local name="$1" body="$2"
  # Called directly, not `tmp=$(links_fixture_setup)`: the latter forks a
  # subshell, so DOTFILES_DIR/CLAUDE_DIR/HOME set inside the function would
  # vanish the instant the substitution closes, leaving them unbound here.
  links_fixture_setup >/dev/null
  add_cleanup_dir "$LINKS_TMP"
  source "$REPO_DIR/lib/links.sh"
  LINK_CHANGED=0; LINK_OK=0; LINK_SKIPPED=0; LINK_FAILED=0
  "$body"
}

# 1. a dangling link is repointed at the current checkout
_t_repoint() {
  echo 'x' > "$DOTFILES_DIR/scripts/a.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  ln -sfn "/nonexistent/a.sh" "$CLAUDE_DIR/scripts/a.sh"
  link_file "$DOTFILES_DIR/scripts/a.sh" "$CLAUDE_DIR/scripts/a.sh"
  if [ "$(readlink "$CLAUDE_DIR/scripts/a.sh")" = "$DOTFILES_DIR/scripts/a.sh" ] \
     && [ "$LINK_CHANGED" -eq 1 ]; then
    report pass "link_file repoints a dangling link"
  else
    report fail "link_file repoints a dangling link" "changed=$LINK_CHANGED"
  fi
}
links_case repoint _t_repoint

# 2. a correct link is untouched and silent
_t_verified() {
  echo 'x' > "$DOTFILES_DIR/scripts/b.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  ln -sfn "$DOTFILES_DIR/scripts/b.sh" "$CLAUDE_DIR/scripts/b.sh"
  LINKS_OUT=""
  link_file "$DOTFILES_DIR/scripts/b.sh" "$CLAUDE_DIR/scripts/b.sh"
  if [ "$LINK_OK" -eq 1 ] && [ -z "$LINKS_OUT" ]; then
    report pass "link_file leaves a correct link untouched and silent"
  else
    report fail "link_file leaves a correct link untouched and silent" "ok=$LINK_OK out=$LINKS_OUT"
  fi
}
links_case verified _t_verified

# 3. dst is a directory -> refused, directory survives
_t_dstdir() {
  echo 'x' > "$DOTFILES_DIR/scripts/c.sh"
  mkdir -p "$CLAUDE_DIR/scripts/c.sh"
  link_file "$DOTFILES_DIR/scripts/c.sh" "$CLAUDE_DIR/scripts/c.sh"
  if [ -d "$CLAUDE_DIR/scripts/c.sh" ] && [ "$LINK_FAILED" -eq 1 ]; then
    report pass "link_file refuses a directory destination"
  else
    report fail "link_file refuses a directory destination" "failed=$LINK_FAILED"
  fi
}
links_case dstdir _t_dstdir

# 4. dst is a regular file -> backed up, then replaced
_t_dstfile() {
  echo 'new' > "$DOTFILES_DIR/scripts/d.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  echo 'original' > "$CLAUDE_DIR/scripts/d.sh"
  link_file "$DOTFILES_DIR/scripts/d.sh" "$CLAUDE_DIR/scripts/d.sh"
  if [ -L "$CLAUDE_DIR/scripts/d.sh" ] \
     && grep -rq original "$CLAUDE_DIR/.backups" 2>/dev/null; then
    report pass "link_file backs up a regular file before replacing it"
  else
    report fail "link_file backs up a regular file before replacing it" "$(ls -R "$CLAUDE_DIR" 2>&1)"
  fi
}
links_case dstfile _t_dstfile

# 5. src missing -> skip, no link created
_t_srcmissing() {
  mkdir -p "$CLAUDE_DIR/scripts"
  link_file "$DOTFILES_DIR/scripts/nope.sh" "$CLAUDE_DIR/scripts/nope.sh"
  if [ ! -e "$CLAUDE_DIR/scripts/nope.sh" ] && [ ! -L "$CLAUDE_DIR/scripts/nope.sh" ] \
     && [ "$LINK_SKIPPED" -eq 1 ]; then
    report pass "link_file skips a missing source"
  else
    report fail "link_file skips a missing source" "skipped=$LINK_SKIPPED"
  fi
}
links_case srcmissing _t_srcmissing

# 6. an exported counter does not leak into the run
_t_exported() {
  echo 'x' > "$DOTFILES_DIR/scripts/e.sh"
  export LINK_CHANGED=7
  LINK_CHANGED=0; LINK_OK=0; LINK_SKIPPED=0; LINK_FAILED=0
  link_file "$DOTFILES_DIR/scripts/e.sh" "$CLAUDE_DIR/scripts/e.sh"
  local got="$LINK_CHANGED"
  unset LINK_CHANGED
  if [ "$got" -eq 1 ]; then
    report pass "an exported counter does not survive explicit assignment"
  else
    report fail "an exported counter does not survive explicit assignment" "got $got, want 1"
  fi
}
links_case exported _t_exported

# 7. link_statusline does not chmod through a link it did not create, and its
# dry-run report matches link_file's dry-run contract: counted, marked
# "(dry run)", and the fixture tree left byte-for-byte untouched.
#
# A destination that is absent under dry run proves nothing: link_file never
# touches an absent destination anyway, dry run or not, so `[ ! -e dst ]`
# alone would pass even with the dry-run clause deleted entirely. The guard
# needs a link that already exists and is WRONG — pointing somewhere other
# than our statusline.sh — so a leaked chmod has a real, checkable victim:
# the wrong target's own mode bit.
_t_statusline_dryrun() {
  local before after wrong_target
  wrong_target="$DOTFILES_DIR/not-the-statusline.sh"
  echo 'not it' > "$wrong_target"
  chmod 644 "$wrong_target"
  ln -sfn "$wrong_target" "$CLAUDE_DIR/statusline.sh"
  before=$(find "$LINKS_TMP" | sort)
  LINKS_DRY_RUN=1
  LINKS_OUT=""
  link_statusline
  unset LINKS_DRY_RUN
  after=$(find "$LINKS_TMP" | sort)
  if [ "$(readlink "$CLAUDE_DIR/statusline.sh")" = "$wrong_target" ] \
     && [ ! -x "$wrong_target" ] \
     && [ "$LINK_CHANGED" -eq 1 ] \
     && printf '%s' "$LINKS_OUT" | grep -q '(dry run)' \
     && [ "$before" = "$after" ]; then
    report pass "link_statusline leaves a foreign link and its target's mode alone under dry run"
  else
    report fail "link_statusline leaves a foreign link and its target's mode alone under dry run" \
      "dst=$(readlink "$CLAUDE_DIR/statusline.sh" 2>&1) wrong_target_exec=$([ -x "$wrong_target" ] && echo yes || echo no) changed=$LINK_CHANGED out=$LINKS_OUT tree_changed=$([ "$before" = "$after" ] && echo no || echo yes)"
  fi
}
links_case statusline_dryrun _t_statusline_dryrun

# 7b. the readlink-mismatch half of the guard blocks the chmod even when a
# link already exists at dst — but does NOT prove the dry-run half does
# anything, since a pre-existing CORRECT link satisfies the readlink
# comparison regardless of LINKS_DRY_RUN. That is the one arrangement a
# readlink-only guard would get wrong: source seeded non-executable, dst
# already a correct link, called under dry run — the source's mode must be
# untouched.
_t_statusline_dryrun_correct() {
  chmod 644 "$DOTFILES_DIR/statusline.sh"
  ln -sfn "$DOTFILES_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  LINKS_DRY_RUN=1
  link_statusline
  unset LINKS_DRY_RUN
  if [ ! -x "$DOTFILES_DIR/statusline.sh" ]; then
    report pass "link_statusline does not chmod the source through an already-correct link under dry run"
  else
    report fail "link_statusline does not chmod the source through an already-correct link under dry run" \
      "source_exec=$([ -x "$DOTFILES_DIR/statusline.sh" ] && echo yes || echo no)"
  fi
}
links_case statusline_dryrun_correct _t_statusline_dryrun_correct

# 7c. link_repo_scripts carries the identical guard as link_statusline (a
# stale/foreign symlink at dst must not get chmod'd, dry run or not) — cover
# it the same way: a wrong pre-existing link, called under dry run.
_t_reposcripts_dryrun_foreign() {
  local wrong_target
  echo 'x' > "$DOTFILES_DIR/scripts/foo.sh"
  wrong_target="$DOTFILES_DIR/not-foo.sh"
  echo 'not it' > "$wrong_target"
  chmod 644 "$wrong_target"
  mkdir -p "$CLAUDE_DIR/scripts"
  ln -sfn "$wrong_target" "$CLAUDE_DIR/scripts/foo.sh"
  LINKS_DRY_RUN=1
  link_repo_scripts
  unset LINKS_DRY_RUN
  if [ "$(readlink "$CLAUDE_DIR/scripts/foo.sh")" = "$wrong_target" ] \
     && [ ! -x "$wrong_target" ]; then
    report pass "link_repo_scripts leaves a foreign link and its target's mode alone under dry run"
  else
    report fail "link_repo_scripts leaves a foreign link and its target's mode alone under dry run" \
      "dst=$(readlink "$CLAUDE_DIR/scripts/foo.sh" 2>&1) wrong_target_exec=$([ -x "$wrong_target" ] && echo yes || echo no)"
  fi
}
links_case reposcripts_dryrun_foreign _t_reposcripts_dryrun_foreign

# 8. a missing source directory is skipped, not failed
_t_nobindir() {
  rmdir "$DOTFILES_DIR/bin"
  link_bin_tools
  if [ "$LINK_FAILED" -eq 0 ]; then
    report pass "link_bin_tools skips a missing bin/ without failing"
  else
    report fail "link_bin_tools skips a missing bin/ without failing" "failed=$LINK_FAILED"
  fi
}
links_case nobindir _t_nobindir

# 9. hooks with a dotted stem are repo-side helpers, never linked as hooks
_t_dottedhook() {
  echo 'x' > "$DOTFILES_DIR/hooks/real.sh"
  echo 'x' > "$DOTFILES_DIR/hooks/helper.test.sh"
  link_claude_hooks
  if [ -L "$CLAUDE_DIR/hooks/real.sh" ] && [ ! -e "$CLAUDE_DIR/hooks/helper.test.sh" ]; then
    report pass "link_claude_hooks skips dotted-stem helpers"
  else
    report fail "link_claude_hooks skips dotted-stem helpers" "$(ls "$CLAUDE_DIR/hooks" 2>&1)"
  fi
}
links_case dottedhook _t_dottedhook

# 10. relink_all zeroes counters on entry — an exported value must not leak
_t_relink_reset() {
  export LINK_CHANGED=99
  echo 'x' > "$DOTFILES_DIR/scripts/f.sh"
  LINKS_OUT=""
  relink_all
  local got="$LINK_CHANGED"
  unset LINK_CHANGED
  # Assert the actual count, not the absence of the string "99": a broken
  # reset that accumulated onto the exported value would report 100, which
  # does not contain "99" and would pass a substring check. Require also
  # that a summary was printed, so a relink_all that emitted nothing at all
  # cannot satisfy this by silence.
  if [ "$got" -ge 1 ] && [ "$got" -lt 99 ] \
     && printf '%s' "$LINKS_OUT" | grep -q 'verified'; then
    report pass "relink_all zeroes counters, ignoring an exported value"
  else
    report fail "relink_all zeroes counters, ignoring an exported value" \
      "changed=$got out=$LINKS_OUT"
  fi
}
links_case relink_reset _t_relink_reset

# 11. AGENTS.md failures are counted, not erased by the reset. This was the
# review's broadest finding: called BEFORE relink_all, they printed under
# "0 failed".
_t_agents_counted() {
  echo 'x' > "$CLAUDE_DIR/CLAUDE.md"
  relink_all
  if [ -L "$HOME/AGENTS.md" ]; then
    report pass "relink_all links AGENTS.md and counts it"
  else
    report fail "relink_all links AGENTS.md and counts it" "$LINKS_OUT"
  fi
}
links_case agents_counted _t_agents_counted

# 12. the four counters account for every link attempted
_t_counter_sum() {
  echo 'x' > "$DOTFILES_DIR/scripts/g.sh"
  echo 'x' > "$DOTFILES_DIR/hooks/h.sh"
  relink_all
  total=$(( LINK_CHANGED + LINK_OK + LINK_SKIPPED + LINK_FAILED ))
  if [ "$total" -gt 0 ]; then
    report pass "relink_all counters sum to the links attempted"
  else
    report fail "relink_all counters sum to the links attempted" "total=$total"
  fi
}
links_case counter_sum _t_counter_sum

# 13. a repair is a warn, not an ok — 24 silent repairs under a checkmark
# would hide exactly the condition that caused the incident
_t_repair_warns() {
  echo 'x' > "$DOTFILES_DIR/scripts/i.sh"
  mkdir -p "$CLAUDE_DIR/scripts"
  ln -sfn /nonexistent/i.sh "$CLAUDE_DIR/scripts/i.sh"
  LINKS_OUT=""
  relink_all
  if grep -q "\[warn\].*changed" <<<"$LINKS_OUT"; then
    report pass "relink_all summarises a repair as a warn"
  else
    report fail "relink_all summarises a repair as a warn" "$LINKS_OUT"
  fi
}
links_case repair_warns _t_repair_warns

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
