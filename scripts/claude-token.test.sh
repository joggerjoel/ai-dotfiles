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

TMP=$(mktemp -d -t claudetoken-test) || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

check() { # <name> <file body> <expected value>
  printf '%s\n' "$2" > "$TMP/env"
  local got
  got=$(HERDR_CLAUDE_ENV="$TMP/env" bash "$S" _token_from_env_file)
  [ "$got" = "$3" ] && ok "$1" || ko "$1" "got '$got', want '$3'"
}

FAKE='sk-ant-oat-FAKE-000'

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

# An unreadable or absent file must be empty, not an error.
got=$(HERDR_CLAUDE_ENV="$TMP/does-not-exist" bash "$S" _token_from_env_file)
[ "$got" = "" ] && ok "a missing .env yields nothing, not a failure" \
                || ko "a missing .env yields nothing, not a failure" "got '$got'"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
