#!/bin/bash
# Supplies lib/links.sh's caller contract to the test harness: a throwaway
# checkout and HOME, plus capturing ok/warn/skip stubs. Sourced, not executed.

links_fixture_setup() {
  LINKS_TMP=$(mktemp -d)
  export HOME="$LINKS_TMP/home"
  DOTFILES_DIR="$LINKS_TMP/checkout"
  CLAUDE_DIR="$HOME/.claude"
  mkdir -p "$DOTFILES_DIR/scripts" "$DOTFILES_DIR/hooks" "$DOTFILES_DIR/bin" \
           "$DOTFILES_DIR/codex/prompts" "$CLAUDE_DIR" "$HOME/.local/bin"
  echo '#!/bin/bash' > "$DOTFILES_DIR/statusline.sh"
  LINKS_OUT=""
  unset LINKS_DRY_RUN
  echo "$LINKS_TMP"
}

ok()   { LINKS_OUT="$LINKS_OUT[ok] $1"$'\n'; }
warn() { LINKS_OUT="$LINKS_OUT[warn] $1"$'\n'; }
skip() { LINKS_OUT="$LINKS_OUT[skip] $1"$'\n'; }
