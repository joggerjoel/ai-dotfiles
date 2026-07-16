#!/bin/bash
# check-updates.sh — SessionStart update notifier.
#
# Reports (never installs) when a managed package is out of sync with its
# latest upstream, so YOU decide whether to upgrade. Checks four things:
#   1. Claude Code           — installed vs latest on npm
#   2. This dotfiles repo    — local clone vs its git remote
#   3. Plugin marketplaces   — cached clones vs their git remotes
#   4. System CLI tools      — node, gh, bun, uv vs latest release
#
# Two modes:
#   (no args)    Hook mode. Prints the cached result as a Claude Code
#                systemMessage (silent when everything is in sync), then
#                spawns a detached --refresh if the cache is stale. Never
#                blocks startup on the network.
#   --refresh    Does the actual (networked) checks and rewrites the cache.
#                Runs in the background; safe to call directly to force a check.

set -u

# ── Resolve the dotfiles repo from this script's location ────────────
# setup.sh symlinks scripts/*.sh into ~/.claude/scripts/, so follow the
# symlink chain (portably — no `readlink -f`, which BSD/macOS lacks) to find
# the real repo root for the git check.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
    link="$(readlink "$SELF")"
    case "$link" in
        /*) SELF="$link" ;;
        *)  SELF="$(dirname "$SELF")/$link" ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CACHE="$HOME/.claude/.update-check.cache"
LOCK="$HOME/.claude/.update-check.lock"
TTL=43200   # 12h — refresh the cache at most this often

# OS-aware mtime (matches statusline.sh's approach).
if [[ "$(uname -s)" == "Darwin" ]]; then
    stat_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }
else
    stat_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }
fi

# Bound network calls when `timeout` (or macOS `gtimeout`) is available; a
# no-op otherwise so the script still works without coreutils.
if command -v timeout >/dev/null 2>&1; then BOUND="timeout 15"
elif command -v gtimeout >/dev/null 2>&1; then BOUND="gtimeout 15"
else BOUND=""; fi
bound() { $BOUND "$@"; }

# semver from arbitrary version output, e.g. "gh version 2.96.0 (…)" → 2.96.0
semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

# is_behind INSTALLED LATEST → true only when INSTALLED < LATEST (never when
# equal or ahead), so a newer-than-registry local build is never flagged.
is_behind() {
    [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] || return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]
}

# latest_gh_release owner/repo → newest release tag with leading "v" stripped.
latest_gh_release() {
    bound curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//'
}

# ── Refresh: run the real checks, rewrite the cache atomically ───────
do_refresh() {
    # Single-flight: if another refresh holds the lock, bail. A reboot or
    # kill -9 mid-refresh leaves the lock behind forever — treat >60min as
    # stale so the notifier can't freeze on a cached result indefinitely.
    if [ -d "$LOCK" ]; then
      find "$LOCK" -maxdepth 0 -mmin +60 -exec rmdir {} \; 2>/dev/null || true
    fi
    if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT

    local out="" line

    # 1. Claude Code (npm) --------------------------------------------
    local cc_have cc_want
    cc_have=$(claude --version 2>/dev/null | semver)
    cc_want=$(bound npm view @anthropic-ai/claude-code version 2>/dev/null | semver)
    if is_behind "$cc_have" "$cc_want"; then
        out+="Claude Code: $cc_have → $cc_want  (npm i -g @anthropic-ai/claude-code)"$'\n'
    fi

    # 2. This dotfiles repo -------------------------------------------
    if git -C "$DOTFILES_DIR" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        bound git -C "$DOTFILES_DIR" fetch --quiet 2>/dev/null
        local behind
        behind=$(git -C "$DOTFILES_DIR" rev-list --count 'HEAD..@{u}' 2>/dev/null)
        if [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null; then
            out+="dotfiles: $behind commit(s) behind origin  (./setup.sh update)"$'\n'
        fi
    fi

    # 3. Plugin marketplaces ------------------------------------------
    local mp_dir="$HOME/.claude/plugins/marketplaces" stale=()
    if [ -d "$mp_dir" ]; then
        local d name behind
        for d in "$mp_dir"/*/; do
            name=$(basename "$d")
            git -C "$d" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 || continue
            bound git -C "$d" fetch --quiet 2>/dev/null
            behind=$(git -C "$d" rev-list --count 'HEAD..@{u}' 2>/dev/null)
            [ -n "$behind" ] && [ "$behind" -gt 0 ] 2>/dev/null && stale+=("$name")
        done
        if [ ${#stale[@]} -gt 0 ]; then
            local IFS=', '
            out+="plugins: ${stale[*]} have updates  (/plugin → update, or restart)"$'\n'
        fi
    fi

    # 4. System CLI tools ---------------------------------------------
    local have want
    if command -v node >/dev/null 2>&1; then
        have=$(node -v 2>/dev/null | semver)
        want=$(bound curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null \
                 | jq -r 'map(select(.lts != false))[0].version // empty' 2>/dev/null | semver)
        is_behind "$have" "$want" && out+="node: $have → $want (LTS)"$'\n'
    fi
    if command -v gh >/dev/null 2>&1; then
        have=$(gh --version 2>/dev/null | semver)
        want=$(latest_gh_release cli/cli)
        is_behind "$have" "$want" && out+="gh: $have → $want"$'\n'
    fi
    if command -v bun >/dev/null 2>&1; then
        have=$(bun --version 2>/dev/null | semver)
        want=$(latest_gh_release oven-sh/bun)
        is_behind "$have" "$want" && out+="bun: $have → $want"$'\n'
    fi
    if command -v uv >/dev/null 2>&1; then
        have=$(uv --version 2>/dev/null | semver)
        want=$(latest_gh_release astral-sh/uv)
        is_behind "$have" "$want" && out+="uv: $have → $want"$'\n'
    fi

    # Write atomically. Empty file = "checked, all in sync" (hook stays silent).
    local tmp
    tmp=$(mktemp) || exit 0
    printf '%s' "$out" > "$tmp"
    mv "$tmp" "$CACHE"
}

# ── Hook: emit cached result, refresh in background if stale ─────────
do_hook() {
    local content=""
    [ -f "$CACHE" ] && content=$(cat "$CACHE" 2>/dev/null)

    if [ -n "$content" ]; then
        local msg="📦 Updates available (your call whether to upgrade):"$'\n'"$content"
        jq -cn --arg m "$msg" '{systemMessage: $m}'
    fi

    # Refresh when the cache is missing or older than the TTL — detached so
    # startup never waits on the network.
    if [ ! -f "$CACHE" ] || [ $(( $(date +%s) - $(stat_mtime "$CACHE") )) -gt "$TTL" ]; then
        nohup "$SELF" --refresh >/dev/null 2>&1 &
    fi
}

case "${1:-}" in
    --refresh) do_refresh ;;
    *)         do_hook ;;
esac
