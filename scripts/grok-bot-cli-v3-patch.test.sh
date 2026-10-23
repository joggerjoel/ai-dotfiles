#!/usr/bin/env bash
# Tests for scripts/grok-bot-cli-v3-patch.sh. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a hook.
#
# The fixture is the descriptor guard as shipped in grok-bot-cli 0.12.4.

HERE=$(cd "$(dirname "$0")" && pwd)
SUT="$HERE/grok-bot-cli-v3-patch.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gbotpatch.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ (${2})}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing: $3" ;; esac; }

mkdir -p "$TMP/pkg/dist/bin" "$TMP/pkg/dist/mcp"
cat > "$TMP/pkg/dist/bin/gbot.mjs" <<'JS'
            if (wrapped.version != null && wrapped.version !== 1 && wrapped.version !== 2) {
                throw new GrokBotGatewaySessionError("UNSUPPORTED_VERSION", `Unsupported Grok Bot gateway descriptor version ${wrapped.version}.`);
            }
            if (wrapped.version === 2) {
JS
cp "$TMP/pkg/dist/bin/gbot.mjs" "$TMP/pkg/dist/mcp/server.mjs"
echo 'const other = 1;' > "$TMP/pkg/dist/bin/unrelated.mjs"

out="$(bash "$SUT" "$TMP/pkg")"
body="$(cat "$TMP/pkg/dist/bin/gbot.mjs")"
has "guard accepts v3" "$body" "wrapped.version !== 2 && wrapped.version !== 3)"
has "entries branch covers v3" "$body" "if ((wrapped.version === 2 || wrapped.version === 3)) {"
has "patches every bundle" "$(cat "$TMP/pkg/dist/mcp/server.mjs")" "wrapped.version !== 3)"
has "reports what it patched" "$out" "patched 2 bundle(s)"
eq "leaves unrelated files alone" "const other = 1;" "$(cat "$TMP/pkg/dist/bin/unrelated.mjs")"

out="$(bash "$SUT" "$TMP/pkg")"
eq "second run is silent" "" "$out"
eq "second run changes nothing" "$body" "$(cat "$TMP/pkg/dist/bin/gbot.mjs")"

out="$(bash "$SUT" "$TMP/missing")"; rc=$?
eq "missing package exits 0" "0" "$rc"
eq "missing package is silent" "" "$out"

echo "grok-bot-cli-v3-patch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
