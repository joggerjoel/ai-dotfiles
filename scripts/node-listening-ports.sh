#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# node-listening-ports.sh — publish this host's listening TCP sockets as a
# node_exporter textfile metric.
#
# node_exporter has no collector for listening ports. node_netstat_* and
# node_sockstat_* are aggregate counters, so nothing in a stock install can
# answer "what is bound to 3002 on this host". That gap is why nobody knew a
# node process held port 3000 on aorus7 until grafana failed to start on it.
#
# Reads from the inside rather than scanning from outside, so it also gets the
# process name and costs no port scan on the LAN.
#
#   node-listening-ports.sh                       write to the default dir
#   node-listening-ports.sh --dir DIR             write elsewhere
#   node-listening-ports.sh --from-file FIXTURE   parse recorded `ss` output
#   node-listening-ports.sh --from-lsof FIXTURE   parse recorded `lsof` output
#   node-listening-ports.sh --stdout              print, write nothing
#
# Linux reads `ss`, macOS reads `lsof`: macOS has no ss at all, which is why the
# first version of this script failed on every mac in the fleet. Both parsers
# emit the same three fields, so everything downstream is shared.
#
# Run as root. Neither `ss -p` nor lsof names processes the caller does not own,
# so an unprivileged run silently reports proc="unknown" for everything else,
# which looks like data rather than like a permissions problem.
# ─────────────────────────────────────────────────────────────────

OUT_DIR="/var/lib/node_exporter/textfile_collector"
FROM_FILE=""
FROM_LSOF=""
TO_STDOUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       OUT_DIR="${2:-}"; shift 2 ;;
    --from-file) FROM_FILE="${2:-}"; shift 2 ;;
    --from-lsof) FROM_LSOF="${2:-}"; shift 2 ;;
    --stdout)    TO_STDOUT=1; shift ;;
    *) echo "usage: node-listening-ports.sh [--dir DIR] [--from-file F] [--stdout]" >&2; exit 2 ;;
  esac
done

# Each parser emits "<addr> <port> <proc>" so the renderer below is shared.

parse_ss() {
  awk '
    {
      addr = $4
      # Split on the LAST colon. IPv6 locals arrive as [::]:22, so splitting on
      # the first colon yields a port of "" and a silently dropped socket.
      n = split(addr, parts, ":")
      port = parts[n]
      ip = substr(addr, 1, length(addr) - length(port) - 1)
      gsub(/^\[|\]$/, "", ip)
      if (ip == "*") ip = "0.0.0.0"
      if (port !~ /^[0-9]+$/) next
      proc = "unknown"
      if (match($0, /users:\(\("[^"]*"/)) proc = substr($0, RSTART + 9, RLENGTH - 10)
      print ip, port, proc
    }'
}

# lsof NAME looks like *:49152, 127.0.0.1:12001 or [::1]:7001, always followed
# by "(LISTEN)". COMMAND is truncated to 9 characters by default, hence -c 64.
parse_lsof() {
  awk '
    /\(LISTEN\)/ {
      addr = $(NF-1)
      n = split(addr, parts, ":")
      port = parts[n]
      ip = substr(addr, 1, length(addr) - length(port) - 1)
      gsub(/^\[|\]$/, "", ip)
      if (ip == "*") ip = "0.0.0.0"
      if (port !~ /^[0-9]+$/) next
      print ip, port, $1
    }'
}

collect() {
  if [ -n "$FROM_FILE" ]; then
    parse_ss < "$FROM_FILE"
  elif [ -n "$FROM_LSOF" ]; then
    parse_lsof < "$FROM_LSOF"
  elif [ "$(uname -s)" = "Darwin" ]; then
    # `|| true` is load-bearing. lsof exits non-zero whenever it cannot inspect
    # every process, which is normal even as root, and with pipefail plus set -e
    # that killed the whole script. It surfaced as rc 1 with empty stderr and no
    # metric file, while --stdout looked perfectly fine.
    { lsof -nP -c 64 -iTCP -sTCP:LISTEN 2>/dev/null || true; } | parse_lsof
  else
    # -H drops the header so awk never has to skip it, which is what breaks
    # when a future iproute2 reworks its column titles.
    { ss -ltnHp 2>/dev/null || true; } | parse_ss
  fi
}

render() {
  echo "# HELP node_listening_port A TCP socket in LISTEN state on this host."
  echo "# TYPE node_listening_port gauge"

  collect | awk '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    {
      # A port bound on both IPv4 and IPv6 produces two rows that normalise to
      # one identical label set. Prometheus rejects an entire textfile that
      # carries a duplicate series, so the whole metric would vanish rather than
      # double-count. Dedupe on the rendered labels.
      key = $1 "|" $2 "|" $3
      if (seen[key]++) next
      printf "node_listening_port{port=\"%s\",addr=\"%s\",proc=\"%s\"} 1\n",
             esc($2), esc($1), esc($3)
    }
  '
}

if [ "$TO_STDOUT" -eq 1 ]; then
  render
  exit 0
fi

mkdir -p "$OUT_DIR"
TMP="$(mktemp "$OUT_DIR/listening_ports.prom.XXXXXX")"
trap 'rm -f "$TMP"' EXIT INT TERM
render > "$TMP"
chmod 0644 "$TMP"
# Rename, never write in place. node_exporter reads this directory on every
# scrape, and a partially written file parses as a truncated metric set.
# mktemp put the temp file in the same directory, so the rename is atomic.
mv "$TMP" "$OUT_DIR/listening_ports.prom"
trap - EXIT INT TERM
