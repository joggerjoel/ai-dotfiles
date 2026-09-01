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
#   node-listening-ports.sh --stdout              print, write nothing
#
# Run as root. `ss -p` only names processes the caller owns, so an unprivileged
# run silently reports proc="unknown" for everything else, which looks like data
# rather than like a permissions problem.
# ─────────────────────────────────────────────────────────────────

OUT_DIR="/var/lib/node_exporter/textfile_collector"
FROM_FILE=""
TO_STDOUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       OUT_DIR="${2:-}"; shift 2 ;;
    --from-file) FROM_FILE="${2:-}"; shift 2 ;;
    --stdout)    TO_STDOUT=1; shift ;;
    *) echo "usage: node-listening-ports.sh [--dir DIR] [--from-file F] [--stdout]" >&2; exit 2 ;;
  esac
done

collect() {
  if [ -n "$FROM_FILE" ]; then
    cat "$FROM_FILE"
  else
    # -H drops the header so awk never has to skip it, which is what breaks
    # when a future iproute2 reworks its column titles.
    ss -ltnHp 2>/dev/null
  fi
}

render() {
  echo "# HELP node_listening_port A TCP socket in LISTEN state on this host."
  echo "# TYPE node_listening_port gauge"

  collect | awk '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
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
      if (match($0, /users:\(\("[^"]*"/)) {
        proc = substr($0, RSTART + 9, RLENGTH - 10)
      }

      # A port bound on both IPv4 and IPv6 produces two rows that normalise to
      # one identical label set. Prometheus rejects an entire textfile that
      # carries a duplicate series, so the whole metric would vanish rather than
      # double-count. Dedupe on the rendered labels.
      key = ip "|" port "|" proc
      if (seen[key]++) next

      printf "node_listening_port{port=\"%s\",addr=\"%s\",proc=\"%s\"} 1\n",
             esc(port), esc(ip), esc(proc)
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
