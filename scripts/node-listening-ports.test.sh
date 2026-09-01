#!/usr/bin/env bash
# Tests for scripts/node-listening-ports.sh. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a hook.
#
# Every case runs against recorded `ss -ltnHp` output, so the suite needs no
# sockets, no root, and no network. The fixture below is real output shapes
# taken from the fleet on 2026-09-01.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SUT="$ROOT/scripts/node-listening-ports.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ports.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ (${2})}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing: $3" ;; esac; }
hasnt() { case "$2" in *"$3"*) ko "$1" "unexpected: $3" ;; *) ok "$1" ;; esac; }

cat > "$TMP/ss.txt" <<'EOF'
LISTEN 0      4096       127.0.0.1:9090       0.0.0.0:*    users:(("docker-proxy",pid=1201,fd=4))
LISTEN 0      511                *:3000             *:*    users:(("node",pid=1749524,fd=68))
LISTEN 0      4096               *:9100             *:*
LISTEN 0      128            [::]:22             [::]:*    users:(("sshd",pid=900,fd=4))
LISTEN 0      128          0.0.0.0:22           0.0.0.0:*    users:(("sshd",pid=900,fd=3))
LISTEN 0      4096         0.0.0.0:3002         0.0.0.0:*    users:(("docker-proxy",pid=1310,fd=4))
EOF

out="$(bash "$SUT" --from-file "$TMP/ss.txt" --stdout)"

# --- format -----------------------------------------------------------------

has "emits a HELP line" "$out" "# HELP node_listening_port"
has "emits a TYPE line" "$out" "# TYPE node_listening_port gauge"

has "reports a loopback-bound port with its process" "$out" \
  'node_listening_port{port="9090",addr="127.0.0.1",proc="docker-proxy"} 1'

# The port that already collided with grafana on aorus7.
has "reports the node process holding 3000" "$out" \
  'node_listening_port{port="3000",addr="0.0.0.0",proc="node"} 1'

# --- the parsing bugs this guards -------------------------------------------

# `*:3000` must normalise to a real address, not the literal asterisk, or the
# label is useless for grouping.
hasnt "a wildcard bind is not left as a literal asterisk" "$out" 'addr="*"'

# [::]:22 splits wrong on the FIRST colon, yielding an empty port and a socket
# silently dropped from the output.
has "an IPv6 wildcard bind still resolves port 22" "$out" 'port="22"'

# sshd binds 22 on both 0.0.0.0 and [::], which normalise to one identical
# label set. Prometheus rejects a whole textfile containing a duplicate series,
# so a missed dedupe deletes every metric in this file, not just this one.
eq "a port bound on v4 and v6 is emitted once, not twice" \
   "1" "$(printf '%s\n' "$out" | grep -c 'port="22",addr="0.0.0.0",proc="sshd"')"

# A socket with no users:(()) field must still be reported. node_exporter's own
# port had no process column in the fixture.
has "a socket with no process column is still reported" "$out" \
  'node_listening_port{port="9100",addr="0.0.0.0",proc="unknown"} 1'

# pid is deliberately not a label. It changes on every restart, so including it
# would grow a new series per process lifetime.
hasnt "pid is not a label" "$out" "pid="

# --- atomic write -----------------------------------------------------------

bash "$SUT" --from-file "$TMP/ss.txt" --dir "$TMP/out" >/dev/null
[ -f "$TMP/out/listening_ports.prom" ] \
  && ok "writes the metric file into the target directory" \
  || ko "writes the metric file into the target directory"

eq "leaves no temp file behind for node_exporter to read" \
   "0" "$(find "$TMP/out" -name 'listening_ports.prom.*' | wc -l | tr -d ' ')"

eq "the written file is world readable" \
   "644" "$(stat -f '%OLp' "$TMP/out/listening_ports.prom" 2>/dev/null \
            || stat -c '%a' "$TMP/out/listening_ports.prom")"

# Re-running must replace, not append.
before=$(wc -l < "$TMP/out/listening_ports.prom")
bash "$SUT" --from-file "$TMP/ss.txt" --dir "$TMP/out" >/dev/null
eq "a second run replaces the file rather than appending" \
   "$before" "$(wc -l < "$TMP/out/listening_ports.prom")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
