#!/usr/bin/env bash
# Install a pinned worker release. No daemon, enrollment, credentials, or panes.
set -euo pipefail
temporal_dotfiles_dir=$(cd "$(dirname "$0")/.." && pwd)
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
exec python3 "$temporal_dotfiles_dir/scripts/herdr-temporal-release.py" install \
    --prefix "${HERDR_TEMPORAL_PREFIX:-$HOME/.local/share/herdr-temporal}" \
    --dotfiles "$temporal_dotfiles_dir" "$@"
