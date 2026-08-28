#!/usr/bin/env bash
# Tests for claude-token.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Scope is deliberately the FILE PARSE and nothing else. No ssh, no ansible, no
# API call, and no token — every case below uses an obviously fake value.
#
# The first case is the one that matters. In production the .env held
# `CLAUDE_CODE_OAUTH_TOKEN=` with an empty value, written when `read -rs TOKEN`
# ran in one shell and the `printf` in another. Every "is the token set?" check
# said yes, and it authenticated nothing.

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/claude-token.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/claudetoken-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

check() { # <name> <file body> <expected value>
  printf '%s\n' "$2" > "$TMP/env"
  local got
  got=$(HERDR_CLAUDE_ENV="$TMP/env" bash "$S" _token_from_env_file)
  [ "$got" = "$3" ] && ok "$1" || ko "$1" "got '$got', want '$3'"
}

# Every fixture below MUST contain `r`, `t`, and a backslash-adjacent shape,
# because the parser this replaced used `[^"'\r]` and `[ \t]` under BSD sed,
# where those escapes are not interpreted — the classes silently excluded the
# literal characters `r`, `t` and `\`. The old fake value, `sk-ant-oat-FAKE-000`,
# contained no `r`, so a green suite sat on top of a parser that could not read
# a real token. A fixture that dodges the failing input tests nothing.
FAKE='sk-ant-oatr1-Rr7tTx_yZ-qQwErTy0123456789-abcXYZ'

check "an empty value is not a token (the production bug)" \
      'CLAUDE_CODE_OAUTH_TOKEN=' ''
check "a whitespace-only value is not a token" \
      'CLAUDE_CODE_OAUTH_TOKEN=   ' ''
check "bare assignment" \
      "CLAUDE_CODE_OAUTH_TOKEN=$FAKE" "$FAKE"
check "export prefix" \
      "export CLAUDE_CODE_OAUTH_TOKEN=$FAKE" "$FAKE"
check "double quoted" \
      "CLAUDE_CODE_OAUTH_TOKEN=\"$FAKE\"" "$FAKE"
check "single quoted" \
      "CLAUDE_CODE_OAUTH_TOKEN='$FAKE'" "$FAKE"
check "trailing whitespace is trimmed" \
      "CLAUDE_CODE_OAUTH_TOKEN=$FAKE   " "$FAKE"
check "found among other keys" \
      "OPENAI_API_KEY=zzz
CLAUDE_CODE_OAUTH_TOKEN=$FAKE
FOO=bar" "$FAKE"
check "a commented-out line is not a token" \
      "# CLAUDE_CODE_OAUTH_TOKEN=$FAKE" ''
check "absent" \
      'OPENAI_API_KEY=zzz' ''
# Appending is how this file gets written, so a later real value must win over
# an earlier broken one rather than the parse stopping at the first match.
check "a later value wins over an earlier empty one" \
      "CLAUDE_CODE_OAUTH_TOKEN=
CLAUDE_CODE_OAUTH_TOKEN=$FAKE" "$FAKE"

# The exact shape that broke in production: a long, real-length token. Kept as
# its own case so the failure names itself rather than hiding inside the others.
LONGFAKE='sk-ant-oat01-rTrTrTrT_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789-rrrttt_AAAA-BBBBBB'
check "a long token containing r and t (the production failure)" \
      "CLAUDE_CODE_OAUTH_TOKEN=$LONGFAKE" "$LONGFAKE"

# An unreadable or absent file must be empty, not an error.
got=$(HERDR_CLAUDE_ENV="$TMP/does-not-exist" bash "$S" _token_from_env_file)
[ "$got" = "" ] && ok "a missing .env yields nothing, not a failure" \
                || ko "a missing .env yields nothing, not a failure" "got '$got'"

# --- dry-run flag -------------------------------------------------------------
#
# The bug that made `just claude-token` incapable of deploying anything. The
# flags were built with `${check:+--check --diff}`, which expands when the
# variable is NON-EMPTY — and check=0 is non-empty. So --check was passed on
# every run: ansible reported `changed:` for three tasks, printed a diff,
# reported no failures, and wrote nothing at all. The host still had no token
# file and no .bashrc stanza afterwards.
got=$(bash "$S" _ansible_flags 0)
[ -z "$got" ] \
  && ok "check=0 produces no flags (a deploy actually deploys)" \
  || ko "check=0 produces no flags (a deploy actually deploys)" "got '$got'"

got=$(bash "$S" _ansible_flags 1)
[ "$got" = "--check --diff" ] \
  && ok "check=1 produces --check --diff" \
  || ko "check=1 produces --check --diff" "got '$got'"

got=$(bash "$S" _ansible_flags)
[ -z "$got" ] \
  && ok "an absent check value produces no flags" \
  || ko "an absent check value produces no flags" "got '$got'"

# --- generated inventory ------------------------------------------------------
#
# The first live run failed here, not on the token. `mktemp -t claude-token-inv`
# produces a random suffix and no extension, and ansible chooses its inventory
# parser from the FILENAME — so it tried the INI plugin on YAML and reported
# `Invalid host pattern 'aorus_ai:'`, an error about the content that was really
# about the name. Checking that the YAML is well-formed would not have caught
# it; only handing the real file to ansible does.
if command -v ansible-inventory >/dev/null 2>&1; then
  inv=$(bash "$S" _inventory_for aorus4 aorus6)
  case "$inv" in
    *.yml) ok "the generated inventory is named so ansible parses it as YAML" ;;
    *)     ko "the generated inventory is named so ansible parses it as YAML" "got '$inv'" ;;
  esac

  if out=$(ansible-inventory -i "$inv" --list 2>&1); then
    if printf '%s' "$out" | grep -q 'aorus4' && printf '%s' "$out" | grep -q 'aorus6'; then
      ok "ansible parses the generated inventory and finds every host"
    else
      ko "ansible parses the generated inventory and finds every host" "hosts absent from --list"
    fi
  else
    ko "ansible parses the generated inventory and finds every host" "$(printf '%s' "$out" | head -2)"
  fi
  case "$inv" in */claude-token-inv*/inventory.yml) rm -rf "$(dirname "$inv")" ;; esac
else
  printf '  SKIP  inventory tests (ansible-inventory not installed)\n'
fi

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
