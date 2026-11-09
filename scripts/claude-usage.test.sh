#!/usr/bin/env bash
# Tests for bin/claude-usage. Dotted stem on purpose: run-all-tests.sh globs
# scripts/*.test.sh, and nothing links a dotted file as a live script.
#
# Hermetic: a fake usage endpoint on 127.0.0.1, a fake `security` and `claude`
# first on PATH, a scratch HOME. No real login, no network, no token. The
# tokens below are obviously fake, and one case asserts they never reach
# stdout or stderr.

HERE=$(cd "$(dirname "$0")" && pwd)
CU="$HERE/../bin/claude-usage"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/claudeusage-test.XXXXXX") || exit 1
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

TMP=$(cd "$TMP" && pwd -P)   # TMPDIR may end in a slash; the tool hashes the normalised path
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/kc"
TOKEN='sk-ant-oat01-FAKE-Rr7tTx_yZ-qQwErTy0123456789'
OTHER_TOKEN='sk-ant-oat01-SETUP-TOKEN-must-be-ignored'
FUTURE=$(( ($(date +%s) + 7200) * 1000 ))
PAST=$(( ($(date +%s) - 7200) * 1000 ))

cat > "$TMP/server.py" <<'PY'
import http.server, os, sys
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(os.path.join(d, "requests"), "a") as f:
            f.write("%s|%s|%s\n" % (self.path, self.headers.get("Authorization"), self.headers.get("anthropic-beta")))
        with open(os.path.join(d, "status")) as f: code = int(f.read())
        with open(os.path.join(d, "body"), "rb") as f: body = f.read()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port"), "w") as f: f.write(str(s.server_port))
s.serve_forever()
PY
python3 "$TMP/server.py" "$TMP" &
SERVER_PID=$!
for _ in $(seq 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
[ -s "$TMP/port" ] || { echo "fake server did not start"; exit 1; }
URL="http://127.0.0.1:$(cat "$TMP/port")/api/oauth/usage"

# Fake `security`: logs the service it was asked for, answers from $TMP/kc/<service>.
cat > "$TMP/bin/security" <<'SH'
#!/bin/sh
svc=""
while [ $# -gt 0 ]; do [ "$1" = "-s" ] && svc="$2"; shift; done
printf '%s\n' "$svc" >> "$FAKE_DIR/security.log"
[ -f "$FAKE_DIR/kc/$svc" ] && { cat "$FAKE_DIR/kc/$svc"; exit 0; }
exit 44
SH
cat > "$TMP/bin/claude" <<'SH'
#!/bin/sh
printf '{"loggedIn":true,"email":"fake@example.com","subscriptionType":"max"}\n'
SH
chmod +x "$TMP/bin/security" "$TMP/bin/claude"

# login <dir> <expiresAt> <scopes json>: a config dir holding a file login.
login() {
  mkdir -p "$1"
  printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"RT-FAKE","expiresAt":%s,"scopes":%s,"subscriptionType":"max"}}' \
    "$TOKEN" "$2" "$3" > "$1/.credentials.json"
}
SCOPES='["user:inference","user:profile"]'

serve() { printf '%s' "$1" > "$TMP/status"; printf '%s' "$2" > "$TMP/body"; : > "$TMP/requests"; }

# run <args...>: sets OUT, ERR, RC.
run() {
  OUT=$(env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin" FAKE_DIR="$TMP" \
        CLAUDE_USAGE_URL="${CU_URL:-$URL}" CLAUDE_CODE_OAUTH_TOKEN="$OTHER_TOKEN" \
        python3 "$CU" "$@" 2>"$TMP/err")
  RC=$?
  ERR=$(cat "$TMP/err")
  printf '%s\n%s\n' "$OUT" "$ERR" >> "$TMP/everything"
}

expect() { # <name> <want rc>
  [ "$RC" = "$2" ] && ok "$1" || ko "$1" "exit $RC, want $2 (stderr: $ERR)"
}
contains() { # <name> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "no '$3' in: $2" ;; esac
}
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" <<< "$OUT"; }

# Real replies carry dozens of codename keys, most null.
USABLE='{"five_hour":{"utilization":1.0,"resets_at":"2026-11-09T20:00:00+00:00"},"seven_day":{"utilization":66.0,"resets_at":"2026-11-14T16:00:00+00:00"},
 "amber_cistern":null,"tangelo":{"x":[1,2]},"spend":{"percent":0},"weekly_scoped_shares":[{"limit_index":1}],"brand_new_key":"?",
 "limits":[{"kind":"session","group":"session","percent":1,"severity":"normal","resets_at":"2026-11-09T20:00:00.5+00:00","scope":null,"is_active":true,"future":1},
           {"kind":"weekly_all","group":"weekly","percent":66,"severity":"normal","resets_at":"2026-11-14T16:00:00+00:00","scope":null,"is_active":true},
           "junk",{"kind":"weekly_scoped","percent":"high"},{"percent":null}]}'
LIMITED='{"limits":[{"kind":"session","group":"session","percent":100,"severity":"critical","resets_at":"2026-11-09T20:00:00Z","scope":null,"is_active":true},
 {"kind":"weekly_all","group":"weekly","percent":100,"severity":"critical","resets_at":"2026-11-09T23:59:59Z","scope":null,"is_active":true},
 {"kind":"weekly_scoped","group":"weekly","percent":39,"severity":"normal","resets_at":"2026-11-10T00:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":false}]}'

D="$TMP/cfg"
login "$D" "$FUTURE" "$SCOPES"

serve 200 "$USABLE"
run --config-dir "$D"
expect "usable login exits 0" 0
contains "usable output names the account" "$OUT" "fake@example.com"
contains "usable output says usable" "$OUT" "usable"
run --config-dir "$D" --json
contains "json: not limited" "$(jq_py 'd["limited"]')" "False"
contains "json: unknown keys, junk entries and codename fields tolerated (2 limits)" "$(jq_py 'len(d["limits"])')" "2"
contains "json: reset normalised to UTC" "$(jq_py 'd["limits"][0]["resets_at"]')" "2026-11-09T20:00:00Z"
contains "json: no resets_at when nothing blocks" "$(jq_py 'd["resets_at"]')" "None"
contains "request carries the file's token and the oauth beta header" \
  "$(cat "$TMP/requests")" "/api/oauth/usage|Bearer $TOKEN|oauth-2025-04-20"
case "$(cat "$TMP/requests")" in *"$OTHER_TOKEN"*) ko "CLAUDE_CODE_OAUTH_TOKEN ignored" "setup token was sent" ;;
  *) ok "CLAUDE_CODE_OAUTH_TOKEN ignored" ;; esac

serve 200 "$LIMITED"
run --config-dir "$D" --json
expect "100% critical exits 2" 2
contains "json: limited" "$(jq_py 'd["limited"]')" "True"
contains "json: resets_at is when every blocking limit has cleared" "$(jq_py 'd["resets_at"]')" "2026-11-09T23:59:59Z"
contains "json: account and subscription" "$(jq_py 'd["account"] + "/" + d["subscription"]')" "fake@example.com/max"
contains "json: scope name kept" "$(jq_py 'd["limits"][2]["scope"]')" "Fable"
run --config-dir "$D"
contains "text: says limited until" "$OUT" "LIMITED until"

serve 200 '{"seven_day":{"utilization":100.0,"resets_at":"2026-11-14T16:00:00Z"},"five_hour":null}'
run --config-dir "$D" --json
expect "no limits array: legacy windows still decide" 2

serve 200 '{"limits":[{"kind":"weekly_all","percent":97,"severity":"critical","resets_at":"2026-11-09T23:59:59Z"}]}'
run --config-dir "$D" --json
expect "critical below 100% is limited" 2

serve 403 '{"type":"error","error":{"type":"permission_error","message":"x","details":{"error_code":"oauth_scope_insufficient"}}}'
run --config-dir "$D"
expect "403 exits 3" 3
serve 403 '{"error":{"type":"oauth_scope_insufficient"}}'
run --config-dir "$D"
expect "403 oauth_scope_insufficient exits 3" 3
contains "403 says missing_scope" "$ERR" "missing_scope"

serve 401 '{"error":{"type":"authentication_error"}}'
run --config-dir "$D"
expect "401 exits 4 (stale)" 4
contains "401 says unauthorized" "$ERR" "unauthorized"

serve 500 'oops'
run --config-dir "$D" --json
expect "HTTP 500 exits 3" 3
contains "json on failure keeps the shape" "$(jq_py 'str(d["limited"]) + d["error"]')" "Nonehttp_error"

serve 200 'not json'
run --config-dir "$D"
expect "non-JSON reply exits 3" 3

CU_URL="http://127.0.0.1:1/x" run --config-dir "$D"
expect "unreachable endpoint exits 3" 3
contains "unreachable says network_error" "$ERR" "network_error"

serve 200 "$USABLE"
login "$TMP/noprofile" "$FUTURE" '["user:inference"]'
run --config-dir "$TMP/noprofile"
expect "setup-token style login (no user:profile) exits 3" 3
contains "missing scope is named" "$ERR" "missing_scope"
[ ! -s "$TMP/requests" ] && ok "missing scope never calls the API" || ko "missing scope never calls the API" "request sent"

login "$TMP/stale" "$PAST" "$SCOPES"
run --config-dir "$TMP/stale"
expect "expired token exits 4" 4
contains "stale is named" "$ERR" "stale_token"
[ ! -s "$TMP/requests" ] && ok "expired token never calls the API" || ko "expired token never calls the API" "request sent"

mkdir -p "$TMP/empty"
run --config-dir "$TMP/empty"
expect "no login exits 3" 3
contains "no login is named, with the fix" "$ERR" "claude auth login"

# Explicit keychain service (any platform: the fake `security` answers).
printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s,"scopes":%s}}' "$TOKEN" "$FUTURE" "$SCOPES" > "$TMP/kc/Custom Service"
run --keychain-service "Custom Service" --config-dir "$TMP/empty"
expect "--keychain-service reads that service" 0
contains "keychain login's token is the one sent" "$(cat "$TMP/requests")" "Bearer $TOKEN"
run --keychain-service "Missing Service" --config-dir "$TMP/empty"
expect "--keychain-service with no entry exits 3" 3

# Derived service name (macOS only: other platforms read the file).
if [ "$(uname)" = Darwin ]; then
  want="Claude Code-credentials-$(printf %s "$TMP/derived" | shasum -a 256 | cut -c1-8)"
  cp "$TMP/kc/Custom Service" "$TMP/kc/$want"
  : > "$TMP/security.log"
  run --config-dir "$TMP/derived/"
  expect "derived keychain service is found (trailing slash normalised)" 0
  contains "service = prefix + sha256(config dir)[:8]" "$(cat "$TMP/security.log")" "$want"
  : > "$TMP/security.log"
  run
  contains "ambient default login uses the plain service" "$(cat "$TMP/security.log")" "Claude Code-credentials"
else
  ok "derived keychain service (skipped: not macOS)"
fi

# Nothing any run printed may contain a token.
if grep -qF -e "$TOKEN" -e "$OTHER_TOKEN" -e RT-FAKE "$TMP/everything"; then
  ko "no token in any output" "token leaked"
else
  ok "no token in any output"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
