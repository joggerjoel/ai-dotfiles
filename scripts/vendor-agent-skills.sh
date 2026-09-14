#!/usr/bin/env bash
# Vendor individual skills from third-party skill repositories into
# ai-dotfiles/skills/<name>/, one folder per skill, pinned to the upstream commit.
#
# These upstreams publish no Claude plugin marketplace (or publish one whose
# bundle would drag in a dozen skills we don't want), so the copy model in
# setup.sh's install_skills() is the right fit: vendor here, and `setup.sh` /
# `setup.sh update` ships the folder to every host. Same shape as
# vendor-unlazy-skill.sh, generalised to a table of (repo, path, name).
#
# Each vendored folder gets a `.upstream` stamp — "<clone-url> <sha> <path>" —
# so a later re-run can report what moved, and a reader can find the source.
# A root LICENSE is copied in when the skill folder has none of its own.
#
#   ./scripts/vendor-agent-skills.sh            # re-vendor everything at upstream HEAD
#   ./scripts/vendor-agent-skills.sh --deploy   # re-vendor, then copy to ~/.claude/skills
set -euo pipefail

# repo|path-in-repo|folder-name-here
# The folder name matches the skill's frontmatter `name`, which is how Claude
# Code lists it, so the two never disagree.
SKILLS=(
  "mattpocock/skills|skills/productivity/handoff|handoff"
  "mattpocock/skills|skills/productivity/grill-me|grill-me"
  "vercel-labs/agent-skills|skills/web-design-guidelines|web-design-guidelines"
  "vercel-labs/agent-skills|skills/react-best-practices|vercel-react-best-practices"
  "vercel-labs/agent-skills|skills/composition-patterns|vercel-composition-patterns"
  "anthropics/skills|skills/webapp-testing|webapp-testing"
)

DOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$DOT/skills"
MODE="${1:-}"

command -v git >/dev/null || { echo "need git" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# One shallow clone per distinct repo, so every skill from a repo comes from
# the same commit and the stamps agree.
clone_dir() { echo "$TMP/${1//\//__}"; }
sha_of() { git -C "$(clone_dir "$1")" rev-parse HEAD; }

for entry in "${SKILLS[@]}"; do
  repo="${entry%%|*}"
  dir="$(clone_dir "$repo")"
  [ -d "$dir" ] && continue
  git clone --quiet --depth 1 "https://github.com/$repo.git" "$dir"
done

for entry in "${SKILLS[@]}"; do
  IFS='|' read -r repo path name <<<"$entry"
  src="$(clone_dir "$repo")/$path"
  [ -f "$src/SKILL.md" ] || { echo "$repo:$path has no SKILL.md — layout changed?" >&2; exit 1; }

  sha="$(sha_of "$repo")"
  stamp="$DEST/$name/.upstream"
  prev="$(cut -d' ' -f2 "$stamp" 2>/dev/null || true)"

  rm -rf "${DEST:?}/${name:?}"
  cp -R "$src" "$DEST/$name"
  if ! ls "$DEST/$name"/LICENSE* >/dev/null 2>&1; then
    root_license="$(ls "$(clone_dir "$repo")"/LICENSE* 2>/dev/null | head -1 || true)"
    [ -n "$root_license" ] && cp "$root_license" "$DEST/$name/LICENSE"
  fi
  printf 'https://github.com/%s.git %s %s\n' "$repo" "$sha" "$path" >"$stamp"

  if [ -z "$prev" ]; then
    echo "vendored $name at ${sha:0:7} (first stamp)"
  elif [ "$prev" = "$sha" ]; then
    echo "vendored $name — upstream unchanged at ${sha:0:7}"
  else
    echo "vendored $name — upstream moved ${prev:0:7}..${sha:0:7}"
  fi
done

if [ "$MODE" = "--deploy" ]; then
  for entry in "${SKILLS[@]}"; do
    name="${entry##*|}"
    rm -rf "$HOME/.claude/skills/${name:?}"
    cp -R "$DEST/$name" "$HOME/.claude/skills/$name"
  done
  echo "deployed ${#SKILLS[@]} skills → ~/.claude/skills/"
fi
