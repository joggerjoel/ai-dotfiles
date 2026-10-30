#!/usr/bin/env bash
# Tests for herdr-sign.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# No real keychain or codesign. Stubs on PATH stand in for uname, codesign,
# security, openssl and launchctl and record every call; a file signed by the
# codesign stub carries a marker line the `-dv` stub reads back. Each case pins
# one outcome: not macOS, no herdr, already signed, signed, identity created,
# signing failed, and --restart.

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/herdr-sign.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdr-sign-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/uname" <<'STUB'
#!/bin/bash
cat "$STUB_DIR/os"
STUB
cat > "$TMP/bin/codesign" <<'STUB'
#!/bin/bash
echo "codesign $*" >> "$STUB_DIR/calls"
file="${!#}"
case "$1" in
  -dv)
    if grep -q '^SIGNED-herdr-local$' "$file" 2>/dev/null; then
      printf 'Identifier=dev.herdr.herdr\nAuthority=herdr-local\n' >&2
    else
      printf 'Identifier=herdr-f885a9882c5a59ec\nSignature=adhoc\n' >&2
    fi ;;
  -f)
    [ -f "$STUB_DIR/sign.fails" ] && exit 1
    echo 'SIGNED-herdr-local' >> "$file" ;;
esac
STUB
cat > "$TMP/bin/security" <<'STUB'
#!/bin/bash
echo "security $*" >> "$STUB_DIR/calls"
case "$1" in
  find-identity) [ -f "$STUB_DIR/has.identity" ] \
    && echo '  1) 9C6E "herdr-local" (CSSMERR_TP_NOT_TRUSTED)' ;;
  import) touch "$STUB_DIR/has.identity" ;;
  show-keychain-info) [ -f "$STUB_DIR/locked" ] && exit 1 ;;
esac
exit 0
STUB
cat > "$TMP/bin/launchctl" <<'STUB'
#!/bin/bash
echo "launchctl $*" >> "$STUB_DIR/calls"
STUB
chmod +x "$TMP/bin/"*

reset_stub() { # <os> → fresh unsigned herdr, identity present
  rm -rf "$TMP/stub"; mkdir -p "$TMP/stub"
  printf '%s\n' "$1" > "$TMP/stub/os"
  printf '#!/bin/sh\necho herdr\n' > "$TMP/stub/herdr"
  touch "$TMP/stub/has.identity" "$TMP/stub/calls"
}

# /usr/bin/openssl is called by absolute path, so the identity case runs the
# real one; it only writes into the script's own temp dir.
run() { # [args] → sets OUT and RC
  OUT=$(STUB_DIR="$TMP/stub" HERDR_BIN="$TMP/stub/herdr" \
    PATH="$TMP/bin:/usr/bin:/bin" bash "$S" "$@" 2>&1)
  RC=$?
}

called() { grep -qF -- "$1" "$TMP/stub/calls"; }

echo "herdr-sign.sh"

reset_stub Linux; run
[ "$RC" -eq 0 ] && [[ "$OUT" == *"not macOS"* ]] && ! called codesign \
  && ok "non-macOS host is a skip" || ko "non-macOS host is a skip" "rc=$RC out=$OUT"

reset_stub Darwin; rm "$TMP/stub/herdr"; run
[ "$RC" -eq 0 ] && [[ "$OUT" == *"herdr not installed"* ]] \
  && ok "missing herdr is a skip" || ko "missing herdr is a skip" "rc=$RC out=$OUT"

reset_stub Darwin; echo 'SIGNED-herdr-local' >> "$TMP/stub/herdr"; run
[ "$RC" -eq 0 ] && [[ "$OUT" == *"already signed"* ]] && ! called "codesign -f" \
  && ok "signed binary is left alone" || ko "signed binary is left alone" "rc=$RC out=$OUT"

reset_stub Darwin; run
[ "$RC" -eq 0 ] && called "codesign -f -s herdr-local --identifier dev.herdr.herdr" \
  && grep -q '^SIGNED-herdr-local$' "$TMP/stub/herdr" && [ ! -e "$TMP/stub/herdr.new" ] \
  && [[ "$OUT" == *"--restart"* ]] && ! called launchctl \
  && ok "ad-hoc binary is signed in place, restart only suggested" \
  || ko "ad-hoc binary is signed in place, restart only suggested" "rc=$RC out=$OUT"

reset_stub Darwin; rm "$TMP/stub/has.identity"; run
[ "$RC" -eq 0 ] && called "security import" && [[ "$OUT" == *"created code-signing identity"* ]] \
  && grep -q '^SIGNED-herdr-local$' "$TMP/stub/herdr" \
  && ok "missing identity is created first" || ko "missing identity is created first" "rc=$RC out=$OUT"

reset_stub Darwin; touch "$TMP/stub/sign.fails"; before=$(cat "$TMP/stub/herdr"); run
[ "$RC" -eq 1 ] && [ "$(cat "$TMP/stub/herdr")" = "$before" ] && [ ! -e "$TMP/stub/herdr.new" ] \
  && ok "failed signing leaves the binary untouched" \
  || ko "failed signing leaves the binary untouched" "rc=$RC out=$OUT"

reset_stub Darwin; touch "$TMP/stub/locked"; before=$(cat "$TMP/stub/herdr"); run </dev/null
[ "$RC" -eq 1 ] && [[ "$OUT" == *"unlock-keychain"* ]] && ! called "codesign -f" \
  && [ "$(cat "$TMP/stub/herdr")" = "$before" ] \
  && ok "locked keychain without a tty fails before signing" \
  || ko "locked keychain without a tty fails before signing" "rc=$RC out=$OUT"

reset_stub Darwin; run --restart
[ "$RC" -eq 0 ] && called "launchctl kickstart -k gui/$(id -u)/dev.herdr.node" \
  && ok "--restart kickstarts the server" || ko "--restart kickstarts the server" "rc=$RC out=$OUT"

reset_stub Darwin; run --bogus
[ "$RC" -eq 1 ] && ! called codesign \
  && ok "unknown flag is rejected" || ko "unknown flag is rejected" "rc=$RC out=$OUT"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
