#!/usr/bin/env bash
# Vendor RayFernando's Apache-2.0 WAVES skills into this repository.
#
# Both skills are pinned to one upstream commit so a single update cannot mix
# worker instructions from different revisions. `waves` is installed for
# Claude. `waves-codex` is also linked into Codex by setup.sh.
#
#   ./scripts/vendor-rayfernando-skills.sh            # update tracked sources
#   ./scripts/vendor-rayfernando-skills.sh --deploy   # also install locally
set -euo pipefail

REPO="https://github.com/RayFernando1337/rayfernando-skills.git"
SKILLS=(
  "plugins/waves/skills/waves|waves"
  "plugins/waves-codex/skills/waves-codex|waves-codex"
)

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$DOTFILES_DIR/skills"
STAMP="$DOTFILES_DIR/skills-local/.upstream-rayfernando-waves"
MODE="${1:-}"

case "$MODE" in
  ""|--deploy) ;;
  *) echo "usage: $0 [--deploy]" >&2; exit 2 ;;
esac

command -v git >/dev/null || { echo "need git" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
source="$tmp/source"
git clone --quiet --depth 1 "$REPO" "$source"
sha="$(git -C "$source" rev-parse HEAD)"
previous="$(awk '{print $2}' "$STAMP" 2>/dev/null || true)"

for entry in "${SKILLS[@]}"; do
  upstream_path="${entry%%|*}"
  name="${entry##*|}"
  from="$source/$upstream_path"
  to="$DEST/$name"
  [ -f "$from/SKILL.md" ] || {
    echo "$upstream_path has no SKILL.md; upstream layout changed" >&2
    exit 1
  }

  staged="$tmp/$name"
  cp -R "$from" "$staged"
  if ! find "$staged" -maxdepth 1 -iname 'LICENSE*' -print -quit | grep -q .; then
    cp "$source/LICENSE" "$staged/LICENSE"
  fi
  printf '%s %s %s\n' "$REPO" "$sha" "$upstream_path" > "$staged/.upstream"
  rm -rf "${to:?}"
  mv "$staged" "$to"
done

mkdir -p "$(dirname "$STAMP")"
printf '%s %s\n' "$REPO" "$sha" > "$STAMP"

if [ -z "$previous" ]; then
  echo "vendored waves and waves-codex at ${sha:0:12} (first stamp)"
elif [ "$previous" = "$sha" ]; then
  echo "vendored waves and waves-codex — upstream unchanged at ${sha:0:12}"
else
  echo "vendored waves and waves-codex — upstream moved ${previous:0:7}..${sha:0:7}"
fi

if [ "$MODE" = "--deploy" ]; then
  mkdir -p "$HOME/.claude/skills" "$HOME/.codex/skills"
  rm -rf "$HOME/.claude/skills/waves" "$HOME/.claude/skills/waves-codex"
  cp -R "$DEST/waves" "$HOME/.claude/skills/waves"
  cp -R "$DEST/waves-codex" "$HOME/.claude/skills/waves-codex"
  rm -rf "$HOME/.codex/skills/waves-codex"
  ln -s "$DEST/waves-codex" "$HOME/.codex/skills/waves-codex"
  echo "deployed waves to Claude and waves-codex to Claude and Codex"
fi
