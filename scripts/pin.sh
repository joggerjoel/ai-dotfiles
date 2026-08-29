#!/bin/bash
set -uo pipefail

# ─────────────────────────────────────────────────────────────────
# pin.sh — per-CLI update policy for the sibling agent CLIs that
# agents-update.sh manages.
#
# Config is a plain "<name>=<action>" file (not JSON — it is read by
# shell on every fleet host, and grep beats a parser dependency):
#   ~/.local/state/ai-dotfiles/agents-update.conf
#
# Two actions, and the absence of one:
#   pin    hold at the installed version; never upgrade
#   auto   always upgrade, never ask
#   (none) ask when a human is attached, upgrade when unattended
#
# agents-update.sh sources this for get_action/set_action; it is also
# runnable directly to decide policy AHEAD of an unattended run, so an
# Ansible or cron host converges with no tty involved:
#   pin.sh list
#   pin.sh add <name>      pin at current version
#   pin.sh auto <name>     always upgrade
#   pin.sh remove <name>   clear, go back to asking
# ─────────────────────────────────────────────────────────────────

AGENTS_PIN_STATE_DIR="${AGENTS_PIN_STATE_DIR:-$HOME/.local/state/ai-dotfiles}"
AGENTS_CONF_FILE="$AGENTS_PIN_STATE_DIR/agents-update.conf"

# Prints the configured action for a CLI, or nothing when unset.
get_action() {
  [ -f "$AGENTS_CONF_FILE" ] || return 0
  sed -n "s/^$1=//p" "$AGENTS_CONF_FILE" | head -1
}

set_action() {
  mkdir -p "$AGENTS_PIN_STATE_DIR"
  clear_action "$1"
  echo "$1=$2" >> "$AGENTS_CONF_FILE"
}

clear_action() {
  [ -f "$AGENTS_CONF_FILE" ] || return 0
  grep -v "^$1=" "$AGENTS_CONF_FILE" > "$AGENTS_CONF_FILE.tmp" 2>/dev/null || true
  mv "$AGENTS_CONF_FILE.tmp" "$AGENTS_CONF_FILE"
}

is_pinned() { [ "$(get_action "$1")" = "pin" ]; }
is_auto()   { [ "$(get_action "$1")" = "auto" ]; }

# Names configured with a given action, one per line.
list_action() {
  [ -f "$AGENTS_CONF_FILE" ] || return 0
  sed -n "s/=$1\$//p" "$AGENTS_CONF_FILE"
}
list_pins() { list_action pin; }

# Only dispatch a subcommand when executed directly — sourcing this
# file (agents-update.sh does) must define the functions above and
# nothing else.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    list)
      if [ ! -s "$AGENTS_CONF_FILE" ] 2>/dev/null || [ ! -f "$AGENTS_CONF_FILE" ]; then
        echo "No CLI update policy configured — every CLI will be asked about."
      else
        echo "CLI update policy ($AGENTS_CONF_FILE):"
        while IFS='=' read -r n a; do
          [ -n "$n" ] || continue
          case "$a" in
            pin)  printf "  %-14s pinned — never upgraded\n" "$n" ;;
            auto) printf "  %-14s auto — always upgraded, never asked\n" "$n" ;;
            *)    printf "  %-14s %s\n" "$n" "$a" ;;
          esac
        done < "$AGENTS_CONF_FILE"
      fi
      ;;
    add | pin)
      [ -n "${2:-}" ] || { echo "usage: pin.sh add <name>" >&2; exit 1; }
      set_action "$2" pin
      echo "Pinned $2 — it will not be upgraded."
      ;;
    auto)
      [ -n "${2:-}" ] || { echo "usage: pin.sh auto <name>" >&2; exit 1; }
      set_action "$2" auto
      echo "Set $2 to always upgrade — it will not be asked about."
      ;;
    remove | rm | unpin)
      [ -n "${2:-}" ] || { echo "usage: pin.sh remove <name>" >&2; exit 1; }
      clear_action "$2"
      echo "Cleared $2 — it will be asked about again."
      ;;
    *)
      echo "usage: pin.sh {list|add <name>|auto <name>|remove <name>}" >&2
      exit 1
      ;;
  esac
fi
