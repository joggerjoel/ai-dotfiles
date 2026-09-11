#!/usr/bin/env bash
# Tests for setup.sh's serena config seeding. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a live hook.
#
# The bug: ensure_serena_dashboard_off() creates ~/.serena/serena_config.yml
# when absent, seeding three dashboard keys under the comment "Serena fills all
# other keys with defaults". It does not. serena REQUIRES a `projects` key and
# aborts on every launch without one:
#
#     SerenaConfigError: `projects` key not found in Serena configuration.
#
# So the MCP server never completed a handshake and `claude mcp list` showed
# only "Connection closed" — a message that says nothing about the real cause.
# Hosts where serena had run before setup.sh had a complete file and worked,
# which is why this never reproduced on a developer machine. Every freshly
# provisioned fleet host got the truncated seed and a permanently broken serena.
#
# Two invariants:
#   1. a seeded config is one serena can actually load
#   2. a host already carrying a truncated config is repaired, not left broken,
#      and a complete config is never clobbered
#
# Runs under bash 3.2 (stock macOS) as well as bash 5.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SETUP="$ROOT/setup.sh"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/setupserena.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

DISPATCH=$(grep -n '^case "${1:-}" in' "$SETUP" | cut -d: -f1)
if [ -z "$DISPATCH" ]; then
  printf '  FAIL  cannot locate the setup.sh dispatch case — test needs updating\n'
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
sed -n "1,$((DISPATCH - 1))p" "$SETUP" > "$TMP/defs.sh"

# Run ensure_serena_dashboard_off against a throwaway HOME. SERENA_CONFIG is
# derived from $HOME when the definitions are sourced, so HOME must be set on
# the way in, not after.
run_in_home() {
  local home="$1"
  HOME="$home" bash -c "
    source '$TMP/defs.sh' >/dev/null 2>&1
    ensure_serena_dashboard_off >/dev/null 2>&1
  "
}

cfg_of() { printf '%s/.serena/serena_config.yml' "$1"; }

# --- 1. a seeded config is loadable -------------------------------------------

H="$TMP/fresh"
mkdir -p "$H"
run_in_home "$H"
C=$(cfg_of "$H")

if [ -f "$C" ]; then
  ok "a missing serena config is created"
else
  ko "a missing serena config is created" "no file at $C"
fi

if grep -qE '^projects:' "$C" 2>/dev/null; then
  ok "the seeded config carries the required \`projects\` key"
else
  ko "the seeded config carries the required \`projects\` key" \
     "serena aborts on every launch without it"
fi

if grep -qE '^web_dashboard:[[:space:]]*false' "$C" 2>/dev/null; then
  ok "the seeded config still disables the dashboard"
else
  ko "the seeded config still disables the dashboard" "$(cat "$C" 2>/dev/null)"
fi

# The whole point: what gets written must be valid YAML serena can parse.
if command -v python3 >/dev/null 2>&1; then
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$C'))
sys.exit(0 if isinstance(d, dict) and 'projects' in d else 1)
" 2>/dev/null; then
    ok "the seeded config parses as YAML with a projects key"
  else
    ko "the seeded config parses as YAML with a projects key"
  fi
fi

# --- 2. an already-broken host is repaired ------------------------------------

# Exactly the file the old seed produced, which is what the fleet is carrying.
H="$TMP/truncated"
mkdir -p "$H/.serena"
cat > "$(cfg_of "$H")" <<'YAML'
# Seeded by setup.sh. Serena fills all other keys with defaults; edit freely.
gui_log_window: false
web_dashboard: false
web_dashboard_open_on_launch: false
YAML
run_in_home "$H"
C=$(cfg_of "$H")

if grep -qE '^projects:' "$C"; then
  ok "a truncated config already on disk is repaired"
else
  ko "a truncated config already on disk is repaired" \
     "still missing projects — provisioned hosts stay broken"
fi

if grep -qE '^web_dashboard:[[:space:]]*false' "$C"; then
  ok "repairing a truncated config preserves the dashboard settings"
else
  ko "repairing a truncated config preserves the dashboard settings"
fi

# --- 3. a complete config is not clobbered ------------------------------------

H="$TMP/complete"
mkdir -p "$H/.serena"
cat > "$(cfg_of "$H")" <<'YAML'
gui_log_window: false
web_dashboard: false
web_dashboard_open_on_launch: false
log_level: 20
projects:
  - /home/someone/code/a-real-project
YAML
run_in_home "$H"
C=$(cfg_of "$H")

if grep -q 'a-real-project' "$C"; then
  ok "an existing projects list is left alone"
else
  ko "an existing projects list is left alone" "the user's projects were dropped"
fi

n=$(grep -cE '^projects:' "$C")
[ "$n" -eq 1 ] \
  && ok "a complete config does not gain a second projects key" \
  || ko "a complete config does not gain a second projects key" "found $n"

if grep -qE '^log_level:' "$C"; then
  ok "unrelated keys survive"
else
  ko "unrelated keys survive"
fi

# --- 4. idempotent across repeated runs ---------------------------------------

# update.yml runs `setup.sh update` on a schedule, so this executes over and
# over on the same file. Appending on each pass would corrupt it slowly.
H="$TMP/repeat"
mkdir -p "$H"
run_in_home "$H"; run_in_home "$H"; run_in_home "$H"
C=$(cfg_of "$H")

n=$(grep -cE '^projects:' "$C")
[ "$n" -eq 1 ] \
  && ok "three runs leave exactly one projects key" \
  || ko "three runs leave exactly one projects key" "found $n"

n=$(grep -cE '^web_dashboard:' "$C")
[ "$n" -eq 1 ] \
  && ok "three runs leave exactly one web_dashboard key" \
  || ko "three runs leave exactly one web_dashboard key" "found $n"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
