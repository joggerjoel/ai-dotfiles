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
# Where the detached remote login writes its output, and where the stub records
# a cancellation. Under $TMP so a run never touches the real /tmp path.
export HERDR_AUTH_CURSOR_LOG="$TMP/cursor-login.log"
export HERDR_AUTH_CANCELLED="$TMP/cancelled"
# The verbatim remote command every cancellation sends, so the pkill pattern
# can be tested as a string rather than trusted.
export HERDR_AUTH_PKILL_CMD="$TMP/pkill-cmd"
export HERDR_AUTH_CODEX_LOG="$TMP/codex-login.log"
# An ordered journal of starts and cancels. Serialisation is a property of
# sequence, so occurrence-only assertions cannot see it.
export HERDR_AUTH_ORDER="$TMP/order"
export HERDR_AUTH_START_CMD="$TMP/start-cmd"
# How long the stub blocks in the foreground form. The elapsed-time assertion
# uses this as the line between "read the URL live" and "waited for exit".
export HERDR_AUTH_STUB_BLOCK=5
export HERDR_AUTH_URL_INTERVAL=0
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

# The real `cursor-agent login` never exits until the flow completes — it has to
# keep running to poll Cursor's servers. Reading its URL therefore must not wait
# for the process to exit. It once did (out="$(remote ...)"), which deadlocked on
# host 1 and never reached the fleet, while the suite stayed green because the
# stub modelled a command that returns. The stub now blocks like the real CLI,
# so a regression to that shape costs at least HERDR_AUTH_STUB_BLOCK seconds
# PER HOST instead of passing quietly.
: > "$HERDR_AUTH_OPENED"
start=$SECONDS
out=$(HERDR_AUTH_HOSTS="aorus aorus4" bash "$A" login --cli cursor --no-wait 2>&1)
elapsed=$((SECONDS - start))
[ "$elapsed" -lt "$HERDR_AUTH_STUB_BLOCK" ] \
  && ok "cursor login: reads the URL without waiting for the process to exit (${elapsed}s)" \
  || ko "cursor login: reads the URL without waiting for the process to exit" \
        "took ${elapsed}s — at or past the ${HERDR_AUTH_STUB_BLOCK}s block, so it waited for exit"
[ "$(grep -c . "$HERDR_AUTH_OPENED")" = 2 ] \
  && ok "cursor login: still opens both URLs under the detached model" \
  || ko "cursor login: still opens both URLs under the detached model" "opened $(grep -c . "$HERDR_AUTH_OPENED")"

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

# --- cancel_login: the kill pattern must not match its own command line -------
#
# `pkill -f` matches full command lines, and the remote shell's own argv holds
# the pattern it was handed. Verified on a live host:
#
#     $ pgrep -af "cursor-agent login"
#     931550 bash -lc pgrep -af "cursor-agent login"; ...
#
# A literal pattern therefore makes cancel signal its own shell, and the `rm -f`
# that follows may never run — stranding a file holding a live login URL on the
# host at exactly the moment the operator asked to cancel it.
#
# This is asserted as a property of the string the script sends, because the
# defect lives in the pattern, not in any behaviour a stub could imitate.
export HERDR_AUTH_POLL_INTERVAL=0
export HERDR_AUTH_POLL_CEILING=1
fixture aorus4.cursorlogin 'Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_C&uuid=00000000-0000-0000-0000-00000000000c&mode=login&redirectTarget=cli'
fixture aorus4.cursor 'Not logged in'
: > "$HERDR_AUTH_PKILL_CMD"
HERDR_AUTH_HOSTS="aorus4" bash "$A" login --cli cursor >/dev/null 2>&1
pkcmd=$(cat "$HERDR_AUTH_PKILL_CMD")

if [ -z "$pkcmd" ]; then
  ko "cancel: a timed-out login sends a kill at all" "nothing recorded"
  ko "cancel: the kill pattern must not match its own command line" "no command"
  ko "cancel: the log is removed before the kill is attempted" "no command"
else
  ok "cancel: a timed-out login sends a kill at all"

  # The pattern as the script actually wrote it, taken back out of the command.
  pkpat=${pkcmd#*pkill -f \"}
  pkpat=${pkpat%%\"*}
  printf '%s' "$pkcmd" | grep -qE "$pkpat" \
    && ko "cancel: the kill pattern must not match its own command line" "pattern '$pkpat' matches the command carrying it" \
    || ok "cancel: the kill pattern must not match its own command line"

  # The complement, and the reason the pair is meaningful: a pattern that
  # matches nothing would satisfy the assertion above while killing nothing.
  # `cursor-agent login` is the command line the real flow actually runs under.
  printf 'cursor-agent login\n' | grep -qE "$pkpat" \
    && ok "cancel: the kill pattern still matches the real login command" \
    || ko "cancel: the kill pattern still matches the real login command" "pattern '$pkpat' matches nothing"

  # Ordering is the guarantee: remove the credential first, so that even a kill
  # that goes wrong cannot leave the login URL behind.
  case "$pkcmd" in
    *"rm -f"*pkill*) ok "cancel: the log is removed before the kill is attempted" ;;
    *) ko "cancel: the log is removed before the kill is attempted" "$pkcmd" ;;
  esac
fi
unset HERDR_AUTH_POLL_INTERVAL HERDR_AUTH_POLL_CEILING

# --- codex: serial device-code flow -------------------------------------------
#
# Shaped from the real output captured on aorus8 under nohup, including the
# static URL, so the extractor is exercised against prose it will actually meet.
CODEXOUT='Welcome to Codex [v0.147.0]
Follow these steps to sign in with ChatGPT using device code authorization:
1. Open this link in your browser and sign in to your account
   https://auth.openai.com/codex/device
2. Enter this one-time code (expires in 15 minutes)
   SYNTH-CODE1
Continue only if you started this login in Codex.'

export HERDR_AUTH_POLL_INTERVAL=0
export HERDR_AUTH_POLL_CEILING=1
fixture aorus4.codexlogin "$CODEXOUT"
fixture aorus5.codexlogin "$CODEXOUT"
# An earlier cursor case marked aorus5 unreachable, and reachability is a
# fixture file rather than per-case state. Left in place it silently turns the
# serialisation assertion below into a test of one host.
rm -f "$HERDR_AUTH_FIXTURE/aorus5.unreachable"

# An already-authed host must cost one probe, not a code the operator types.
fixture aorus4.codex 'Logged in using ChatGPT'
: > "$HERDR_AUTH_ORDER"
out=$(HERDR_AUTH_HOSTS="aorus4" bash "$A" login --cli codex 2>&1)
printf '%s' "$out" | grep -q 'already logged in, skipping' \
  && ok "codex: an already-authed host is skipped" \
  || ko "codex: an already-authed host is skipped" "$out"
grep -q '^start ' "$HERDR_AUTH_ORDER" \
  && ko "codex: skipping starts no flow" "a flow was started for an authed host" \
  || ok "codex: skipping starts no flow"

# The code reaches the operator, the static URL is opened, and the flag that
# keeps the callback off the wrong localhost is the one actually used.
fixture aorus4.codex 'Not logged in'
: > "$HERDR_AUTH_ORDER"; : > "$HERDR_AUTH_START_CMD"; : > "$HERDR_AUTH_OPENED"
out=$(HERDR_AUTH_HOSTS="aorus4" HERDR_AUTH_NO_WAIT=1 bash "$A" login --cli codex 2>&1)
printf '%s' "$out" | grep -q 'enter code SYNTH-CODE1' \
  && ok "codex: the one-time code is put in front of the operator" \
  || ko "codex: the one-time code is put in front of the operator" "$out"
grep -qF 'https://auth.openai.com/codex/device' "$HERDR_AUTH_OPENED" \
  && ok "codex: the static device URL is opened" \
  || ko "codex: the static device URL is opened" "$(cat "$HERDR_AUTH_OPENED")"
grep -qF -- '--device-auth' "$HERDR_AUTH_START_CMD" \
  && ok "codex: uses --device-auth, never the localhost-callback form" \
  || ko "codex: uses --device-auth, never the localhost-callback form" "$(cat "$HERDR_AUTH_START_CMD")"

# Serialisation, asserted as sequence. A parallel implementation would emit
# start/start before either cancel, and every occurrence-only assertion above
# would still pass — which is exactly why this one reads line numbers.
fixture aorus5.codex 'Not logged in'
: > "$HERDR_AUTH_ORDER"
out=$(HERDR_AUTH_HOSTS="aorus4 aorus5" bash "$A" login --cli codex 2>&1)
s5=$(grep -n '^start aorus5$' "$HERDR_AUTH_ORDER" | head -1 | cut -d: -f1)
c4=$(grep -n '^cancel aorus4$' "$HERDR_AUTH_ORDER" | head -1 | cut -d: -f1)
if [ -n "$s5" ] && [ -n "$c4" ] && [ "$s5" -gt "$c4" ]; then
  ok "codex: host 2's flow does not start until host 1's has finished"
else
  ko "codex: host 2's flow does not start until host 1's has finished" "$(tr '\n' '/' < "$HERDR_AUTH_ORDER")"
fi

# A host that produces no code never got a flow going; say so, and clean up
# rather than leaving a started process polling on the host.
fixture aorus6.codex 'Not logged in'
fixture aorus6.codexlogin 'some error, no code here'
: > "$HERDR_AUTH_CANCELLED"
out=$(HERDR_AUTH_HOSTS="aorus6" bash "$A" login --cli codex 2>&1)
printf '%s' "$out" | grep -q 'host aorus6: no device code' \
  && ok "codex: a host that yields no code is reported, not silently skipped" \
  || ko "codex: a host that yields no code is reported, not silently skipped" "$out"
grep -q '^aorus6$' "$HERDR_AUTH_CANCELLED" \
  && ok "codex: a codeless host still gets its flow cancelled" \
  || ko "codex: a codeless host still gets its flow cancelled" "$(cat "$HERDR_AUTH_CANCELLED")"

# An unreachable host must not consume a code.
: > "$HERDR_AUTH_FIXTURE/aorus7.unreachable"
: > "$HERDR_AUTH_ORDER"
out=$(HERDR_AUTH_HOSTS="aorus7" bash "$A" login --cli codex 2>&1)
printf '%s' "$out" | grep -q 'host aorus7: unreachable' \
  && ok "codex: an unreachable host is skipped before any flow starts" \
  || ko "codex: an unreachable host is skipped before any flow starts" "$out"
grep -q '^start aorus7$' "$HERDR_AUTH_ORDER" \
  && ko "codex: no flow is started for an unreachable host" "started anyway" \
  || ok "codex: no flow is started for an unreachable host"
rm -f "$HERDR_AUTH_FIXTURE/aorus7.unreachable"
unset HERDR_AUTH_POLL_INTERVAL HERDR_AUTH_POLL_CEILING

# --- claude credential classifier ---------------------------------------------
#
# Exercised directly on stdin, with no ssh anywhere, because the defect it
# replaces was a logic error and not a transport one.
NOW_MS=$(( $(date +%s) * 1000 ))
FUTURE=$(( NOW_MS + 30 * 24 * 3600 * 1000 ))   # +30d
SOON=$((   NOW_MS +  8      * 3600 * 1000 ))   # +8h
PAST=$((   NOW_MS - 20 * 24 * 3600 * 1000 ))   # -20d

classify() { printf '%s' "$1" | HERDR_AUTH_WARN_HOURS="${2:-72}" bash "$A" _classify_creds; }

# The production defect, in one assertion. This is aorus4's real file shape: the
# supabase MCP plugin owns entries in the same store, so the file exists and
# parses while holding no Claude login at all. The old probe called this authed.
got=$(classify '{"mcpOAuth":{"plugin:supabase|abc":{"serverName":"supabase","accessToken":""}}}')
[ "$got" = missing ] \
  && ok "claude: a file with only mcpOAuth entries is not a Claude login" \
  || ko "claude: a file with only mcpOAuth entries is not a Claude login" "got '$got'"

got=$(classify "{\"claudeAiOauth\":{\"refreshToken\":\"r\",\"refreshTokenExpiresAt\":$FUTURE}}")
[ "$got" = authed ] \
  && ok "claude: a live refresh token is authed" \
  || ko "claude: a live refresh token is authed" "got '$got'"

# The semantic the fleet measurement established: the access token is reissued
# every time claude starts, so its expiry says nothing about health. Only the
# refresh token decides.
got=$(classify "{\"claudeAiOauth\":{\"refreshToken\":\"r\",\"expiresAt\":$PAST,\"refreshTokenExpiresAt\":$FUTURE}}")
[ "$got" = authed ] \
  && ok "claude: an expired ACCESS token does not make a host missing" \
  || ko "claude: an expired ACCESS token does not make a host missing" "got '$got'"

# aorus6's real shape: block present, refresh token gone.
got=$(classify "{\"claudeAiOauth\":{\"refreshTokenExpiresAt\":$FUTURE}}")
[ "$got" = missing ] \
  && ok "claude: a block with no refresh token is missing" \
  || ko "claude: a block with no refresh token is missing" "got '$got'"

got=$(classify "{\"claudeAiOauth\":{\"refreshToken\":\"r\",\"refreshTokenExpiresAt\":$PAST}}")
[ "$got" = missing ] \
  && ok "claude: a lapsed refresh token is missing, not authed" \
  || ko "claude: a lapsed refresh token is missing, not authed" "got '$got'"

got=$(classify "{\"claudeAiOauth\":{\"refreshToken\":\"r\",\"refreshTokenExpiresAt\":$SOON}}")
case "$got" in
  expiring:*) ok "claude: a refresh token inside the warning window reports expiring" ;;
  *) ko "claude: a refresh token inside the warning window reports expiring" "got '$got'" ;;
esac

# The window is a threshold, not a constant: the same file reads healthy when
# the caller cares about a shorter horizon.
got=$(classify "{\"claudeAiOauth\":{\"refreshToken\":\"r\",\"refreshTokenExpiresAt\":$SOON}}" 4)
[ "$got" = authed ] \
  && ok "claude: the warning window is honoured, not hard-coded" \
  || ko "claude: the warning window is honoured, not hard-coded" "got '$got'"

got=$(classify 'not json at all')
[ "$got" = missing ] \
  && ok "claude: an unparseable credentials file is missing, never a crash" \
  || ko "claude: an unparseable credentials file is missing, never a crash" "got '$got'"

got=$(classify '')
[ "$got" = missing ] \
  && ok "claude: an absent credentials file is missing" \
  || ko "claude: an absent credentials file is missing" "got '$got'"

# A JSON true is an int in Python unless you exclude bool explicitly.
got=$(classify '{"claudeAiOauth":{"refreshToken":"r","refreshTokenExpiresAt":true}}')
[ "$got" = missing ] \
  && ok "claude: a non-numeric expiry is missing, not a truthy timestamp" \
  || ko "claude: a non-numeric expiry is missing, not a truthy timestamp" "got '$got'"

# The classifier describes the credentials FILE. It must not be asked about a
# host running on the fleet token: there the env var authenticates and the file
# is irrelevant, so probe_claude checks the environment first and never reaches
# here. Pinning that boundary keeps someone from "helpfully" teaching the
# classifier about a variable it cannot see.
got=$(CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-FAKE classify '{"mcpOAuth":{}}')
[ "$got" = missing ] \
  && ok "claude: the classifier judges the file, not the ambient environment" \
  || ko "claude: the classifier judges the file, not the ambient environment" "got '$got'"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
