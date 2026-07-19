#!/usr/bin/env bash
# Re-vendor the 9router skill set from upstream (decolua/9router) into
# ai-dotfiles/skills/, then inject our local deployment block into the main skill.
# Idempotent: safe to re-run to pull upstream updates. Requires `gh`.
#
#   ./scripts/vendor-9router-skills.sh            # update ai-dotfiles/skills only
#   ./scripts/vendor-9router-skills.sh --deploy   # also copy into ~/.claude/skills
set -euo pipefail

REPO="decolua/9router"
SKILLS=(9router 9router-chat 9router-embeddings 9router-image 9router-stt \
        9router-tts 9router-video 9router-web-fetch 9router-web-search)
DOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$DOT/skills"
LOCAL_BLOCK="$DOT/skills-local/9router-deployment.md"
BEGIN='<!-- BEGIN LOCAL DEPLOYMENT (ai-dotfiles/skills-local/9router-deployment.md) -->'
END='<!-- END LOCAL DEPLOYMENT -->'

command -v gh >/dev/null || { echo "need gh CLI" >&2; exit 1; }

for s in "${SKILLS[@]}"; do
  mkdir -p "$DEST/$s"
  gh api "repos/$REPO/contents/skills/$s/SKILL.md" --jq '.content' | base64 -d > "$DEST/$s/SKILL.md"
  echo "vendored $s"
done

# Inject the local deployment block into the main 9router skill, right after the
# YAML frontmatter (line 4 = closing '---'). Strip any prior block first (idempotent).
main="$DEST/9router/SKILL.md"
tmp="$(mktemp)"
awk -v b="$BEGIN" -v e="$END" '
  $0==b {skip=1} skip && $0==e {skip=0; next} skip {next} {print}
' "$main" > "$tmp"
{
  head -4 "$tmp"
  echo ""; echo "$BEGIN"; cat "$LOCAL_BLOCK"; echo "$END"
  tail -n +5 "$tmp"
} > "$main"
rm -f "$tmp"
echo "injected local deployment block into 9router/SKILL.md"

if [ "${1:-}" = "--deploy" ]; then
  for s in "${SKILLS[@]}"; do
    mkdir -p "$HOME/.claude/skills/$s"
    cp "$DEST/$s/SKILL.md" "$HOME/.claude/skills/$s/SKILL.md"
  done
  echo "deployed ${#SKILLS[@]} skills → ~/.claude/skills/"
fi
