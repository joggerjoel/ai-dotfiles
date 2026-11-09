#!/usr/bin/env bash
# Tests for bin/procrun-retain: `retain` prunes rotated and dated logs and only
# reports single legacy logs. Real files with set mtimes; no network beyond
# uv's first fetch of croniter.
#
# Runs under bash 3.2 (stock macOS): no associative arrays, no mapfile.
# rc is read only inside the single-quoted conditions that check() evals.
# shellcheck disable=SC2034
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DOT=$(cd "$HERE/.." && pwd)
PRR="$DOT/bin/procrun-retain"
pass=0 fail=0

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

if [ -z "${PROCRUN_UV:-}" ]; then
  PROCRUN_UV=$(cd "$DOT" && { pyenv which uv 2>/dev/null || command -v uv || echo "$HOME/.local/bin/uv"; })
fi
if ! "$PROCRUN_UV" --version >/dev/null 2>&1; then
  echo "SKIP: uv not available; procrun-retain needs it"
  echo "0 passed, 0 failed"
  exit 0
fi
export PROCRUN_UV

TMP=$(mktemp -d "${TMPDIR:-/tmp}/procrun-retain-test.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
export PROCRUN_REGISTRY="$TMP/processes.toml"
L="$TMP/logs"

age() {  # age DAYS FILE...: set mtime DAYS days ago
  local d=$1; shift
  python3 -c 'import os, sys, time
t = time.time() - float(sys.argv[1]) * 86400
for p in sys.argv[2:]: os.utime(p, (t, t))' "$d" "$@"
}
OLD=$(python3 -c 'import datetime as d; print((d.date.today() - d.timedelta(days=40)).strftime("%Y-%m-%d"))')
OLDC=$(echo "$OLD" | tr -d -)
NEW=$(date +%Y-%m-%d)

setup() {
  rm -rf "$L"; mkdir -p "$L"
  # rotated: app.log with generations
  echo live > "$L/app.log"
  for f in app.log.1 app.log.2.gz "app.log-$OLDC" "app.log.$OLD"; do echo old > "$L/$f"; done
  echo recent > "$L/app.log.3"
  age 40 "$L/app.log.1" "$L/app.log.2.gz" "$L/app.log-$OLDC" "$L/app.log.$OLD"
  age 2 "$L/app.log.3"
  echo unrelated > "$L/app.logger.1"; age 40 "$L/app.logger.1"
  # legacy: one continuously appended file
  echo big > "$L/legacy.log"; age 40 "$L/legacy.log"
  # dated: band-YYYY-MM-DD.log
  echo old > "$L/band-$OLD.log"; age 40 "$L/band-$OLD.log"
  echo new > "$L/band-$NEW.log"
  echo nodate > "$L/band-misc.log"; age 40 "$L/band-misc.log"
  # dated name but recently written (a late writer): kept
  OLD2=$(python3 -c 'import datetime as d; print((d.date.today() - d.timedelta(days=41)).strftime("%Y%m%d"))')
  echo late > "$L/band-$OLD2.log"; age 1 "$L/band-$OLD2.log"
  # only one dated file, old: it is the newest match, so kept
  mkdir -p "$L/solo"; echo only > "$L/solo/solo-$OLD.log"; age 40 "$L/solo/solo-$OLD.log"
  cat > "$PROCRUN_REGISTRY" <<EOF
[[process]]
name = "app"
kind = "cron"
schedule = "* * * * *"
log = "$L/app.log"
retain = "30d"

[[process]]
name = "legacy"
kind = "cron"
schedule = "* * * * *"
progress = "$L/legacy.log"
retain = "30d"

[[process]]
name = "bands"
kind = "daemon"
pattern = "band"
log_glob = "$L/band-*.log"
retain = "30d"

[[process]]
name = "solo"
kind = "daemon"
pattern = "solo"
log_glob = "$L/solo/solo-*.log"
retain = "30d"

[[process]]
name = "no-retain"
kind = "cron"
schedule = "* * * * *"
log = "$L/keep.log"
EOF
  echo x > "$L/keep.log.1"; age 400 "$L/keep.log.1"
}

echo "warm-up (uv resolves croniter once)"
setup
"$PRR" --help >/dev/null 2>&1

echo "dry run"
setup
out=$("$PRR" --dry-run 2>&1); rc=$?
check "dry run exits 0" '[ $rc = 0 ]' "$out"
check "dry run lists old rotated generations" 'echo "$out" | grep -q "would prune $L/app.log.1 "' "$out"
check "dry run deletes nothing" '[ -f "$L/app.log.1" ] && [ -f "$L/band-$OLD.log" ]'

echo "prune"
setup
out=$("$PRR" 2>&1); rc=$?
check "exits 0" '[ $rc = 0 ]' "$out"
check "old numbered generations pruned" '[ ! -e "$L/app.log.1" ] && [ ! -e "$L/app.log.2.gz" ]' "$out"
check "old dated generations pruned" '[ ! -e "$L/app.log-$OLDC" ] && [ ! -e "$L/app.log.$OLD" ]' "$out"
check "a recent generation is kept" '[ -f "$L/app.log.3" ]'
check "the live log is never pruned" '[ -f "$L/app.log" ]'
check "a file that only shares the prefix is not a generation" '[ -f "$L/app.logger.1" ]'
check "an old dated log is pruned" '[ ! -e "$L/band-$OLD.log" ]' "$out"
check "today's dated log is kept" '[ -f "$L/band-$NEW.log" ]'
check "a dated log written recently is kept" '[ -f "$L/band-$OLD2.log" ]'
check "the newest dated match is never pruned" '[ -f "$L/solo/solo-$OLD.log" ]'
check "an undated match is kept and reported" '[ -f "$L/band-misc.log" ] && echo "$out" | grep -q "^undated $L/band-misc.log"' "$out"
check "a single legacy log is kept, not moved" '[ -f "$L/legacy.log" ] && [ "$(ls "$L" | grep -c "^legacy")" = 1 ]'
check "the legacy log is reported" 'echo "$out" | grep -q "^legacy $L/legacy.log .*not pruned or moved"' "$out"
check "an entry without retain is untouched" '[ -f "$L/keep.log.1" ]'
check "summary line counts" 'echo "$out" | tail -1 | grep -q "^pruned 5 file(s)"' "$out"

echo "errors"
printf '[[process]]\nname = "x"\nkind = "cron"\nschedule = "* * * * *"\nlog = "%s/app.log"\nretain = "soon"\n' "$L" > "$PROCRUN_REGISTRY"
out=$("$PRR" 2>&1); rc=$?
check "a bad retain fails" '[ $rc = 1 ] && echo "$out" | grep -q "FAIL: process .x.: retain"' "$out"
PROCRUN_REGISTRY="$TMP/missing.toml" "$PRR" >/dev/null 2>&1; rc=$?
check "a missing registry fails" '[ $rc = 1 ]'

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
