#!/usr/bin/env bash
# Tests for herdr-network.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# No network and no real HOME. A synthetic ssh config holds a wildcard block,
# a direct-style pair, a ProxyJump-style pair, an unpaired alias, a
# multi-pattern Host line and a wildcard *-jump block. A stub `nc` on PATH
# succeeds or fails according to a marker file. Resolution cases run real
# `ssh -G`, which never connects.

HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/herdr-network.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/herdr-network-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/nc" <<'STUB'
#!/bin/bash
echo "nc $*" >> "$STUB_DIR/calls"
[ -f "$STUB_DIR/lan.up" ]
STUB
chmod +x "$TMP/bin/nc"

fresh() { # → new ssh config, no override file, LAN down
  rm -rf "$TMP/h" "$TMP/stub"; mkdir -p "$TMP/h" "$TMP/stub"
  cat > "$TMP/h/config" <<'CFG'
Host *
  ServerAliveInterval 30

Host alpha
  HostName 192.168.1.10
  User joel

Host alpha-ts
  HostName 100.64.0.10
  HostKeyAlias alpha-lan
  User joel

Host beta
  HostName 192.168.1.20
  Port 2222
  User joel

# the tailnet route goes through a jump box
Host beta-ts
  HostName 10.0.0.20
  ProxyJump alpha-ts
  User joel

Host solo
  HostName 192.168.1.30

Host x y
  HostName 192.168.1.40

Host x-ts y-ts
  HostName 100.64.0.40

Host *-jump
  HostName 100.64.0.99
CFG
  chmod 600 "$TMP/h/config"
}

run() { # <args...> → runs the script against the fresh sandbox
  PATH="$TMP/bin:$PATH" STUB_DIR="$TMP/stub" \
    SSH_CONFIG="$TMP/h/config" HERDR_NETWORK_CONF="$TMP/h/herdr-network.conf" \
    HERDR_NETWORK_PROBE_TIMEOUT=1 bash "$S" "$@"
}

resolved() { # <alias> <key> → ssh -G value
  ssh -G -F "$TMP/h/config" "$1" 2>/dev/null | awk -v k="$2" '$1 == k { print $2; exit }'
}

fresh
run ts >/dev/null 2>&1
conf=$(cat "$TMP/h/herdr-network.conf")
if [ "$(grep -c '^Host ' <<<"$conf")" = 2 ] \
  && grep -qx '  HostName 100.64.0.10' <<<"$conf" \
  && grep -qx '  HostKeyAlias alpha-lan' <<<"$conf" \
  && grep -qx '  ProxyJump alpha-ts' <<<"$conf" \
  && ! grep -qE 'solo|^Host x|jump' <<<"$conf"; then
  ok "ts writes one override block per pair, copied verbatim, none for unpaired"
else
  ko "ts override blocks" "$conf"
fi

fresh
run lan >/dev/null 2>&1
if ! grep -q '^Host ' "$TMP/h/herdr-network.conf" && grep -q '^# mode: lan$' "$TMP/h/herdr-network.conf"; then
  ok "lan writes header only"
else
  ko "lan header only" "$(cat "$TMP/h/herdr-network.conf")"
fi

fresh
run ts >/dev/null 2>&1
run lan >/dev/null 2>&1
inc="Include $TMP/h/herdr-network.conf"
n=$(grep -cxF "$inc" "$TMP/h/config")
first=$(grep -v '^$' "$TMP/h/config" | head -n 1)
baks=$(find "$TMP/h" -name 'config.bak.*' | wc -l | tr -d ' ')
mode=$(stat -f %Lp "$TMP/h/config" 2>/dev/null || stat -c %a "$TMP/h/config")
if [ "$n" = 1 ] && [ "$first" = "$inc" ] && [ "$baks" = 1 ] && [ "$mode" = 600 ]; then
  ok "Include inserted once at top over two runs, one backup, mode 600"
else
  ko "Include insertion" "count=$n first='$first' backups=$baks mode=$mode"
fi

fresh
touch "$TMP/stub/lan.up"
run auto >/dev/null 2>&1
up=$(sed -n 's/^# mode: //p' "$TMP/h/herdr-network.conf")
rm "$TMP/stub/lan.up"
run auto >/dev/null 2>&1
down=$(sed -n 's/^# mode: //p' "$TMP/h/herdr-network.conf")
if [ "$up" = lan ] && [ "$down" = ts ]; then
  ok "auto picks lan when a probe answers, ts when none do"
else
  ko "auto detection" "up=$up down=$down"
fi

fresh
touch "$TMP/stub/lan.up"
run auto >/dev/null 2>&1
if grep -q ' 192.168.1.20 2222$' "$TMP/stub/calls" && grep -q ' 192.168.1.10 22$' "$TMP/stub/calls"; then
  ok "auto probes each pair's LAN HostName and Port"
else
  ko "auto probe targets" "$(cat "$TMP/stub/calls" 2>/dev/null)"
fi

# macOS nc's -w is an idle timeout; only -G bounds the connect, so without it a
# dead LAN address holds auto for the kernel's 75 s.
fresh
run auto >/dev/null 2>&1
if [ "$(uname -s)" != Darwin ] || grep -q 'nc -z -G 1 -w 1 192.168.1.10 22' "$TMP/stub/calls"; then
  ok "auto bounds each probe's connect time on macOS"
else
  ko "probe connect timeout" "$(cat "$TMP/stub/calls" 2>/dev/null)"
fi

# A pair whose LAN alias already names the tailnet host (macstudio) answers from
# anywhere, so probing it would always pick lan.
fresh
cat >> "$TMP/h/config" <<'CFG'

Host gamma
  HostName gamma.example.ts.net

Host gamma-ts
  HostName gamma.example.ts.net
CFG
run auto >/dev/null 2>&1
if ! grep -q 'gamma.example.ts.net' "$TMP/stub/calls" && grep -q '192.168.1.10' "$TMP/stub/calls"; then
  ok "auto skips pairs whose LAN route is the tailnet route"
else
  ko "auto probes tailnet-only pair" "$(cat "$TMP/stub/calls" 2>/dev/null)"
fi

fresh
out=$(run ts --dry-run 2>/dev/null)
if [ ! -e "$TMP/h/herdr-network.conf" ] \
  && ! grep -q '^Include' "$TMP/h/config" \
  && [ -z "$(find "$TMP/h" -name 'config.bak.*')" ] \
  && grep -qx '  HostName 100.64.0.10' <<<"$out"; then
  ok "--dry-run prints the override and changes nothing"
else
  ko "--dry-run" "conf exists or Include added"
fi

fresh
run ts >/dev/null 2>&1
if [ "$(resolved alpha hostname)" = 100.64.0.10 ] \
  && [ "$(resolved beta hostname)" = 10.0.0.20 ] \
  && [ "$(resolved beta proxyjump)" = alpha-ts ] \
  && [ "$(resolved solo hostname)" = 192.168.1.30 ]; then
  ok "ssh -G resolves paired aliases to the tailnet route after ts"
else
  ko "ts resolution" "alpha=$(resolved alpha hostname) beta=$(resolved beta hostname)"
fi
run lan >/dev/null 2>&1
if [ "$(resolved alpha hostname)" = 192.168.1.10 ] \
  && [ "$(resolved beta hostname)" = 192.168.1.20 ] \
  && [ "$(resolved beta port)" = 2222 ]; then
  ok "ssh -G resolves paired aliases to the LAN route after lan"
else
  ko "lan resolution" "alpha=$(resolved alpha hostname) beta=$(resolved beta hostname)"
fi

fresh
printf 'Host solo\n  HostName 192.168.1.30\n' > "$TMP/h/config"
run ts >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ] && [ ! -e "$TMP/h/herdr-network.conf" ]; then
  ok "config with no pairs exits 2"
else
  ko "no pairs" "rc=$rc"
fi

fresh
run status >"$TMP/status.out" 2>&1 && st_before=$(cat "$TMP/status.out")
run ts >/dev/null 2>&1
run status >"$TMP/status.out" 2>&1
rc=$?
if [ "$rc" = 0 ] \
  && grep -q '^mode: lan (no override file)$' <<<"$st_before" \
  && grep -q '^mode: ts$' "$TMP/status.out" \
  && grep -Eq '^alpha[[:space:]]+100\.64\.0\.10[[:space:]]+\(ts: 100\.64\.0\.10\)$' "$TMP/status.out" \
  && grep -Eq '^beta[[:space:]]+10\.0\.0\.20[[:space:]]+\(ts: 10\.0\.0\.20\)$' "$TMP/status.out"; then
  ok "status reports the recorded mode and each pair"
else
  ko "status" "$(cat "$TMP/status.out")"
fi

fresh
run bogus >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "unknown argument exits 1"; else ko "usage" "rc=$rc"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
