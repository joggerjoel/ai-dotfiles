#!/usr/bin/env bash
# Tests for herdr-auth.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Every external command (ssh, herdr, open) is served by a stub on PATH, so
# nothing here touches the real fleet and no auth flow is ever started.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
A="$HERE/herdr-auth.sh"
pass=0 fail=0

TMP=$(mktemp -d -t herdrauth-test) || exit 1
trap 'rm -rf "$TMP"' EXIT

export PATH="$ROOT/tests/auth-stubs:$PATH"
export HERDR_AUTH_FIXTURE="$TMP/fixture"
export HERDR_AUTH_OPENED="$TMP/opened"
mkdir -p "$HERDR_AUTH_FIXTURE"

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

# Each fixture file is named <host>.<probe> and holds that probe's stdout.
fixture() { printf '%s\n' "$2" > "$HERDR_AUTH_FIXTURE/$1"; }

# --- probes -----------------------------------------------------------------

fixture aorus.cursor 'Not logged in'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe cursor aorus)
[ "$got" = missing ] && ok "cursor: 'Not logged in' -> missing" \
                     || ko "cursor: 'Not logged in' -> missing" "got '$got'"

fixture aorus.cursor 'Logged in as joel@example.com'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe cursor aorus)
[ "$got" = authed ] && ok "cursor: logged-in line -> authed" \
                    || ko "cursor: logged-in line -> authed" "got '$got'"

fixture aorus.codex 'Not logged in'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe codex aorus)
[ "$got" = missing ] && ok "codex: 'Not logged in' -> missing" \
                     || ko "codex: 'Not logged in' -> missing" "got '$got'"

fixture aorus.codex 'Logged in using ChatGPT'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe codex aorus)
[ "$got" = authed ] && ok "codex: 'Logged in using ChatGPT' -> authed" \
                    || ko "codex: 'Logged in using ChatGPT' -> authed" "got '$got'"

fixture aorus.claude 'missing'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe claude aorus)
[ "$got" = missing ] && ok "claude: no credentials file -> missing" \
                     || ko "claude: no credentials file -> missing" "got '$got'"

fixture aorus.claude 'authed'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe claude aorus)
[ "$got" = authed ] && ok "claude: credentials file -> authed" \
                    || ko "claude: credentials file -> authed" "got '$got'"

# --- status table -----------------------------------------------------------

fixture aorus.cursor 'Not logged in'
fixture aorus.codex  'Not logged in'
fixture aorus.claude 'missing'
fixture aorus4.cursor 'Not logged in'
fixture aorus4.codex  'Not logged in'
fixture aorus4.claude 'authed'

out=$(HERDR_AUTH_HOSTS="aorus aorus4" bash "$A" status)
printf '%s' "$out" | grep -q 'aorus4' \
  && ok "status: lists every host" \
  || ko "status: lists every host" "missing aorus4"
# Pin the COLUMN, not just the row: aorus4 is missing/missing/authed, so
# `authed` must be the third state on the line. A permissive `aorus4.*authed`
# would pass even if authed landed in the cursor or codex column.
printf '%s' "$out" | grep -qE '^aorus4 +missing +missing +authed' \
  && ok "status: reports aorus4 claude as authed" \
  || ko "status: reports aorus4 claude as authed" "$(printf '%s' "$out" | grep aorus4)"
# aorus contributes 0 authed / 3 missing; aorus4 contributes 1 authed (claude)
# / 2 missing. Six probes across two hosts: 1 authed, 5 missing, 0 unreachable.
printf '%s' "$out" | grep -q '1 authed, 5 missing, 0 unreachable' \
  && ok "status: prints a totals line" \
  || ko "status: prints a totals line" "$(printf '%s' "$out" | tail -1)"

# An unreachable host must report all three columns as `unreachable` and be
# tallied in its own bucket, not silently counted as `missing` — later phases
# drive login flows off these probes and a dead host must not look merely
# logged-out.
: > "$HERDR_AUTH_FIXTURE/aorus5.unreachable"
out=$(HERDR_AUTH_HOSTS="aorus4 aorus5" bash "$A" status)
printf '%s' "$out" | grep -qE '^aorus5 +unreachable +unreachable +unreachable' \
  && ok "status: reports an unreachable host distinctly" \
  || ko "status: reports an unreachable host distinctly" "$(printf '%s' "$out" | grep aorus5)"
printf '%s' "$out" | grep -q '1 authed, 2 missing, 3 unreachable' \
  && ok "status: tallies unreachable separately from missing" \
  || ko "status: tallies unreachable separately from missing" "$(printf '%s' "$out" | tail -1)"

# --- url extraction and redaction -------------------------------------------
# SYNTHETIC challenge/uuid only. A real one must never enter this repo.
SAMPLE='Starting login process...
Waiting for browser authentication...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_CHALLENGE_VALUE&uuid=00000000-0000-0000-0000-000000000000&mode=login&redirectTarget=cli'

got=$(printf '%s\n' "$SAMPLE" | bash "$A" _extract_url)
[ "$got" = 'https://cursor.com/loginDeepControl?challenge=SYNTHETIC_CHALLENGE_VALUE&uuid=00000000-0000-0000-0000-000000000000&mode=login&redirectTarget=cli' ] \
  && ok "extract_url: pulls the URL out of surrounding noise" \
  || ko "extract_url: pulls the URL out of surrounding noise" "got '$got'"

got=$(printf 'no link here at all\n' | bash "$A" _extract_url)
[ -z "$got" ] && ok "extract_url: empty when no URL present" \
              || ko "extract_url: empty when no URL present" "got '$got'"

got=$(printf '%s\n' "$SAMPLE" | bash "$A" _redact)
printf '%s' "$got" | grep -q 'SYNTHETIC_CHALLENGE_VALUE' \
  && ko "redact: strips the challenge value" "challenge survived" \
  || ok "redact: strips the challenge value"
printf '%s' "$got" | grep -q '00000000-0000' \
  && ko "redact: strips the uuid value" "uuid survived" \
  || ok "redact: strips the uuid value"
printf '%s' "$got" | grep -q 'challenge=REDACTED' \
  && ok "redact: keeps the parameter name" \
  || ko "redact: keeps the parameter name" "$got"
printf '%s' "$got" | grep -q 'redirectTarget=cli' \
  && ok "redact: leaves non-secret params alone" \
  || ko "redact: leaves non-secret params alone"

got=$(printf 'https://x.test/a?token=abc123&access_token=def456&code=ghi789\n' | bash "$A" _redact)
printf '%s' "$got" | grep -qE 'abc123|def456|ghi789' \
  && ko "redact: covers token, access_token, code" "a value survived: $got" \
  || ok "redact: covers token, access_token, code"

# The allowlist's whole reason for existing: a parameter nobody anticipated is
# redacted by default. A denylist would print these two in the clear.
got=$(printf 'https://x.test/a?state=SECRET_STATE&verifier=SECRET_VERIFIER&mode=login\n' | bash "$A" _redact)
printf '%s' "$got" | grep -qE 'SECRET_STATE|SECRET_VERIFIER' \
  && ko "redact: redacts unanticipated params (allowlist)" "leaked: $got" \
  || ok "redact: redacts unanticipated params (allowlist)"
printf '%s' "$got" | grep -q 'mode=login' \
  && ok "redact: keeps allowlisted params readable" \
  || ko "redact: keeps allowlisted params readable" "$got"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
