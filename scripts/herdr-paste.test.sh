#!/usr/bin/env bash
# Tests for herdr-paste.py. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Every external command is stubbed on PATH and no test touches the real
# herdr socket or the fleet. Run it IN PLACE — copying it elsewhere breaks the
# relative stub path and would reach real commands.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
P="$HERE/herdr-paste.py"
pass=0 fail=0

TMP=$(mktemp -d -t herdrpaste-test) || exit 1
trap 'rm -rf "$TMP"' EXIT

export PATH="$ROOT/tests/paste-stubs:$PATH"

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

# --- payload validation ------------------------------------------------------
# `_validate` is an internal entry point so the rules can be exercised without
# a socket, a pane, or a human. It reads the candidate on stdin — never argv,
# which is world-readable through `ps`.

v() { printf '%s' "$1" | python3 "$P" _validate >/dev/null 2>&1; echo $?; }

eq "validate: a plain token is accepted" 0 "$(v 'sk-ant-abc123')"
eq "validate: empty is rejected" 1 "$(v '')"
eq "validate: an interior newline is rejected" 1 "$(v 'ab
cd')"
eq "validate: a tab is rejected" 1 "$(v "$(printf 'ab\tcd')")"
eq "validate: a C0 control byte is rejected" 1 "$(v "$(printf 'ab\001cd')")"
eq "validate: DEL is rejected" 1 "$(v "$(printf 'ab\177cd')")"

# These two cannot go through `v`: command substitution strips a trailing
# newline, and a literal C1 byte does not survive being typed into this file.
# Build them in python and feed them straight to stdin.
py_v() {  # <python-expression producing the candidate>
  python3 -c "import sys; sys.stdout.write($1)" |
    python3 "$P" _validate >/dev/null 2>&1
  echo $?
}

eq "validate: a trailing newline is rejected" 1 "$(py_v "'abcd' + chr(0x0A)")"
eq "validate: a C1 control codepoint is rejected" 1 "$(py_v "'abcd' + chr(0x85)")"
eq "validate: a C1 CSI codepoint is rejected" 1 "$(py_v "'abcd' + chr(0x9B)")"
eq "validate: non-ASCII is rejected" 1 "$(v 'abé')"
eq "validate: a bidi override is rejected" 1 "$(v 'ab‮cd')"

# A quote and a backslash are legal in a credential. They are dangerous only
# to a naive encoder, and the encoder — not the validator — is what handles
# them. Rejecting them here would refuse valid tokens for no gain.
eq "validate: a double quote is accepted" 0 "$(v 'ab"cd')"
eq "validate: a backslash is accepted" 0 "$(v 'ab\cd')"

# The rejection has to say what was wrong; a bare failure sends the operator
# hunting through a credential they cannot see.
printf '%s' "$(printf 'ab\001cd')" | python3 "$P" _validate 2>&1 |
  grep -qi "control\|printable\|ascii" &&
  ok "validate: rejection names the offending class" ||
  ko "validate: rejection names the offending class"

# The value must never be echoed, even back to the operator.
out=$(printf '%s' 'SENTINEL-XYZ' | python3 "$P" _validate 2>&1)
printf '%s' "$out" | grep -q 'SENTINEL-XYZ' &&
  ko "validate: never echoes the value" "leaked it" ||
  ok "validate: never echoes the value"

# --- CLI surface -------------------------------------------------------------

python3 "$P" >/dev/null 2>&1
eq "no verb exits 2 (usage)" 2 "$?"

python3 "$P" 2>&1 | grep -qi usage &&
  ok "no verb prints a usage line" ||
  ko "no verb prints a usage line"

python3 "$P" bogus >/dev/null 2>&1
eq "an unknown verb exits 2" 2 "$?"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
