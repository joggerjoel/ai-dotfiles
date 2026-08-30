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

# Record which upstream commit this tree came from, mirroring
# skills/unlazy/.upstream. Without it a re-vendor silently takes whatever main
# holds and there is no way, afterwards, to say what moved. Kept outside
# skills/<name>/ on purpose: the vendor loop rm -rf's each skill directory, so
# a stamp stored in one would be destroyed by the very run that wrote it.
STAMP="$DOT/skills-local/.upstream-pstack"
SHA="$(git -C "$TMP/plugins" rev-parse HEAD)"
PREV="$(cut -d' ' -f2 "$STAMP" 2>/dev/null || true)"

# Upstream is Cursor, which writes display-style frontmatter names ("Poteto
# Mode"); Claude Code requires `name:` to equal the skill's directory, and
# preflight fails the skill when it does not. Rewriting it here — at the vendor
# step, not in the vendored tree — is what makes the fix survive: editing
# skills/<name>/SKILL.md directly is undone by the next re-vendor, because the
# loop below rm -rf's the directory before copying.
normalize_skill_name() {
  local file="$1" want="$2" tmp
  [ -f "$file" ] || return 0
  grep -q "^name: *${want}\$" "$file" && return 0
  tmp="$(mktemp)"
  awk -v want="$want" '
    NR == 1 && /^---[[:space:]]*$/ { print; in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/   { in_fm = 0; print; next }
    in_fm && /^name:/              { print "name: " want; next }
                                   { print }
  ' "$file" >"$tmp" && mv "$tmp" "$file"
  echo "  renamed frontmatter name → $want"
}

count=0
for dir in "$SRC"/*/; do
  name="$(basename "$dir")"
  rm -rf "${DEST:?}/$name"
  mkdir -p "$DEST/$name"
  cp -R "$dir." "$DEST/$name/"
  normalize_skill_name "$DEST/$name/SKILL.md" "$name"
  count=$((count + 1))
  echo "vendored $name"
done

mkdir -p "$(dirname "$STAMP")"
printf '%s %s\n' "$REPO" "$SHA" >"$STAMP"
if [ -z "$PREV" ]; then
  echo "vendored $count pstack skills at $SHA (first stamp)"
elif [ "$PREV" = "$SHA" ]; then
  echo "vendored $count pstack skills — upstream unchanged at $SHA"
else
  echo "vendored $count pstack skills — upstream moved ${PREV:0:7}..${SHA:0:7}"
fi

# Deploys from DEST, not SRC: SRC still holds the upstream frontmatter, so
# copying from it would put the un-normalized name back into ~/.claude/skills.
if [ "${1:-}" = "--deploy" ]; then
  mkdir -p "$HOME/.claude/skills"
  for dir in "$SRC"/*/; do
    name="$(basename "$dir")"
    rm -rf "$HOME/.claude/skills/${name:?}"
    mkdir -p "$HOME/.claude/skills/$name"
    cp -R "$DEST/$name/." "$HOME/.claude/skills/$name/"
  done
  echo "deployed $count skills → ~/.claude/skills/"
fi
