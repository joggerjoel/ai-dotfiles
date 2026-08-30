#!/usr/bin/env bash
# Run herdr-paste from a HUD laptop against the node's herdr API.
#
# `herdr --remote <node>` leaves only a bridge socket on this machine — it
# shuttles bytes to the node's TUI and serves no API, so every herdr-paste verb
# has nothing local to talk to (see references/herdr-paste.md, "Finding the
# socket"). This forwards the node's real API socket here for the length of one
# command and points herdr-paste at it.
#
# The tunnel is per-invocation on purpose. A credential relay that leaves a
# standing tunnel to the machine holding every pane is a worse trade than
# paying an ssh handshake per paste.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PASTE="$HERE/herdr-paste.py"

node=$(python3 "$PASTE" _node)

# No node means a local API server already answers — resolution finds it
# unaided, and a tunnel would be a detour. Also the case on the node itself.
if [ -z "$node" ]; then
  exec python3 "$PASTE" "$@"
fi

# A unix socket path cannot exceed 104 bytes, so this lives at the root of
# /tmp rather than under $TMPDIR, which on macOS is already ~50 characters.
sock=$(mktemp -u "/tmp/hp-${node}.XXXXXX")
ctl=$(mktemp -u "/tmp/hpc-${node}.XXXXXX")

cleanup() {
  ssh -S "$ctl" -O exit "$node" 2>/dev/null || true
  rm -f "$sock"
}
trap cleanup EXIT INT TERM

# Master first, then ask it for $HOME, then add the forward. Resolving the
# remote home rather than assuming /Users/<me> keeps this working on the Linux
# nodes, where it is /home/<me>.
ssh -M -S "$ctl" -o ControlPersist=no -f -N "$node"
remote_home=$(ssh -S "$ctl" "$node" 'printf %s "$HOME"')
ssh -S "$ctl" -O forward \
    -L "$sock:$remote_home/.config/herdr/herdr.sock" "$node" >/dev/null

# Not exec: the trap above has to run, and exec would replace this shell
# before it could, leaving both the tunnel and the socket behind.
HERDR_SOCKET_PATH="$sock" python3 "$PASTE" "$@"
