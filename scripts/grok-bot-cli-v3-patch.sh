#!/usr/bin/env bash
# Temporary workaround: grok-bot-cli <= 0.12.4 rejects the version-3
# gateway-descriptor.json that the Grok Bot desktop app (0.75+) writes, failing
# with "Unsupported Grok Bot gateway descriptor version 3"
# (ScriptedAlchemy/grok-bot-cli#149, unreleased fix #143). v3 keeps v2's
# `entries` layout, so accepting 3 wherever 2 is accepted is the whole fix.
#
# zsh/modules/grok-bot-cli.zsh reruns this after every global npm install.
# Idempotent, and it retires itself: a release carrying the fix no longer has
# the v1/v2-only guard, so nothing matches. Once that ships, delete this
# script, its test, the zsh module, and its modules.conf row.
#
# Usage: grok-bot-cli-v3-patch.sh [package-dir]   (default: $(npm root -g)/grok-bot-cli)

set -euo pipefail

root="${1:-$(npm root -g 2>/dev/null)/grok-bot-cli}"
[ -d "$root/dist" ] || exit 0

# The unpatched guard, e.g. `wrapped.version !== 1 && wrapped.version !== 2)`.
guard='\.version !== 1 && [A-Za-z_$][A-Za-z0-9_$]*\.version !== 2\)'

patched=0
while IFS= read -r f; do
  perl -pi -e '
    s/(\w+)\.version !== 2\)/$1.version !== 2 && $1.version !== 3)/g;
    s/\b(\w+)\.version === 2(?! \|\|)/($1.version === 2 || $1.version === 3)/g;
  ' "$f"
  patched=$((patched + 1))
done < <(grep -rlE --include='*.mjs' "$guard" "$root/dist" || true)

[ "$patched" -eq 0 ] || echo "grok-bot-cli: patched $patched bundle(s) to accept gateway descriptor v3 (#149)"
