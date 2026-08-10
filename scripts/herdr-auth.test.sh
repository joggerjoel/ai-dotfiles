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

# --- regression: sed-pipeline leaks, replaced by the python3 implementation -

# Finding 1 (CRITICAL): a fragment token. The old sed pipeline only ever
# matched a key after `?` or `&`, so anything after `#` — including an
# implicit/PKCE access token, which several OAuth flows put in the fragment —
# survived in the clear.
got=$(printf 'https://x.test/callback#access_token=LEAKED&state=xyz\n' | bash "$A" _redact)
printf '%s' "$got" | grep -q 'LEAKED' \
  && ko "redact: closes the fragment leak (#access_token)" "leaked: $got" \
  || ok "redact: closes the fragment leak (#access_token)"
printf '%s' "$got" | grep -q 'access_token=REDACTED' \
  && ok "redact: fragment key is redacted, not dropped" \
  || ko "redact: fragment key is redacted, not dropped" "$got"

# Finding 2 (CRITICAL): a key=value token with no leading `?`/`&` at all —
# the first token on a line. The old sed pass required a literal separator
# right before the key, so the very first token on a line was never touched.
got=$(printf 'code=BARE_LEAK_TEST&mode=login\n' | bash "$A" _redact)
printf '%s' "$got" | grep -q 'BARE_LEAK_TEST' \
  && ko "redact: closes the no-separator leak (line-leading key)" "leaked: $got" \
  || ok "redact: closes the no-separator leak (line-leading key)"
printf '%s' "$got" | grep -q '^code=REDACTED&mode=login$' \
  && ok "redact: line-leading key redacted, trailing allowlisted key kept" \
  || ko "redact: line-leading key redacted, trailing allowlisted key kept" "$got"

# Finding 3 (CRITICAL): a forged sentinel. The old implementation protected
# allowlisted keys by swapping their `=` for a literal `\001`, then swapping
# it back at the end — but redact() runs on raw pane text, not a guaranteed-
# clean URL, so an attacker-controlled `\001` already in the input rewrote
# back into a live `=`, reconstructing `secret=LEAKED` in the clear. This
# implementation strips C0 control bytes up front and never uses a sentinel,
# so there is nothing for a forged control byte to collide with.
got=$(printf '?secret\001LEAKED&mode=login\n' | bash "$A" _redact)
printf '%s' "$got" | grep -q 'secret=LEAKED' \
  && ko "redact: closes the forged-sentinel leak" "reconstructed: $got" \
  || ok "redact: closes the forged-sentinel leak"
printf '%s' "$got" | grep -q $'\001' \
  && ko "redact: strips the raw control byte" "survived in: $got" \
  || ok "redact: strips the raw control byte"

# Finding 4 (IMPORTANT): a repeated key. Documented semantic: every
# occurrence is judged independently by its own key name, with no memory of
# earlier occurrences. A repeated allowlisted key (mode is never secret by
# definition) is left alone on every occurrence...
got=$(printf '?mode=login&mode=LEAKED_SECOND\n' | bash "$A" _redact)
[ "$got" = '?mode=login&mode=LEAKED_SECOND' ] \
  && ok "redact: repeated allowlisted key left alone on every occurrence" \
  || ko "redact: repeated allowlisted key left alone on every occurrence" "got '$got'"
# ...while a repeated NON-allowlisted key is redacted on every occurrence —
# fail-closed, no "first one wins" special case that could let a later
# duplicate slip through.
got=$(printf '?token=AAA&token=BBB\n' | bash "$A" _redact)
printf '%s' "$got" | grep -qE 'AAA|BBB' \
  && ko "redact: repeated non-allowlisted key redacted on every occurrence" "leaked: $got" \
  || ok "redact: repeated non-allowlisted key redacted on every occurrence"
[ "$got" = '?token=REDACTED&token=REDACTED' ] \
  && ok "redact: repeated redaction hits both occurrences, not just one" \
  || ko "redact: repeated redaction hits both occurrences, not just one" "got '$got'"

# Finding 5 (IMPORTANT): extract_url corrupting the URL it returns. Real pane
# output can trail a URL with prose punctuation or an ANSI reset code with no
# whitespace in between; `[^[:space:]]+` swallowed both into the "URL".
got=$(printf 'Open this link: https://x.test/a?mode=login.\n' | bash "$A" _extract_url)
[ "$got" = 'https://x.test/a?mode=login' ] \
  && ok "extract_url: strips trailing prose punctuation" \
  || ko "extract_url: strips trailing prose punctuation" "got '$got'"

got=$(printf 'Open this link: https://x.test/a?mode=login\x1b[0m\n' | bash "$A" _extract_url)
[ "$got" = 'https://x.test/a?mode=login' ] \
  && ok "extract_url: strips a trailing ANSI escape" \
  || ko "extract_url: strips a trailing ANSI escape" "got '$got'"

# --- cursor login batch -----------------------------------------------------
: > "$HERDR_AUTH_OPENED"
fixture aorus.cursorlogin 'Starting login process...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_A&uuid=00000000-0000-0000-0000-00000000000a&mode=login&redirectTarget=cli'
fixture aorus4.cursorlogin 'Starting login process...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_B&uuid=00000000-0000-0000-0000-00000000000b&mode=login&redirectTarget=cli'

# 2>&1: the security property under test is that the URL never reaches the
# TERMINAL, which is both streams. Capturing stdout alone would let a
# regression that leaks the URL via stderr slip through this guard undetected.
out=$(HERDR_AUTH_HOSTS="aorus aorus4" bash "$A" login --cli cursor --no-wait 2>&1)

[ "$(grep -c . "$HERDR_AUTH_OPENED")" = 2 ] \
  && ok "cursor login: opens one URL per host" \
  || ko "cursor login: opens one URL per host" "opened $(grep -c . "$HERDR_AUTH_OPENED")"
grep -q 'SYNTHETIC_A' "$HERDR_AUTH_OPENED" && grep -q 'SYNTHETIC_B' "$HERDR_AUTH_OPENED" \
  && ok "cursor login: opens the real URL for each host" \
  || ko "cursor login: opens the real URL for each host"
printf '%s' "$out" | grep -qE 'SYNTHETIC_A|SYNTHETIC_B' \
  && ko "cursor login: never prints a challenge" "leaked: $out" \
  || ok "cursor login: never prints a challenge"
printf '%s' "$out" | grep -q 'opened login URL for host aorus4' \
  && ok "cursor login: logs per host without the URL" \
  || ko "cursor login: logs per host without the URL" "$out"

fixture aorus.cursorlogin 'some error, no link'
: > "$HERDR_AUTH_OPENED"
out=$(HERDR_AUTH_HOSTS="aorus" bash "$A" login --cli cursor --no-wait)
[ "$(grep -c . "$HERDR_AUTH_OPENED")" = 0 ] \
  && ok "cursor login: opens nothing when no URL is printed" \
  || ko "cursor login: opens nothing when no URL is printed"
printf '%s' "$out" | grep -q 'no login URL' \
  && ok "cursor login: reports a missing URL loudly" \
  || ko "cursor login: reports a missing URL loudly" "$out"

# An unreachable host must not have a login fired at it: a device code spent
# on a dead host expires unused. host_reachable() already gates cmd_status
# this way (Task 1); cmd_login must reuse it, report the host, and move on to
# the next one rather than trying cursor-agent against it.
: > "$HERDR_AUTH_FIXTURE/aorus5.unreachable"
fixture aorus4.cursorlogin 'Starting login process...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_B&uuid=00000000-0000-0000-0000-00000000000b&mode=login&redirectTarget=cli'
: > "$HERDR_AUTH_OPENED"
out=$(HERDR_AUTH_HOSTS="aorus5 aorus4" bash "$A" login --cli cursor --no-wait)
[ "$(grep -c . "$HERDR_AUTH_OPENED")" = 1 ] \
  && ok "cursor login: skips an unreachable host, still opens the reachable one" \
  || ko "cursor login: skips an unreachable host, still opens the reachable one" "opened $(grep -c . "$HERDR_AUTH_OPENED")"
printf '%s' "$out" | grep -q 'host aorus5.*unreachable' \
  && ok "cursor login: reports the unreachable host by name and reason" \
  || ko "cursor login: reports the unreachable host by name and reason" "$out"
# Distinguish "skipped, unreachable" from "tried and got no URL" — a dead
# host must never fall into the generic no-login-URL message, or an operator
# cannot tell a dead box from a cursor-agent failure.
printf '%s' "$out" | grep -q 'aorus5.*no login URL' \
  && ko "cursor login: unreachable host must not report as a bare login failure" "$out" \
  || ok "cursor login: unreachable host must not report as a bare login failure"

# --- completion polling -----------------------------------------------------
export HERDR_AUTH_POLL_INTERVAL=0
export HERDR_AUTH_POLL_CEILING=1

fixture aorus.cursor 'Logged in as joel@example.com'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _wait cursor aorus)
[ "$got" = ok ] && ok "wait: returns ok once the probe reports authed" \
                || ko "wait: returns ok once the probe reports authed" "got '$got'"

fixture aorus.cursor 'Not logged in'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _wait cursor aorus)
[ "$got" = timeout ] && ok "wait: returns timeout at the ceiling" \
                     || ko "wait: returns timeout at the ceiling" "got '$got'"

# Real-arithmetic regression guard: interval=0 must no longer short-circuit
# through a special case, it must terminate through the SAME ceiling
# arithmetic production uses. With interval=1 and ceiling=2 a host that never
# authenticates must genuinely loop (not exit on iteration 1) and still
# return timeout — costs ~2s of real sleeping, acceptable for the coverage.
export HERDR_AUTH_POLL_INTERVAL=1
export HERDR_AUTH_POLL_CEILING=2
fixture aorus.cursor 'Not logged in'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _wait cursor aorus)
[ "$got" = timeout ] && ok "wait: genuinely loops (interval=1, ceiling=2) and times out" \
                     || ko "wait: genuinely loops (interval=1, ceiling=2) and times out" "got '$got'"
unset HERDR_AUTH_POLL_INTERVAL HERDR_AUTH_POLL_CEILING

# --- login wait phase skips hosts with no started flow ----------------------

# Finding 1: a host skipped as unreachable, or one that produced no login
# URL, must never enter the wait phase — it never had a flow started, so it
# must not burn a full poll ceiling. This exercises the real wait path (no
# --no-wait), unlike the earlier unreachable-host test above.
export HERDR_AUTH_POLL_INTERVAL=0
export HERDR_AUTH_POLL_CEILING=1
: > "$HERDR_AUTH_FIXTURE/aorus5.unreachable"
fixture aorus.cursorlogin 'some error, no link'
fixture aorus4.cursorlogin 'Starting login process...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_C&uuid=00000000-0000-0000-0000-00000000000c&mode=login&redirectTarget=cli'
fixture aorus4.cursor 'Logged in as joel@example.com'
: > "$HERDR_AUTH_OPENED"
out=$(HERDR_AUTH_HOSTS="aorus5 aorus aorus4" bash "$A" login --cli cursor 2>&1)
printf '%s' "$out" | grep -q 'host aorus5: still not logged in' \
  && ko "login wait: unreachable host must not enter the wait phase" "$out" \
  || ok "login wait: unreachable host must not enter the wait phase"
printf '%s' "$out" | grep -q 'host aorus: still not logged in' \
  && ko "login wait: host with no login URL must not enter the wait phase" "$out" \
  || ok "login wait: host with no login URL must not enter the wait phase"
printf '%s' "$out" | grep -q 'host aorus4: logged in' \
  && ok "login wait: the one host with a started flow is still waited on" \
  || ko "login wait: the one host with a started flow is still waited on" "$out"
unset HERDR_AUTH_POLL_INTERVAL HERDR_AUTH_POLL_CEILING

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
