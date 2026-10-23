#!/usr/bin/env bash
# Tests for herdr-integrations.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# No real herdr. A stub on PATH answers `integration status` from a fixture and
# `integration install <t>` from per-target fixtures, and records every call, so
# each case pins one classification: current, installed, updated, skipped,
# failed, and herdr absent.

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/herdr-integrations.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdr-integrations-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/herdr" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_DIR/calls"
case "$1 $2" in
  "integration status") cat "$STUB_DIR/status" ;;
  "integration install")
    t="$3"
    [ -f "$STUB_DIR/install.$t.out" ] && cat "$STUB_DIR/install.$t.out" \
      || echo "installed $t integration hook to $HOME/.$t/herdr-agent-state.sh"
    [ -f "$STUB_DIR/status.after" ] && cp "$STUB_DIR/status.after" "$STUB_DIR/status"
    [ -f "$STUB_DIR/install.$t.rc" ] && exit "$(cat "$STUB_DIR/install.$t.rc")"
    exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/herdr"

ALL_CURRENT='pi: current (v9) (/h/.pi/agent/extensions/herdr-agent-state.ts)
omp: not installed (/h/.omp/agent/extensions/herdr-omp-agent-state.ts)
claude: current (v11) (/h/.claude/hooks/herdr-agent-state.sh)
codex: current (v10) (/h/.codex/herdr-agent-state.sh)
cursor: current (v2) (/h/.cursor/herdr-agent-state.sh)
antigravity-cli: current (v4) (/h/.gemini/config/hooks/herdr-agent-state.sh)
grok: current (v3) (/h/.grok/hooks/herdr-agent-state.sh)
letta (experimental): not installed (/h/.letta/hooks/herdr-agent-session.sh)'

reset_stub() {
  rm -rf "$TMP/stub"; mkdir -p "$TMP/stub"
  printf '%s\n' "$ALL_CURRENT" > "$TMP/stub/status"
}

run() { # → sets OUT and RC
  OUT=$(STUB_DIR="$TMP/stub" PATH="$TMP/bin:/usr/bin:/bin" bash "$S" 2>&1)
  RC=$?
}

expect_line() { # <name> <pattern>
  printf '%s\n' "$OUT" | grep -qE -- "$2" && ok "$1" || ko "$1" "no line matching '$2' in:
$OUT"
}

# ── all six current ──────────────────────────────────────────────
reset_stub; run
[ "$RC" -eq 0 ] && ok "all current: exit 0" || ko "all current: exit 0" "rc=$RC"
expect_line "all current: claude reported current with version" '^ *✓ claude: current \(v11\)$'
expect_line "all current: summary counts six current" \
  '^herdr-integrations: installed=0 updated=0 current=6 skipped=0 failed=0$'
got=$(grep '^integration install' "$TMP/stub/calls" | awk '{print $3}' | tr '\n' ' ')
[ "$got" = "pi claude codex cursor antigravity-cli grok " ] \
  && ok "install runs for every target, in roster order, even when current" \
  || ko "install runs for every target, in roster order, even when current" "calls: $got"
expect_line "letta's parenthetical name does not leak into any target line" '^herdr-integrations:'
if printf '%s\n' "$OUT" | grep -q "letta"; then ko "letta is not a target" "letta mentioned"; else ok "letta is not a target"; fi

# ── harness absent → skipped, not failed ─────────────────────────
reset_stub
printf 'pi extension directory not found at /h/.pi/agent/extensions. install pi first\n' > "$TMP/stub/install.pi.out"
run
[ "$RC" -eq 0 ] && ok "absent harness: exit 0" || ko "absent harness: exit 0" "rc=$RC"
expect_line "absent harness: pi skipped with herdr's hint" '^ *○ pi: skipped \(install pi first\)$'
expect_line "absent harness: counted as skipped" 'installed=0 updated=0 current=5 skipped=1 failed=0$'

# ── not installed → installed ────────────────────────────────────
reset_stub
printf '%s\n' "$ALL_CURRENT" | sed 's|^grok: current (v3)|grok: not installed|' > "$TMP/stub/status"
printf '%s\n' "$ALL_CURRENT" > "$TMP/stub/status.after"
run
expect_line "fresh install: grok reported installed with new version" '^ *✓ grok: installed \(v3\)$'
expect_line "fresh install: counted as installed" 'installed=1 updated=0 current=5 skipped=0 failed=0$'

# ── outdated → updated ───────────────────────────────────────────
reset_stub
printf '%s\n' "$ALL_CURRENT" | sed 's|^codex: current (v10)|codex: outdated (v9)|' > "$TMP/stub/status"
printf '%s\n' "$ALL_CURRENT" > "$TMP/stub/status.after"
run
expect_line "upgrade: codex reported updated old → new" '^ *✓ codex: updated v9 → v10$'
expect_line "upgrade: counted as updated" 'installed=0 updated=1 current=5 skipped=0 failed=0$'

# ── install failure → failed, exit 1 ─────────────────────────────
reset_stub
printf 'permission denied writing /h/.cursor/hooks.json\n' > "$TMP/stub/install.cursor.out"
printf '1\n' > "$TMP/stub/install.cursor.rc"
run
[ "$RC" -eq 1 ] && ok "failure: exit 1" || ko "failure: exit 1" "rc=$RC"
expect_line "failure: cursor reported failed with herdr's message" '^ *✗ cursor: failed — permission denied'
expect_line "failure: other targets still processed" 'installed=0 updated=0 current=5 skipped=0 failed=1$'

# ── herdr absent → skip, exit 0 ──────────────────────────────────
OUT=$(PATH="/usr/bin:/bin" bash "$S" 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "no herdr: exit 0" || ko "no herdr: exit 0" "rc=$RC"
expect_line "no herdr: says so" '^ *○ herdr not installed'
expect_line "no herdr: zero summary" '^herdr-integrations: installed=0 updated=0 current=0 skipped=0 failed=0$'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
