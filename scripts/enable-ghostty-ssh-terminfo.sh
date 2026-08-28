#!/usr/bin/env bash
# Turn on Ghostty's native SSH terminfo integration.
#
# Ghostty ships ssh-env and ssh-terminfo (both since 1.2.0) but disables them by
# default. Without them TERM=xterm-ghostty reaches hosts that have no matching
# terminfo entry, zsh loses `el` and 256-color SGR, and ZLE can no longer erase
# the line it is redrawing - which shows up as doubled characters while typing.
#
# Run this on the machine running Ghostty, not on the SSH destination.

set -euo pipefail

usage() {
    echo "Usage: $0 [--dry-run]"
    echo "Enables ssh-env + ssh-terminfo in the local Ghostty config."
}

DRY_RUN=0
case "${1-}" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    '') ;;
    *) usage >&2; exit 2 ;;
esac

if [ ! -d /Applications/Ghostty.app ] && ! command -v ghostty >/dev/null 2>&1; then
    echo "ghostty-terminfo: Ghostty is not installed on this machine" >&2
    echo "Run this on the machine where Ghostty runs, not on the SSH destination." >&2
    exit 1
fi

# Ghostty prefers whichever config path exists and is non-empty, favouring the
# Application Support directory when neither is.
APP_SUPPORT="$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
CONFIG=""
for candidate in \
    "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config.ghostty" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/config" \
    "$APP_SUPPORT" \
    "$HOME/Library/Application Support/com.mitchellh.ghostty/config"; do
    if [ -s "$candidate" ]; then
        CONFIG=$candidate
        break
    fi
done
[ -n "$CONFIG" ] || CONFIG=$APP_SUPPORT

KEY=shell-integration-features
# Shipped default, minus the two SSH toggles this script owns.
BASE=cursor,no-sudo,title,path

current=""
if [ -f "$CONFIG" ]; then
    current=$(sed -n "s/^[[:space:]]*${KEY}[[:space:]]*=[[:space:]]*//p" "$CONFIG" | tail -1)
fi

# Preserve any other features already configured; we only own the SSH toggles.
if [ -n "$current" ]; then
    BASE=$(printf '%s' "$current" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -vxE 'n?o?-?ssh-(env|terminfo)|no-ssh-env|no-ssh-terminfo|ssh-env|ssh-terminfo' \
        | grep -v '^$' | paste -sd, -)
fi
DESIRED="${BASE:+$BASE,}ssh-env,ssh-terminfo"

if [ "$current" = "$DESIRED" ]; then
    echo "ghostty-terminfo: already enabled in $CONFIG"
    exit 0
fi

echo "ghostty-terminfo: config  $CONFIG"
echo "ghostty-terminfo: before  ${current:-<unset, using shipped default>}"
echo "ghostty-terminfo: after   $DESIRED"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "ghostty-terminfo: dry run, no changes written"
    exit 0
fi

mkdir -p "$(dirname "$CONFIG")"
touch "$CONFIG"

BACKUP_DIR="$HOME/.claude/.backups/ghostty"
mkdir -p "$BACKUP_DIR"
BACKUP="$BACKUP_DIR/$(basename "$CONFIG").$(date +%Y%m%d_%H%M%S)"
cp "$CONFIG" "$BACKUP"
echo "ghostty-terminfo: backed up to $BACKUP"

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
if [ -n "$current" ]; then
    sed "s|^[[:space:]]*${KEY}[[:space:]]*=.*|${KEY} = ${DESIRED}|" "$CONFIG" > "$TMP"
else
    cat "$CONFIG" > "$TMP"
    [ -s "$TMP" ] && ! [ -z "$(tail -c1 "$TMP")" ] && echo >> "$TMP"
    echo "${KEY} = ${DESIRED}" >> "$TMP"
fi
cat "$TMP" > "$CONFIG"

CHANGELOG="$HOME/.claude/.backups/CHANGELOG.md"
[ -d "$(dirname "$CHANGELOG")" ] && \
    echo "$(date '+%Y-%m-%d %H:%M') | $CONFIG | enable ghostty ssh-env + ssh-terminfo" >> "$CHANGELOG"

echo "ghostty-terminfo: enabled"
echo "Restart Ghostty (config is not auto-reloaded), then reconnect."
