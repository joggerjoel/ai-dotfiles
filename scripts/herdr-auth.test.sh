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
printf '%s' "$out" | grep -qE 'aorus4 +[^ ]+ +[^ ]+ +authed|aorus4.*authed' \
  && ok "status: reports aorus4 claude as authed" \
  || ko "status: reports aorus4 claude as authed"
# aorus contributes 0 authed / 3 missing; aorus4 contributes 1 authed (claude)
# / 2 missing. Six probes across two hosts: 1 authed, 5 missing.
printf '%s' "$out" | grep -q '1 authed, 5 missing' \
  && ok "status: prints a totals line" \
  || ko "status: prints a totals line" "$(printf '%s' "$out" | tail -1)"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
