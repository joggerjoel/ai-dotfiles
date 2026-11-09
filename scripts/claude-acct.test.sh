#!/usr/bin/env bash
# Tests for bin/claude-acct. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Offline. `claude` is a stub on PATH that decides what to do from the token it
# was handed, so each case states which account is in what condition. Every
# token below is an obvious fake.

HERE=$(cd "$(dirname "$0")" && pwd)
CA="$HERE/../bin/claude-acct"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/claude-acct-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }
check() { # <name> <condition>
  if eval "$2"; then ok "$1"; else ko "$1" "condition false: $2"; fi
}

FAKE="$TMP/fakebin"; STATE="$TMP/state"; BEH="$TMP/behavior"
mkdir -p "$FAKE" "$STATE" "$BEH"

TOK_A='sk-ant-oat01-FAKE-alpha-rTrT-0001'
TOK_B='sk-ant-oat01-FAKE-bravo-rTrT-0002'

# Behavior is looked up by the token the child received: $BEH/<token> holds
# "<exit code>|<stdout>|<stderr>". No file means "answer ok".
cat > "$FAKE/claude" <<'EOF'
#!/usr/bin/env bash
KEY=${CLAUDE_CODE_OAUTH_TOKEN:-login:${CLAUDE_CONFIG_DIR:-default}}
printf '%s\n' "$KEY" >> "$FAKE_BEH/calls"
printf '%s\n' "$*" >> "$FAKE_BEH/argv"
cat > "$FAKE_BEH/stdin.${KEY//\//_}"
env | grep -c '^CLAUDE_CODE_OAUTH_TOKEN_' > "$FAKE_BEH/other-tokens"
f="$FAKE_BEH/${KEY//\//_}"
if [ -f "$f" ]; then
  IFS='|' read -r rc out err < "$f"
  printf '%s\n' "$out"
  printf '%s\n' "$err" >&2
  exit "$rc"
fi
echo "ok from claude"
exit 0
EOF
chmod +x "$FAKE/claude"

NOW=1794225600   # 2026-11-09 12:00:00 UTC

reset_world() {
  rm -rf "$STATE" "$BEH"; mkdir -p "$STATE" "$BEH"
}

# Run claude-acct with both accounts configured. Output lands in $OUT/$ERR.
run() {
  OUT="$TMP/out" ERR="$TMP/err"
  env -i HOME="$TMP/home" PATH="$FAKE:/usr/bin:/bin" TMPDIR="$TMP" \
    FAKE_BEH="$BEH" CLAUDE_ACCT_STATE="$STATE" CLAUDE_ACCT_NOW="$NOW" \
    CLAUDE_FLEET_ENV="$TMP/no-such-env" \
    CLAUDE_ACCOUNTS="alpha bravo" \
    CLAUDE_CODE_OAUTH_TOKEN_ALPHA="$TOK_A" CLAUDE_CODE_OAUTH_TOKEN_BRAVO="$TOK_B" \
    bash "$CA" "$@" > "$OUT" 2> "$ERR" < "${STDIN:-/dev/null}"
  # shellcheck disable=SC2034
  RC=$?
}

calls() { tr '\n' ' ' < "$BEH/calls" 2>/dev/null; }

LIMIT="You've hit your limit · resets 3pm (UTC)"

# --- pick the first account ---------------------------------------------------
reset_world
run -p hello
check "picks the first account" '[ "$(calls)" = "$TOK_A " ]'
check "success passes stdout through" 'grep -qx "ok from claude" "$OUT"'
check "arguments reach claude unchanged" 'grep -qx -- "-p hello" "$BEH/argv"'
check "success exits 0" '[ $RC -eq 0 ]'
check "only the chosen account token is in the child environment" '[ "$(cat "$BEH/other-tokens")" = 0 ]'

# --- a login account (no token, a config dir) ---------------------------------
login_run() { # <dir for bravo> args...
  local dir=$1; shift
  OUT="$TMP/out" ERR="$TMP/err"
  env -i HOME="$TMP/home" PATH="$FAKE:/usr/bin:/bin" TMPDIR="$TMP" \
    FAKE_BEH="$BEH" CLAUDE_ACCT_STATE="$STATE" CLAUDE_ACCT_NOW="$NOW" \
    CLAUDE_FLEET_ENV="$TMP/no-such-env" CLAUDE_ACCOUNTS="alpha bravo" \
    CLAUDE_CODE_OAUTH_TOKEN_ALPHA="$TOK_A" CLAUDE_CONFIG_DIR_BRAVO="$dir" \
    bash "$CA" "$@" > "$OUT" 2> "$ERR" < /dev/null
  # shellcheck disable=SC2034
  RC=$?
}
reset_world
printf '1|%s|\n' "$LIMIT" > "$BEH/$TOK_A"
login_run "$TMP/home/.claude" -p hello
check "a limited token account fails over to a login account" '[ "$(calls)" = "$TOK_A login:default " ] && [ $RC -eq 0 ]'
check "the default login dir is left implicit" 'grep -qx "login:default" "$BEH/calls"'
reset_world
printf '1|%s|\n' "$LIMIT" > "$BEH/$TOK_A"
login_run "$TMP/accts/bravo/" -p hello
check "a non-default login dir is passed as CLAUDE_CONFIG_DIR" 'grep -qx "login:$TMP/accts/bravo" "$BEH/calls"'
reset_world
printf '1||%s\n' "$LIMIT" > "$BEH/login:default"
printf '%s limit\n' $((NOW + 600)) > "$STATE/alpha"
login_run "$TMP/home/.claude" -p hello
check "a limited login account is marked exhausted" '[ -f "$STATE/bravo" ]'

# --- host-local env adds a login account and sets the order -------------------
reset_world
mkdir -p "$TMP/home/.config/claude-acct"
printf 'CLAUDE_ACCOUNTS="bravo alpha"\nCLAUDE_CONFIG_DIR_BRAVO="$HOME/.claude"\n' > "$TMP/home/.config/claude-acct/env"
OUT="$TMP/out" ERR="$TMP/err"
env -i HOME="$TMP/home" PATH="$FAKE:/usr/bin:/bin" TMPDIR="$TMP" \
  FAKE_BEH="$BEH" CLAUDE_ACCT_STATE="$STATE" CLAUDE_ACCT_NOW="$NOW" \
  CLAUDE_FLEET_ENV="$TMP/no-such-env" CLAUDE_CODE_OAUTH_TOKEN_ALPHA="$TOK_A" \
  bash "$CA" -p hello > "$OUT" 2> "$ERR" < /dev/null
check "the host env's order and login account are used" '[ "$(calls)" = "login:default " ]'
rm -rf "$TMP/home/.config/claude-acct"

# --- skip an exhausted account ------------------------------------------------
reset_world
printf '%s limit\n' $((NOW + 600)) > "$STATE/alpha"
run -p hello
check "skips an account marked exhausted" '[ "$(calls)" = "$TOK_B " ]'

# --- exhaust, then retry on the next ------------------------------------------
reset_world
printf '1|%s|\n' "$LIMIT" > "$BEH/$TOK_A"
run -p hello
check "limit on the first account retries on the second" '[ "$(calls)" = "$TOK_A $TOK_B " ]'
check "the retry result is what the caller sees" 'grep -qx "ok from claude" "$OUT" && [ $RC -eq 0 ]'
check "the discarded attempt is not in the output" '! grep -q "hit your limit" "$OUT" "$ERR"'
check "the exhausted account is marked until the parsed reset" '[ "$(cut -d" " -f1 "$STATE/alpha")" = $((NOW + 3 * 3600 + 60)) ]'
run -p again
check "the next run goes straight to the other account" '[ "$(calls)" = "$TOK_A $TOK_B $TOK_B " ]'

# --- limit text arrives on stderr, in the older wording -----------------------
reset_world
printf '1||5-hour limit reached ∙ resets 3pm\n' > "$BEH/$TOK_A"
run -p hello
check "5-hour wording on stderr is recognised" '[ "$(calls)" = "$TOK_A $TOK_B " ]'

reset_world
printf '1||Claude AI usage limit reached|%s\n' $((NOW + 7200)) > "$BEH/$TOK_A"
run -p hello
check "legacy epoch wording is recognised and its time used" \
  '[ "$(cut -d" " -f1 "$STATE/alpha")" = $((NOW + 7260)) ]'

# --- unparseable reset falls back to one hour ---------------------------------
reset_world
printf '1|You have hit your limit. Try later.|\n' > "$BEH/$TOK_A"
run -p hello
check "an unrecognised phrasing does not trigger a switch" '[ "$(calls)" = "$TOK_A " ]'
reset_world
printf "1|You've hit your limit|\n" > "$BEH/$TOK_A"
run -p hello
check "a limit with no reset time cools down for an hour" \
  '[ "$(cut -d" " -f1 "$STATE/alpha")" = $((NOW + 3600)) ]'

# --- all exhausted: the original error ---------------------------------------
reset_world
printf '1|%s|\n' "$LIMIT" > "$BEH/$TOK_A"
printf '1|%s|\n' "You've hit your limit · resets 5pm (UTC)" > "$BEH/$TOK_B"
run -p hello
check "both exhausted tries both" '[ "$(calls)" = "$TOK_A $TOK_B " ]'
check "all exhausted exits with the first failure's code" '[ $RC -eq 1 ]'
check "all exhausted reports the first failure's text" 'grep -q "resets 3pm" "$OUT" && ! grep -q "resets 5pm" "$OUT"'
run -p hello
check "with everyone marked, the one freeing first is still tried" '[ "$(calls | awk "{print \$NF}")" = "$TOK_A" ]'

# --- exit codes and output of a non-limit failure pass through ----------------
reset_world
printf '7|partial output|some warning\n' > "$BEH/$TOK_A"
run -p hello
check "an ordinary failure is not retried" '[ "$(calls)" = "$TOK_A " ]'
check "an ordinary failure keeps its exit code" '[ $RC -eq 7 ]'
check "an ordinary failure keeps stdout and stderr" 'grep -qx "partial output" "$OUT" && grep -qx "some warning" "$ERR"'

reset_world
printf '0|the limit text appears: You'"'"'ve hit your limit|\n' > "$BEH/$TOK_A"
run -p hello
check "limit wording in a successful run is ignored" '[ "$(calls)" = "$TOK_A " ] && [ $RC -eq 0 ]'

# --- revoked token -----------------------------------------------------------
reset_world
printf '1||API Error: 401 OAuth access token is invalid\n' > "$BEH/$TOK_A"
run -p hello
check "an auth failure moves to the next account" '[ "$(calls)" = "$TOK_A $TOK_B " ] && [ $RC -eq 0 ]'
check "an auth failure is reported on stderr" 'grep -q "alpha failed to authenticate" "$ERR"'
check "stderr names the account but never the token" '! grep -q "$TOK_A" "$ERR" "$OUT"'

# --- reset expiry ------------------------------------------------------------
reset_world
printf '%s limit\n' $((NOW - 1)) > "$STATE/alpha"
run -p hello
check "a marker whose reset time has passed is ignored" '[ "$(calls)" = "$TOK_A " ]'
check "a success clears the stale marker" '[ ! -e "$STATE/alpha" ]'

# --- stdin reaches the retry too ---------------------------------------------
reset_world
printf '1|%s|\n' "$LIMIT" > "$BEH/$TOK_A"
printf 'the prompt\n' > "$TMP/stdin.txt"
STDIN="$TMP/stdin.txt" run -p
unset STDIN
check "stdin is replayed to the retry" 'grep -qx "the prompt" "$BEH/stdin.$TOK_B"'

# --- no accounts configured: plain claude ------------------------------------
reset_world
env -i HOME="$TMP/home" PATH="$FAKE:/usr/bin:/bin" TMPDIR="$TMP" FAKE_BEH="$BEH" \
  CLAUDE_FLEET_ENV="$TMP/no-such-env" CLAUDE_CODE_OAUTH_TOKEN="$TOK_A" \
  bash "$CA" -p hi > "$TMP/out" 2> "$TMP/err" < /dev/null
check "without CLAUDE_ACCOUNTS it is plain claude on the primary token" '[ "$(calls)" = "$TOK_A " ]'

# --- the fleet env file is read when the variables are absent -----------------
reset_world
cat > "$TMP/fleet-env" <<EOF
export CLAUDE_CODE_OAUTH_TOKEN_ALPHA=$TOK_A
export CLAUDE_CODE_OAUTH_TOKEN_BRAVO=$TOK_B
export CLAUDE_ACCOUNTS='alpha bravo'
EOF
printf '1|%s|\n' "$LIMIT" > "$BEH/$TOK_A"
env -i HOME="$TMP/home" PATH="$FAKE:/usr/bin:/bin" TMPDIR="$TMP" FAKE_BEH="$BEH" \
  CLAUDE_ACCT_STATE="$STATE" CLAUDE_ACCT_NOW="$NOW" CLAUDE_FLEET_ENV="$TMP/fleet-env" \
  bash "$CA" -p hi > "$TMP/out" 2> "$TMP/err" < /dev/null
check "accounts are loaded from the fleet env file (the cron case)" '[ "$(calls)" = "$TOK_A $TOK_B " ]'

# --- no token anywhere in what claude-acct prints ----------------------------
reset_world
printf '1|%s|\n' "$LIMIT" > "$BEH/$TOK_A"
run -p hello
# shellcheck disable=SC2034
status=$(env -i HOME="$TMP/home" PATH="$FAKE:/usr/bin:/bin" CLAUDE_ACCT_STATE="$STATE" CLAUDE_ACCT_NOW="$NOW" \
  CLAUDE_FLEET_ENV="$TMP/no-such-env" CLAUDE_ACCOUNTS="alpha bravo" \
  CLAUDE_CODE_OAUTH_TOKEN_ALPHA="$TOK_A" CLAUDE_CODE_OAUTH_TOKEN_BRAVO="$TOK_B" \
  bash "$CA" --acct-status 2>&1)
check "--acct-status shows the exhausted account" 'printf "%s" "$status" | grep -q "^alpha.*unavailable"'
check "no token in the run output, status output, or state files" \
  '! grep -rqF -e "$TOK_A" -e "$TOK_B" "$OUT" "$ERR" "$STATE" && ! printf "%s" "$status" | grep -qF -e "$TOK_A" -e "$TOK_B"'

# --- reset parsing, pinned to NOW = 2026-11-09 12:00 UTC ----------------------
parse() { env -i HOME="$TMP/home" PATH=/usr/bin:/bin CLAUDE_ACCT_NOW="$NOW" bash "$CA" _parse_reset "$1"; }
if [ -e /usr/share/zoneinfo/Europe/Oslo ] || [ -e /var/db/timezone/zoneinfo/Europe/Oslo ]; then
  # 13:00 in Oslo (UTC+1), so 1am is the next day: 2026-11-10 00:00 UTC.
  check "time with zone, rolling to tomorrow" '[ "$(parse "You'"'"'ve hit your limit · resets 1am (Europe/Oslo)")" = $((NOW + 12 * 3600 + 60)) ]'
  # Toronto is UTC-5, so now is 07:00 and 3pm is today at 20:00 UTC.
  check "time with zone, later today" '[ "$(parse "resets 3pm (America/Toronto)")" = $((NOW + 8 * 3600 + 60)) ]'
  check "minutes are honoured" '[ "$(parse "resets 8:30pm (UTC)")" = $((NOW + 8 * 3600 + 30 * 60 + 60)) ]'
  check "date with time" '[ "$(parse "Weekly limit reached ∙ resets Nov 14, 10am (UTC)")" = $((NOW + 5 * 86400 - 2 * 3600 + 60)) ]'
  check "12am is midnight, 12pm is noon" \
    '[ "$(parse "resets 12am (UTC)")" = $((NOW + 12 * 3600 + 60)) ] && [ "$(parse "resets 12pm (UTC)")" = $((NOW + 86400 + 60)) ]'
else
  printf '  SKIP  zone-dependent parse tests (no zoneinfo)\n'
fi
check "an unknown zone is not guessed" '[ -z "$(parse "resets 3pm (Mars/Olympus)")" ]'
check "no reset time in the text yields nothing" '[ -z "$(parse "You'"'"'ve hit your limit")" ]'
check "a date beyond the weekly window is a misparse" '[ -z "$(parse "resets Aug 1, 10am (UTC)")" ]'

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
