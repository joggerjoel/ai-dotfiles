#!/usr/bin/env bash
# Tests for herdr-inbox-notice.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# The hook is driven against a fake herdr-master that records every argument it was
# given, so "never acknowledges" can be proven from what was asked rather than from
# what happened to come back.

HERE=$(cd "$(dirname "$0")" && pwd)
G="$HERE/herdr-inbox-notice.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdrinbox-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

REPO=$TMP/repo
DEEP=$REPO/packages/api/src
mkdir -p "$DEEP" "$REPO/.git"
RESOLVED_REPO=$(cd "$REPO" && pwd -P)
CALLS=$TMP/calls
MAILBOX=$TMP/mail
EXIT_FILE=$TMP/exit

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

# Answers in the real command's shape: a JSON object whose messages each carry a
# `read` flag, which is what herdr_master/inbox.py returns.
cat > "$TMP/herdr-master" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
code=$(cat "$EXIT_FILE" 2>/dev/null || echo 0)
[ "$code" = 0 ] || exit "$code"
cat "$MAILBOX" 2>/dev/null
FAKE
chmod +x "$TMP/herdr-master"
export CALLS MAILBOX EXIT_FILE
export HERDR_MASTER_BIN="$TMP/herdr-master"

mail() { # subject... → one unread message each
  jq -cn --args '{messages: [$ARGS.positional[] | {
    kind: "message", id: "m", repo: "/repo", to: "all", from: "supervisor",
    subject: ., body: "", at: "2026-09-15T12:00:00+00:00", read: false}],
    skipped: 0, total: ($ARGS.positional | length)}' "$@" > "$MAILBOX"
}
read_mail() { # subject... → messages already acknowledged
  jq -cn --args '{messages: [$ARGS.positional[] | {
    kind: "message", id: "m", repo: "/repo", to: "all", from: "supervisor",
    subject: ., body: "", at: "2026-09-15T12:00:00+00:00", read: true}],
    skipped: 0, total: ($ARGS.positional | length)}' "$@" > "$MAILBOX"
}
no_mail() { jq -cn '{messages: [], skipped: 0, total: 0}' > "$MAILBOX"; }
exits() { printf '%s' "$1" > "$EXIT_FILE"; }
reset() { : > "$CALLS"; exits 0; }

payload() { # event [cwd]
  jq -cn --arg e "$1" --arg c "${2:-$REPO}" \
    '{hook_event_name:$e, session_id:"sess-1", transcript_path:"/t.jsonl", cwd:$c}'
}

run() { # event [cwd] → sets OUT, RC
  OUT=$(printf '%s' "$(payload "$1" "${2:-}")" | "$G" 2>/dev/null)
  RC=$?
}

echo "── mail present is announced ──────────────────────────"
reset
mail "from supervisor: rebase before you push" "from cursor-worker: I hold src/app.py"
run SessionStart
if [ "$RC" = 0 ] \
  && case "$OUT" in *"rebase before you push"*"I hold src/app.py"*) true ;; *) false ;; esac; then
  ok "unread mail reaches the starting agent's context"
else ko "mail is printed" "rc=$RC out=$OUT"; fi

case "$OUT" in *"2 unread message"*) ok "the count leads the notice" ;;
  *) ko "message count" "got: $OUT" ;; esac

echo "── silence when there is nothing to say ───────────────"
reset
no_mail
run SessionStart
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "no mail prints nothing at all"
else ko "empty inbox must be silent" "rc=$RC out=$OUT"; fi

reset
read_mail "already seen once" "and again"
run SessionStart
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then
  ok "mail already acknowledged is never announced again"
else ko "read mail must stay quiet" "rc=$RC out=$OUT"; fi

reset
mail "from supervisor: something"
for event in Stop SubagentStop SessionEnd UserPromptSubmit; do
  run "$event"
  if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$CALLS" ]; then
    ok "$event neither speaks nor asks"
  else ko "$event must do nothing" "rc=$RC out=$OUT"; fi
  reset
done

echo "── the repository is found from any depth ─────────────"
reset
mail "from supervisor: nested"
run SessionStart "$DEEP"
if [ "$RC" = 0 ] && case "$OUT" in *nested*) true ;; *) false ;; esac \
  && grep -q -- "--repo $RESOLVED_REPO " "$CALLS"; then
  ok "a session deep inside the tree resolves the repository root"
else ko "repository resolution" "rc=$RC calls=$(cat "$CALLS")"; fi

reset
mail "from supervisor: unreachable"
run SessionStart "$TMP"
if [ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -s "$CALLS" ]; then
  ok "a directory outside any repository asks nothing"
else ko "no repository means no question" "rc=$RC out=$OUT"; fi

echo "── fail open and silent ───────────────────────────────"
reset
mail "from supervisor: hello"
OUT=$(printf '%s' "$(payload SessionStart)" | HERDR_MASTER_BIN="$TMP/absent" "$G" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "a missing herdr-master exits 0 silently"
else ko "missing binary" "rc=$RC out=$OUT"; fi

reset
mail "from supervisor: hello"
exits 3
run SessionStart
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "a nonzero exit prints nothing"
else ko "nonzero exit must be silent" "rc=$RC out=$OUT"; fi

reset
OUT=$(printf '%s' '{not json at all' | "$G" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "malformed input exits 0 silently"
else ko "malformed input" "rc=$RC out=$OUT"; fi

reset
OUT=$(printf '%s' "" | "$G" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "empty stdin exits 0 silently"
else ko "empty stdin" "rc=$RC out=$OUT"; fi

reset
mail "from supervisor: hello"
NOJQ=$TMP/nojq
mkdir -p "$NOJQ"
for tool in bash cat dirname grep head cut printf; do
  target=$(command -v "$tool") && ln -sf "$target" "$NOJQ/$tool"
done
OUT=$(printf '%s' "$(payload SessionStart)" | PATH="$NOJQ" "$G" 2>/dev/null)
RC=$?
if [ "$RC" = 0 ] && [ -z "$OUT" ]; then ok "a missing jq exits 0 silently"
else ko "missing jq" "rc=$RC out=$OUT"; fi

echo "── the backlog is capped, never dumped ────────────────"
reset
mail "one" "two" "three" "four" "five" "six" "seven" "eight"
OUT=$(printf '%s' "$(payload SessionStart)" | HERDR_INBOX_MAX=3 "$G" 2>/dev/null)
RC=$?
SHOWN=$(printf '%s\n' "$OUT" | grep -cE ': (one|two|three|four|five|six|seven|eight)$')
if [ "$RC" = 0 ] && [ "$SHOWN" = 3 ]; then ok "only the first few messages are shown"
else ko "output cap" "shown=$SHOWN out=$OUT"; fi
case "$OUT" in *"5 more"*"herdr-master inbox"*)
  ok "the rest are named, with the command to read them" ;;
  *) ko "pointer to the full inbox" "got: $OUT" ;; esac

reset
LONG=$(printf 'x%.0s' $(seq 1 500))
mail "$LONG"
run SessionStart
LONGEST=$(printf '%s\n' "$OUT" | awk '{ if (length($0) > m) m = length($0) } END { print m }')
if [ "$RC" = 0 ] && [ "$LONGEST" -le 200 ]; then ok "a very long message is truncated"
else ko "line truncation" "longest=$LONGEST"; fi

echo "── reading is not acting ──────────────────────────────"
reset
mail "from supervisor: still unread" "from cursor-worker: also unread"
run SessionStart
FIRST=$OUT
run SessionStart
if [ "$FIRST" = "$OUT" ] && [ -n "$FIRST" ]; then
  ok "reading twice shows the same mail; nothing was consumed"
else ko "mail must survive being read" "first=$FIRST second=$OUT"; fi

if ! grep -Eq -- '(--ack|--acknowledge|--mark|--read|--consume)' "$CALLS"; then
  ok "no invocation ever asked to acknowledge anything"
else ko "the hook asked to mark mail read" "$(cat "$CALLS")"; fi

if [ "$(sort -u "$CALLS" | wc -l | tr -d ' ')" = 1 ] \
  && grep -q -- "inbox --repo $RESOLVED_REPO --all --json" "$CALLS"; then
  ok "every call is the same read-only inbox query"
else ko "unexpected invocation" "$(cat "$CALLS")"; fi

echo "───────────────────────────────────────────────────────"
echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
