#!/usr/bin/env bash
# Vendor the unlazy skill (github.com/Leonxlnx/unlazy) into ai-dotfiles/skills/unlazy,
# and deploy it to ~/.claude/skills and ~/.codex/skills. Requires `git`.
#
# Unlike 9router/pstack, unlazy IS the repository — SKILL.md sits at its root
# alongside the Node checker it drives. The vendored copy is split in two:
#
#   tracked    SKILL.md, SECURITY.md, references/, templates/, ... (prose)
#   gitignored scripts/  — third-party Node that runs shell from CHECK: lines
#
# skills/unlazy/.upstream is the lockfile that joins them: it records the exact
# commit the prose came from, so --payload can restore the untracked half
# reproducibly on any host that only has what git carries.
#
#   ./scripts/vendor-unlazy-skill.sh            # re-vendor everything at upstream HEAD
#   ./scripts/vendor-unlazy-skill.sh --payload  # restore scripts/ at the pinned commit
#   ./scripts/vendor-unlazy-skill.sh --deploy   # re-vendor, then copy to ~/.claude + ~/.codex
set -euo pipefail

REPO="https://github.com/Leonxlnx/unlazy.git"
NAME="unlazy"
PAYLOAD_DIR="scripts"
# Tracked runtime prose. SKILL.md points at SECURITY.md, references/, and
# templates/ by relative path, so all of them ship. LICENSE is MIT — it ships too.
TRACKED=(SKILL.md SECURITY.md README.md LICENSE agents references templates research)

DOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$DOT/skills/$NAME"
STAMP="$DEST/.upstream"
MODE="${1:-}"

command -v git >/dev/null || { echo "need git" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Fetch upstream at $1 ("HEAD" or a full SHA) into $TMP/src; echoes the SHA.
fetch_upstream() {
  local ref="$1" src="$TMP/src"
  mkdir -p "$src"
  if [ "$ref" = "HEAD" ]; then
    git clone --quiet --depth 1 "$REPO" "$src"
  else
    # Shallow-fetch one commit by SHA so a pinned restore stays cheap.
    git -C "$src" init --quiet
    git -C "$src" remote add origin "$REPO"
    git -C "$src" fetch --quiet --depth 1 origin "$ref"
    git -C "$src" checkout --quiet FETCH_HEAD
  fi
  git -C "$src" rev-parse HEAD
}

install_payload() {
  local src="$1"
  [ -d "$src/$PAYLOAD_DIR" ] || { echo "$PAYLOAD_DIR missing upstream — layout changed?" >&2; exit 1; }
  rm -rf "${DEST:?}/$PAYLOAD_DIR"
  cp -R "$src/$PAYLOAD_DIR" "$DEST/$PAYLOAD_DIR"
}

if [ "$MODE" = "--payload" ]; then
  # Restore only the gitignored half, at the commit the tracked prose came from.
  # Deliberately touches no tracked file: a fleet host that ran this must stay
  # clean for the next `git pull`.
  [ -f "$STAMP" ] || { echo "no $STAMP — run ./scripts/vendor-unlazy-skill.sh first" >&2; exit 1; }
  pinned="$(awk '{print $2}' "$STAMP")"
  [ -n "$pinned" ] || { echo "$STAMP has no commit recorded" >&2; exit 1; }
  fetch_upstream "$pinned" >/dev/null
  install_payload "$TMP/src"
  echo "restored $NAME/$PAYLOAD_DIR @ ${pinned:0:12} (pinned)"
  exit 0
fi

SHA="$(fetch_upstream HEAD)"
for item in "${TRACKED[@]}"; do
  [ -e "$TMP/src/$item" ] || { echo "$item missing upstream — layout changed?" >&2; exit 1; }
done

rm -rf "${DEST:?}"
mkdir -p "$DEST"
for item in "${TRACKED[@]}"; do
  cp -R "$TMP/src/$item" "$DEST/"
done
install_payload "$TMP/src"
printf '%s %s\n' "$REPO" "$SHA" > "$STAMP"
echo "vendored $NAME @ ${SHA:0:12}"

if [ "$MODE" = "--deploy" ]; then
  # Claude reads ~/.claude/skills; Codex reads ~/.codex/skills. unlazy is one of
  # the few repo skills that is genuinely agent-agnostic (it ships
  # agents/openai.yaml for Codex), so it goes to both.
  for root in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
    mkdir -p "$root"
    rm -rf "${root:?}/$NAME"
    cp -R "$DEST" "$root/$NAME"
  done
  echo "deployed $NAME → ~/.claude/skills/ and ~/.codex/skills/"
fi
