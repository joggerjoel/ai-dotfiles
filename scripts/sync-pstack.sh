#!/usr/bin/env bash
# sync-pstack.sh — install or refresh michael-denyer/pstack-claude for every
# runtime that discovers Agent Skills from a shared directory: Codex, Prime
# Agent, opencode, and Gemini CLI. Claude Code is NOT served here; it gets
# pstack as a proper plugin (hooks/, agents/) via bootstrap-plugins.sh.
#
# Replaces vendor-pstack-skills.sh, which pulled the Cursor original from
# cursor/plugins and hand-patched frontmatter. That left Cursor primitives in
# every skill body (subagent_type: generalPurpose, environment: "cloud", Cursor
# model slugs, the ~/.cursor/rules/ config path). pstack-claude is the
# maintained port with all of those translated, synced against upstream.
#
# Three things happen, all idempotent:
#   1. clone or fast-forward the port into $CLONE
#   2. link plugins/pstack/skills/*          -> ~/.agents/skills/<name>
#      (52 dirs: 31 public workflows + 21 principle-* leaves poteto-mode reads
#      by path — keep the leaves even though some runtimes list them)
#   3. link plugins/pstack/.codex-plugin/prompts/*.md -> ~/.codex/prompts/<name>.md
#      and set multi_agent = true in ~/.codex/config.toml, without which
#      interrogate / arena / how / why / reflect / architect degrade to a single
#      sequential pass on Codex
#
# Symlinks, not copies: the port's README verifies the symlink install on live
# Codex and opencode sessions, and a link tree means one `git pull` refreshes
# every runtime. Stale links from a prior version are pruned before relinking.
#
#   ./scripts/sync-pstack.sh          # install/refresh
#   PSTACK_CLONE=/path ./scripts/sync-pstack.sh   # override clone location
set -uo pipefail

REPO="https://github.com/michael-denyer/pstack-claude.git"
CLONE="${PSTACK_CLONE:-$HOME/.local/share/pstack-claude}"
SKILLS_SRC="$CLONE/plugins/pstack/skills"
PROMPTS_SRC="$CLONE/plugins/pstack/.codex-plugin/prompts"
AGENTS_SKILLS="$HOME/.agents/skills"
CODEX_PROMPTS="$HOME/.codex/prompts"
CODEX_CONFIG="$HOME/.codex/config.toml"

BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
ok()     { echo -e "  ${GREEN}✓${RESET} $1"; }
skip()   { echo -e "  ${DIM}○ $1${RESET}"; }
warn()   { echo -e "  ${YELLOW}!${RESET} $1"; }
header() { echo -e "\n${BOLD}$1${RESET}"; }

command -v git >/dev/null || { warn "git not available — pstack not synced"; exit 0; }

# ── 1. clone or fast-forward ─────────────────────────────────────
# Both network calls carry a stall cap: abort if under 1 KB/s for 30 s. git
# has no --timeout, and macOS ships no `timeout`, so this is the portable way
# to keep a slow GitHub from wedging an unattended fleet update.
STALL=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30)
header "pstack-claude (Codex / Prime / opencode / Gemini)"
if [ -d "$CLONE/.git" ]; then
  before="$(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null)"
  if git -C "$CLONE" "${STALL[@]}" pull --ff-only --quiet 2>/dev/null; then
    after="$(git -C "$CLONE" rev-parse --short HEAD 2>/dev/null)"
    if [ "$before" = "$after" ]; then
      skip "already at $after"
    else
      ok "updated $before → $after"
    fi
  else
    # Network down or upstream rewrote history. Existing links still resolve,
    # so keep going with what's on disk rather than leaving runtimes half-wired.
    warn "pull failed (network?) — relinking from existing clone at $(git -C "$CLONE" rev-parse --short HEAD)"
  fi
elif git "${STALL[@]}" clone --quiet --depth 1 "$REPO" "$CLONE" 2>/dev/null; then
  ok "cloned → $CLONE ($(git -C "$CLONE" rev-parse --short HEAD))"
else
  warn "clone failed (network?) — pstack not installed for Codex/Prime/opencode/Gemini"
  exit 0
fi

[ -d "$SKILLS_SRC" ] || { warn "plugins/pstack/skills not found in clone — upstream layout changed?"; exit 1; }

# ── 2. shared Agent Skills tree ──────────────────────────────────
# Prune first: a link we made earlier that now dangles (skill renamed or
# removed upstream) would otherwise sit there as a broken entry every runtime
# lists. Only links pointing INTO our clone are ours to remove; anything else
# in ~/.agents/skills belongs to the user or another installer.
mkdir -p "$AGENTS_SKILLS"
pruned=0
for link in "$AGENTS_SKILLS"/*; do
  [ -L "$link" ] || continue
  case "$(readlink "$link")" in
    "$SKILLS_SRC"/*) [ -e "$link" ] || { rm -f "$link"; pruned=$((pruned + 1)); } ;;
  esac
done
[ "$pruned" -gt 0 ] && ok "pruned $pruned stale skill link(s)"

linked=0; kept=0
for dir in "$SKILLS_SRC"/*/; do
  name="$(basename "$dir")"
  target="${dir%/}"
  dest="$AGENTS_SKILLS/$name"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$target" ]; then
    kept=$((kept + 1))
  elif [ -e "$dest" ] && [ ! -L "$dest" ]; then
    # A real directory here is a user-authored skill with the same name.
    # Never clobber it — pstack's copy simply loses on this machine.
    warn "$name exists as a real directory in ~/.agents/skills — left untouched"
  else
    ln -sfn "$target" "$dest"
    linked=$((linked + 1))
  fi
done
ok "skills → ~/.agents/skills ($linked linked, $kept current)"

# ── 3. Codex: slash-command stubs + multi_agent ───────────────────
if [ -d "$PROMPTS_SRC" ]; then
  mkdir -p "$CODEX_PROMPTS"
  plinked=0; pkept=0
  for f in "$PROMPTS_SRC"/*.md; do
    [ -e "$f" ] || continue
    dest="$CODEX_PROMPTS/$(basename "$f")"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$f" ]; then
      pkept=$((pkept + 1))
    elif [ -e "$dest" ] && [ ! -L "$dest" ]; then
      warn "$(basename "$f") exists as a real file in ~/.codex/prompts — left untouched"
    else
      ln -sfn "$f" "$dest"
      plinked=$((plinked + 1))
    fi
  done
  ok "codex prompts → ~/.codex/prompts ($plinked linked, $pkept current)"
else
  skip "no .codex-plugin/prompts in clone — Codex slash commands not linked"
fi

# multi_agent gates spawn_agent / wait_agent / close_agent, which every
# multi-model skill fans out through. Idempotent TOML edit: no-op if already
# true, insert under an existing [features] table, else append the table.
# Backed up first, per ~/.claude/CLAUDE.md config policy.
if [ -f "$CODEX_CONFIG" ] && grep -qE '^\s*multi_agent\s*=\s*true' "$CODEX_CONFIG"; then
  skip "codex multi_agent already enabled"
else
  mkdir -p "$(dirname "$CODEX_CONFIG")" "$HOME/.claude/.backups/codex"
  if [ -f "$CODEX_CONFIG" ]; then
    cp "$CODEX_CONFIG" "$HOME/.claude/.backups/codex/config.toml.$(date +%Y%m%d_%H%M%S)"
  fi
  if [ -f "$CODEX_CONFIG" ] && grep -qE '^\s*multi_agent\s*=' "$CODEX_CONFIG"; then
    # Present but false: flip it in place.
    sed -i.bak -E 's/^(\s*multi_agent\s*=\s*)false/\1true/' "$CODEX_CONFIG" && rm -f "$CODEX_CONFIG.bak"
  elif [ -f "$CODEX_CONFIG" ] && grep -qE '^\s*\[features\]' "$CODEX_CONFIG"; then
    # Table exists: insert directly under its header.
    sed -i.bak -E 's/^(\s*\[features\]\s*)$/\1\
multi_agent = true/' "$CODEX_CONFIG" && rm -f "$CODEX_CONFIG.bak"
  else
    printf '\n[features]\nmulti_agent = true\n' >> "$CODEX_CONFIG"
  fi
  echo "$(date '+%Y-%m-%d %H:%M') | ~/.codex/config.toml | sync-pstack.sh: enabled [features] multi_agent = true (pstack multi-model skills need spawn_agent)" \
    >> "$HOME/.claude/.backups/CHANGELOG.md"
  ok "codex multi_agent = true"
fi

echo -e "  ${DIM}Model config: run /setup-pstack in each runtime (writes ~/.claude/pstack-models.md or ~/.codex/pstack-models.md).${RESET}"
