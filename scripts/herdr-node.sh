#!/usr/bin/env bash
# herdr-node.sh — bring up and control the herdr session server on a NODE
# (the always-on box, e.g. macstudio, where first mate + crew persist).
#
# herdr speaks ONE transport for control: a local Unix socket
# (~/.config/herdr/herdr.sock). Its only built-in remote is `herdr --remote`,
# which is SSH. This script owns the node (server) side: start it reliably,
# keep it alive across reboots (launchd), and — opt-in — expose the socket over
# a NON-SSH mesh with socat for `remote-but-not-ssh` clients.
#
# Idempotent: `up` is a no-op if the server is already running.
# Fail-loud: non-zero exit if herdr is missing or the server won't come up.
#
#   ./scripts/herdr-node.sh up                 # start headless server + default session
#   ./scripts/herdr-node.sh status             # server + session state
#   ./scripts/herdr-node.sh restart            # down then up
#   ./scripts/herdr-node.sh down               # stop the server
#   ./scripts/herdr-node.sh captain-tab        # ensure a persistent firstmate captain tab
#   ./scripts/herdr-node.sh service install [node|bridge|all]   # launchd (default all)
#   ./scripts/herdr-node.sh service uninstall [node|bridge|all] # remove launchd agent(s)
#   ./scripts/herdr-node.sh bridge [PORT]      # EXPERIMENTAL non-ssh socket bridge (mesh-only)
#
# Env:
#   HERDR_SESSION        session name to run (default "default")
#   HERDR_BRIDGE_PORT    TCP port for `bridge` (default 7070)
#   HERDR_BRIDGE_BIND    bind addr for `bridge` (default: this node's tailnet IP; "any"=0.0.0.0)
#   HERDR_START_TIMEOUT  seconds to wait for the server to report running (default 15)
set -uo pipefail

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
skip() { echo -e "  ${DIM}○ $1${RESET}"; }
warn() { echo -e "  ${YELLOW}!${RESET} $1"; }
fail() { echo -e "  ${RED}✗${RESET} $1"; }
header(){ echo -e "\n${BOLD}$1${RESET}"; }

# PATH hardening — launchd/cron/non-login shells miss ~/.local/bin and brew, so
# `command -v herdr` would spuriously fail (the fleet-proven fix).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"

SESSION="${HERDR_SESSION:-default}"
BRIDGE_PORT="${HERDR_BRIDGE_PORT:-7070}"
BRIDGE_BIND="${HERDR_BRIDGE_BIND:-}"
START_TIMEOUT="${HERDR_START_TIMEOUT:-15}"
HERDR_SOCK="$HOME/.config/herdr/herdr.sock"
LOG_DIR="$HOME/.config/herdr"
LABEL="dev.herdr.node"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
BRIDGE_LABEL="dev.herdr.bridge"
BRIDGE_PLIST="$HOME/Library/LaunchAgents/${BRIDGE_LABEL}.plist"
SCRIPT_PATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"

# Load/unload a LaunchAgent into the console user's GUI domain (works over SSH
# when a desktop session is active), falling back to legacy load for older macOS.
_launchd_load() {
  local plist="$1" label="$2" domain="gui/$(id -u)"
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  if launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then ok "loaded $label ($domain)"
  elif launchctl load -w "$plist" >/dev/null 2>&1; then ok "loaded $label (legacy load -w)"
  else warn "plist written but immediate load failed — it will load at next login: $plist"; fi
}
_launchd_unload() {
  local plist="$1" label="$2" domain="gui/$(id -u)"
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || launchctl unload -w "$plist" >/dev/null 2>&1 || true
  if [ -f "$plist" ]; then rm -f "$plist" && ok "removed $plist"; else skip "no plist at $plist"; fi
}

require_herdr() {
  command -v herdr >/dev/null 2>&1 || { fail "herdr not found on PATH ($PATH)"; exit 1; }
}

# Value of the server 'status:' line from `herdr status` ("running" | "" | ...).
server_status() {
  herdr status 2>/dev/null | awk '/^server:/{s=1;next} s&&/status:/{print $2;exit}'
}
server_running() { [ "$(server_status)" = "running" ]; }

cmd_up() {
  header "herdr node · up (session: ${SESSION})"
  require_herdr
  if server_running; then
    skip "server already running — nothing to do"
    cmd_status
    return 0
  fi
  mkdir -p "$LOG_DIR"
  # Headless start incantation is herdr's own: HERDR_SESSION + explicit --session.
  # A bare socket call does NOT auto-start the server (per firstmate herdr-backend docs).
  HERDR_SESSION="$SESSION" nohup herdr server --session "$SESSION" \
    >>"$LOG_DIR/herdr-node.out" 2>>"$LOG_DIR/herdr-node.err" &
  local waited=0
  while ! server_running; do
    sleep 1; waited=$((waited+1))
    if [ "$waited" -ge "$START_TIMEOUT" ]; then
      fail "server did not report running within ${START_TIMEOUT}s — see $LOG_DIR/herdr-node.err"
      exit 1
    fi
  done
  ok "server running (socket: $HERDR_SOCK)"
  cmd_status
}

cmd_down() {
  header "herdr node · down"
  require_herdr
  if ! server_running; then skip "server not running"; return 0; fi
  if herdr server stop >/dev/null 2>&1; then ok "server stopped"; else fail "herdr server stop failed"; exit 1; fi
}

cmd_restart() { cmd_down; cmd_up; }

cmd_status() {
  header "herdr node · status"
  require_herdr
  herdr status 2>&1 | sed 's/^/  /'
  echo
  echo -e "  ${DIM}sessions:${RESET}"
  herdr session list 2>&1 | sed 's/^/  /'
}

# --- captain tab (persistent firstmate captain inside the session) -----------
# Idempotent: ensures one tab labeled "captain" exists in the running session,
# with claude launched in ~/firstmate. The captain then lives IN herdr — it
# survives laptop lids, dropped SSH, and reboots (launchd restarts the server;
# herdr restores panes). Ephemeral ssh-tty captains are for quick one-offs only.
cmd_captain_tab() {
  require_herdr
  command -v jq >/dev/null 2>&1 || { fail "jq required for captain-tab"; exit 1; }
  server_running || { fail "server not running — run '$0 up' first"; exit 1; }
  local fm_dir="${FIRSTMATE_DIR:-$HOME/firstmate}"
  [ -d "$fm_dir" ] || { fail "firstmate not found at $fm_dir"; exit 1; }
  local tab_id
  tab_id=$(herdr tab list 2>/dev/null | jq -r '.result.tabs[]? | select(.label=="captain") | .tab_id' | head -1)
  if [ -n "$tab_id" ]; then
    skip "captain tab already present ($tab_id) — attach and keep going"
    return 0
  fi
  # --no-focus: never steal focus from someone already attached and working.
  herdr tab create --cwd "$fm_dir" --label captain --no-focus >/dev/null 2>&1
  sleep 1
  tab_id=$(herdr tab list 2>/dev/null | jq -r '.result.tabs[]? | select(.label=="captain") | .tab_id' | head -1)
  [ -n "$tab_id" ] || { fail "captain tab did not appear after create"; exit 1; }
  local pane_id
  pane_id=$(herdr pane list 2>/dev/null | jq -r --arg t "$tab_id" '.result.panes[]? | select(.tab_id==$t) | .pane_id' | head -1)
  [ -n "$pane_id" ] || { fail "no pane found in captain tab $tab_id"; exit 1; }
  herdr pane send-text "$pane_id" "claude" >/dev/null 2>&1 \
    && herdr pane send-keys "$pane_id" enter >/dev/null 2>&1 \
    || { fail "could not launch claude in pane $pane_id"; exit 1; }
  ok "captain tab created ($tab_id) — claude starting in $fm_dir"
}

# --- launchd (always-on node) ------------------------------------------------
cmd_service_install() {
  header "herdr node · service install (launchd ${LABEL})"
  require_herdr
  local herdr_bin; herdr_bin="$(command -v herdr)"
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  cat >"$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${herdr_bin}</string>
    <string>server</string>
    <string>--session</string>
    <string>${SESSION}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERDR_SESSION</key><string>${SESSION}</string>
    <!-- firstmate crewmates launch `claude` inside herdr panes and inherit this
         server's environment. The autoresearch plugin's scout-block hook is a
         file-access guard that blocks crewmate reads mid-task; disable it for
         panes here so the firstmate checkout stays pristine (no fm-spawn.sh edit). -->
    <key>AR_DISABLE_SCOUT_BLOCK</key><string>1</string>
    <key>PATH</key><string>${HOME}/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <!-- Restart only on ABNORMAL exit. A plain KeepAlive=true would respawn the
       server the instant herdr shuts it down for its own restart/update handoff,
       making `herdr --remote` fail with "old server is still responding". -->
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>StandardOutPath</key><string>${LOG_DIR}/herdr-node.out</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/herdr-node.err</string>
</dict>
</plist>
PLISTEOF
  ok "wrote $PLIST"
  _launchd_load "$PLIST" "$LABEL"
  ok "herdr server will start at login and be kept alive"
}

cmd_service_uninstall() {
  header "herdr node · service uninstall (${LABEL})"
  _launchd_unload "$PLIST" "$LABEL"
}

# launchd for the non-ssh bridge (server side). KeepAlive retries until the
# herdr server and tailnet are ready, so ordering vs the node service is safe.
cmd_bridge_service_install() {
  header "herdr node · bridge service install (launchd ${BRIDGE_LABEL})"
  require_herdr
  command -v socat >/dev/null 2>&1 || { fail "socat not found — install with: brew install socat"; exit 1; }
  [ -f "$SCRIPT_PATH" ] || { fail "cannot resolve own path ($SCRIPT_PATH)"; exit 1; }
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  cat >"$BRIDGE_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${BRIDGE_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${SCRIPT_PATH}</string>
    <string>bridge</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERDR_SESSION</key><string>${SESSION}</string>
    <key>HERDR_BRIDGE_PORT</key><string>${BRIDGE_PORT}</string>
    <key>PATH</key><string>${HOME}/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${LOG_DIR}/herdr-bridge.out</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/herdr-bridge.err</string>
</dict>
</plist>
PLISTEOF
  ok "wrote $BRIDGE_PLIST"
  _launchd_load "$BRIDGE_PLIST" "$BRIDGE_LABEL"
  ok "non-ssh bridge will start at login and be kept alive (mesh-only bind)"
}

cmd_bridge_service_uninstall() {
  header "herdr node · bridge service uninstall (${BRIDGE_LABEL})"
  _launchd_unload "$BRIDGE_PLIST" "$BRIDGE_LABEL"
}

# --- experimental non-ssh remote bridge --------------------------------------
# Forwards the herdr Unix socket over TCP so a remote client can reach this
# server WITHOUT ssh. socat is plaintext: this MUST ride inside a WireGuard-class
# mesh (Tailscale/Netbird/ZeroTier). NEVER expose the port to the raw internet.
# Client side (on the laptop):
#   socat UNIX-LISTEN:$HOME/.config/herdr/herdr.sock,reuseaddr,fork TCP:<mesh-ip>:PORT
#   herdr        # local client now talks to this node's server
cmd_bridge() {
  header "herdr node · bridge (EXPERIMENTAL, non-ssh)"
  require_herdr
  local port="${1:-$BRIDGE_PORT}"
  command -v socat >/dev/null 2>&1 || { fail "socat not found — install with: brew install socat"; exit 1; }
  server_running || { fail "server not running — run '$0 up' first"; exit 1; }
  [ -S "$HERDR_SOCK" ] || { fail "herdr socket not present at $HERDR_SOCK"; exit 1; }
  # Bind ONLY to the tailnet address so the herdr socket is never exposed on the
  # LAN or the public internet. HERDR_BRIDGE_BIND overrides; set it to "any" to
  # force 0.0.0.0 (discouraged — the socket stream is plaintext).
  local bind="$BRIDGE_BIND"
  if [ -z "$bind" ]; then
    bind="$(tailscale ip -4 2>/dev/null | head -1)"
    [ -z "$bind" ] && bind="$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null | head -1)"
  fi
  local listen
  if [ "$bind" = "any" ]; then
    warn "binding 0.0.0.0 — the plaintext herdr socket will be reachable on every interface"
    listen="TCP-LISTEN:${port},reuseaddr,fork"
  elif [ -n "$bind" ]; then
    listen="TCP-LISTEN:${port},bind=${bind},reuseaddr,fork"
  else
    fail "no tailnet IP found (is tailscale up?). Set HERDR_BRIDGE_BIND=<ip> or =any to override."
    exit 1
  fi
  warn "socat is PLAINTEXT — only run this inside a WireGuard/Tailscale mesh, never the open internet"
  warn "unsupported: herdr does not test socket-over-TCP; expect possible latency/framing quirks"
  ok "forwarding ${bind:-0.0.0.0}:${port} → ${HERDR_SOCK} (Ctrl-C to stop)"
  echo -e "  ${DIM}client (on the laptop): mkdir -p ~/.herdr-remote-cfg/herdr && \\
    socat UNIX-LISTEN:~/.herdr-remote-cfg/herdr/herdr.sock,reuseaddr,fork TCP:${bind}:${port} & \\
    XDG_CONFIG_HOME=~/.herdr-remote-cfg herdr${RESET}"
  exec socat "$listen" "UNIX-CONNECT:${HERDR_SOCK}"
}

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-up}" in
  up)       cmd_up ;;
  down|stop) cmd_down ;;
  restart)  cmd_restart ;;
  status)   cmd_status ;;
  captain-tab) cmd_captain_tab ;;
  service)
    svc_target="${3:-all}"
    case "${2:-}" in
      install)
        case "$svc_target" in
          node)   cmd_service_install ;;
          bridge) cmd_bridge_service_install ;;
          all)    cmd_service_install; cmd_bridge_service_install ;;
          *) fail "usage: $0 service install {node|bridge|all}"; exit 2 ;;
        esac ;;
      uninstall)
        case "$svc_target" in
          node)   cmd_service_uninstall ;;
          bridge) cmd_bridge_service_uninstall ;;
          all)    cmd_bridge_service_uninstall; cmd_service_uninstall ;;
          *) fail "usage: $0 service uninstall {node|bridge|all}"; exit 2 ;;
        esac ;;
      *) fail "usage: $0 service {install|uninstall} [node|bridge|all]"; exit 2 ;;
    esac ;;
  bridge)   shift; cmd_bridge "${1:-}" ;;
  -h|--help|help) usage ;;
  *) fail "unknown command: $1"; echo; usage; exit 2 ;;
esac
