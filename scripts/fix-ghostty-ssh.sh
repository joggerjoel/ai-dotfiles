#!/usr/bin/env bash
# Install Ghostty's terminfo on an SSH destination to prevent prompt redraw bugs.

set -euo pipefail

usage() {
    echo "Usage: $0 <ssh-host>"
    echo "Run this on the Mac where Ghostty is running, not on the remote host."
}

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

HOST=$1
case "$HOST" in
    ''|-*)
        echo "ghostty-ssh: invalid SSH host: $HOST" >&2
        exit 2
        ;;
esac

if ! command -v ssh >/dev/null 2>&1; then
    echo "ghostty-ssh: ssh is not installed" >&2
    exit 1
fi

# Ghostty 1.4+ has a first-party wrapper that installs terminfo and manages
# its cache. Prefer it when available, but retain the documented manual path
# for Ghostty 1.2/1.3.
if command -v ghostty >/dev/null 2>&1 && \
    ghostty +ssh --help >/dev/null 2>&1; then
    echo "ghostty-ssh: installing terminfo on $HOST with Ghostty's SSH wrapper"
    ghostty +ssh --cache=false -- "$HOST" true
else
    INFOCMP=infocmp
    for candidate in \
        /opt/homebrew/opt/ncurses/bin/infocmp \
        /usr/local/opt/ncurses/bin/infocmp; do
        if [ -x "$candidate" ] && "$candidate" -x xterm-ghostty >/dev/null 2>&1; then
            INFOCMP=$candidate
            break
        fi
    done

    if ! "$INFOCMP" -x xterm-ghostty >/dev/null 2>&1; then
        echo "ghostty-ssh: local xterm-ghostty terminfo is unavailable" >&2
        echo "Open a fresh Ghostty window and retry, or install ncurses with Homebrew." >&2
        exit 1
    fi

    echo "ghostty-ssh: installing xterm-ghostty terminfo on $HOST"
    "$INFOCMP" -x xterm-ghostty | ssh "$HOST" -- tic -x -
fi

if ssh "$HOST" -- infocmp xterm-ghostty >/dev/null 2>&1; then
    echo "ghostty-ssh: fixed; $HOST now recognizes TERM=xterm-ghostty"
    echo "Reconnect with: ssh $HOST"
else
    echo "ghostty-ssh: install ran, but remote verification failed on $HOST" >&2
    exit 1
fi
