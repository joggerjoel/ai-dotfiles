#!/usr/bin/env bash
# Tests for the log contract v1 helpers and parser profiles in lib/log-contract/.
# Picked up by run-all-tests.sh and CI. Runs the Node and Python suites, then
# checks the Bash helper here, and prints one "N passed, M failed" total.
set -uo pipefail

DOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$DOT/lib/log-contract"
pass=0
fail=0

ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

add_counts() {
  local out=$1 p f
  p=$(printf '%s' "$out" | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+')
  f=$(printf '%s' "$out" | grep -oE '[0-9]+ failed' | tail -1 | grep -oE '[0-9]+')
  if [ -z "$p" ] || [ "${f:-1}" -ne 0 ]; then printf '%s\n' "$out"; fi
  if [ -z "$p" ]; then fail=$((fail + 1)); return; fi
  pass=$((pass + p))
  fail=$((fail + ${f:-0}))
}

# ---- Node: logv1.js and log-profile.js ----
add_counts "$(node "$DOT/tests/log-contract/log-contract.test.js" 2>&1)"

# ---- Python: logv1.py ----
add_counts "$(python3 - "$DOT/tests/log-contract" <<'PY' 2>&1
import sys
import unittest
suite = unittest.defaultTestLoader.discover(sys.argv[1], pattern="test_logv1.py")
result = unittest.TextTestRunner(stream=sys.stdout, verbosity=0).run(suite)
failed = len(result.failures) + len(result.errors)
print(f"{result.testsRun - failed - len(result.skipped)} passed, {failed} failed")
PY
)"

# ---- Bash: logv1.sh ----
# Each check runs in a subshell so the helper's state does not leak between them.
bash_record() {
  ( # shellcheck source=../lib/log-contract/logv1.sh
    . "$LIB/logv1.sh"; "$@" 2>&1 )
}

line=$(PROCRUN_RUN_ID=abc PROCRUN_PROC=demo bash_record logv1 info job.start 'Starting' rows=3)
if printf '%s' "$line" | python3 -c '
import json, re, sys
r = json.loads(sys.stdin.read())
assert list(r) == ["v", "ts", "level", "proc", "run_id", "event", "msg", "fields"], list(r)
assert r["v"] == 1 and r["level"] == "info" and r["event"] == "job.start"
assert re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$", r["ts"]), r["ts"]
assert (r["proc"], r["run_id"], r["fields"]) == ("demo", "abc", {"rows": "3"})
'; then ok; else bad "bash helper writes a v1 record with procrun ids"; fi

line=$(bash_record logv1 error db.lock_timeout $'Lock "wait"\ntimeout\\' 'path=C:\tmp' err.type=MariaDB err.code=1205)
if printf '%s' "$line" | python3 -c '
import json, sys
text = sys.stdin.read()
assert "\n" not in text, repr(text)
r = json.loads(text)
assert r["msg"] == "Lock \"wait\" timeout\\", r["msg"]
assert r["fields"] == {"path": "C:\\tmp"}, r["fields"]
assert r["err"] == {"type": "MariaDB", "code": "1205"}, r["err"]
'; then ok; else bad "bash helper escapes JSON, keeps msg on one line and fills err"; fi

line=$(PROCRUN_RUN_ID='' bash_record logv1 info a.b x)
if printf '%s' "$line" | python3 -c '
import json, re, sys
assert re.match(r"^[0-9a-f]{32}$", json.loads(sys.stdin.read())["run_id"])
'; then ok; else bad "bash helper generates a 128-bit run_id outside procrun"; fi

if ! bash_record logv1 fatal a.b x >/dev/null && ! bash_record logv1 info 'Bad Event' x >/dev/null \
   && ! bash_record logv1 info a.b x notapair >/dev/null; then
  ok
else
  bad "bash helper rejects unknown levels, bad events and non key=value arguments"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
