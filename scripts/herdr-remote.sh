#!/usr/bin/env bash
# herdr-remote.sh — attach a herdr server running on a NODE (e.g. macstudio)
# from THIS laptop over a NON-SSH mesh (Tailscale/WireGuard). The laptop side of
# herdr-node.sh's `bridge`.
#
# herdr's control socket is a local Unix socket and its only built-in remote is
# SSH. This helper instead runs a local socat that forwards an ISOLATED herdr
# profile's socket to the node's mesh-exposed bridge port — so `herdr` talks to
# the remote server with zero ssh, and WITHOUT disturbing this machine's own
# local herdr server (a separate XDG profile keeps the two sockets apart).
#
#   ./scripts/herdr-remote.sh            # attach the TUI (herdr --remote over SSH/tailnet)
#   ./scripts/herdr-remote.sh up         # start the local socat bridge (control plane)
#   ./scripts/herdr-remote.sh status     # remote server/session state over the mesh (no ssh)
#   ./scripts/herdr-remote.sh down       # stop the local socat bridge
#
# Attach is SSH (herdr --remote): the TUI's client socket passes file
# descriptors, which cannot cross a TCP bridge. The socat/mesh bridge remains
# for the CONTROL PLANE only — status, session list, api — with zero ssh.
#
# Env:
#   HERDR_REMOTE_SSH    ssh alias for interactive attach (default "macstudio")
#   HERDR_REMOTE_HOST   node's tailnet name/IP for the bridge (default "mac" via MagicDNS)
#   HERDR_BRIDGE_PORT   node's bridge port (default 7070)
#   HERDR_REMOTE_CFG    isolated XDG dir for the remote profile (default ~/.herdr-remote-cfg)
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
header(){ echo -e "\n${BOLD}$1${RESET}"; }

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"

HOST="${HERDR_REMOTE_HOST:-mac}"                  # tailnet name/IP — control-plane bridge
SSH_TARGET="${HERDR_REMOTE_SSH:-macstudio}"       # ssh alias — interactive attach
PORT="${HERDR_BRIDGE_PORT:-7070}"
REMOTE_CFG="${HERDR_REMOTE_CFG:-$HOME/.herdr-remote-cfg}"
SOCK="$REMOTE_CFG/herdr/herdr.sock"

require() { command -v "$1" >/dev/null 2>&1 || { fail "$1 not found on PATH"; exit 1; }; }
client_running() { pgrep -f "UNIX-LISTEN:$SOCK" >/dev/null 2>&1; }
remote_status() { XDG_CONFIG_HOME="$REMOTE_CFG" herdr status 2>/dev/null | awk '/^server:/{s=1} s&&/status:/{print $2;exit}'; }

cmd_up() {
  require herdr; require socat
  mkdir -p "$REMOTE_CFG/herdr"
  if client_running; then
    skip "local bridge already up ($SOCK → $HOST:$PORT)"
  else
    rm -f "$SOCK"
    nohup socat "UNIX-LISTEN:$SOCK,reuseaddr,fork" "TCP:$HOST:$PORT" \
      >"$REMOTE_CFG/bridge.log" 2>&1 &
    sleep 1
    client_running || { fail "socat did not stay up — see $REMOTE_CFG/bridge.log"; cat "$REMOTE_CFG/bridge.log" 2>/dev/null; exit 1; }
    ok "local bridge up ($SOCK → $HOST:$PORT)"
  fi
  local st; st="$(remote_status)"
  if [ "$st" = "running" ]; then
    ok "remote herdr reachable over the mesh (server: running)"
  else
    fail "bridge up but remote server not answering (status: ${st:-none})"
    warn "is the node's server + bridge up?  on the node:  herdr-node.sh up && herdr-node.sh bridge"
    exit 1
  fi
}

# Interactive attach uses herdr's native --remote (SSH transport): the TUI
# needs herdr's client socket, which passes file descriptors and therefore
# CANNOT cross the TCP bridge — the bridge is control-plane only (status/api).
# Tailscale makes this SSH direct from anywhere (no jump host).
cmd_attach() {
  header "herdr remote · attach ($SSH_TARGET)"
  ok "attaching via herdr --remote (Ctrl-b q to detach; captain + crew keep running on the node)"
  exec herdr --remote "$SSH_TARGET"
}

cmd_status() {
  header "herdr remote · status ($HOST)"
  cmd_up
  echo
  XDG_CONFIG_HOME="$REMOTE_CFG" herdr status 2>&1 | sed 's/^/  /'
  echo -e "  ${DIM}sessions:${RESET}"
  XDG_CONFIG_HOME="$REMOTE_CFG" herdr session list 2>&1 | sed 's/^/  /'
}

cmd_down() {
  header "herdr remote · down"
  if client_running; then
    pkill -f "UNIX-LISTEN:$SOCK" 2>/dev/null && ok "stopped local bridge" || warn "could not stop socat"
  else
    skip "no local bridge running"
  fi
  rm -f "$SOCK"
}

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-attach}" in
  attach|"") cmd_attach ;;
  up)        cmd_up ;;
  status)    cmd_status ;;
  down|stop) cmd_down ;;
  -h|--help|help) usage ;;
  *) fail "unknown command: $1"; echo; usage; exit 2 ;;
esac
