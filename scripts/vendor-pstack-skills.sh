#!/usr/bin/env bash
# Re-vendor poteto's pstack skill pack (github.com/cursor/plugins, pstack/skills/)
# into ai-dotfiles/skills/, then deploy to ~/.claude/skills. Idempotent: safe to
# re-run to pull upstream updates. Requires `git`.
#
# Mirrors vendor-9router-skills.sh, but pulls the whole skills/ subtree via a
# sparse clone instead of per-file `gh api` calls — several pstack skills
# (poteto-mode, architect, interrogate, how, why, reflect, show-me-your-work,
# create-verification-skill, typescript-best-practices) ship references/ and
# scripts/ alongside SKILL.md, not just the one file.
#
#   ./scripts/vendor-pstack-skills.sh            # update ai-dotfiles/skills only
#   ./scripts/vendor-pstack-skills.sh --deploy   # also copy into ~/.claude/skills
set -euo pipefail

REPO="https://github.com/cursor/plugins.git"
DOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$DOT/skills"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

command -v git >/dev/null || { echo "need git" >&2; exit 1; }

git clone --quiet --depth 1 --filter=blob:none --sparse "$REPO" "$TMP/plugins"
git -C "$TMP/plugins" sparse-checkout set --no-cone pstack/skills >/dev/null

SRC="$TMP/plugins/pstack/skills"
[ -d "$SRC" ] || { echo "pstack/skills not found upstream — layout changed?" >&2; exit 1; }

count=0
for dir in "$SRC"/*/; do
  name="$(basename "$dir")"
  rm -rf "${DEST:?}/$name"
  mkdir -p "$DEST/$name"
  cp -R "$dir." "$DEST/$name/"
  count=$((count + 1))
  echo "vendored $name"
done
echo "vendored $count pstack skills"

if [ "${1:-}" = "--deploy" ]; then
  mkdir -p "$HOME/.claude/skills"
  for dir in "$SRC"/*/; do
    name="$(basename "$dir")"
    rm -rf "$HOME/.claude/skills/${name:?}"
    mkdir -p "$HOME/.claude/skills/$name"
    cp -R "$dir." "$HOME/.claude/skills/$name/"
  done
  echo "deployed $count skills → ~/.claude/skills/"
fi
