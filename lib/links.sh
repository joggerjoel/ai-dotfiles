#!/bin/bash
# Repo-owned symlinks, shared by setup.sh and update.sh.
# Sourced, never executed. No side effects at source time.
#
# Caller contract: DOTFILES_DIR, CLAUDE_DIR, and the ok/warn/skip helpers must
# be defined before relink_all runs. Must stay bash 3.2 compatible — #!/bin/bash
# is 3.2.57 on macOS.

# Any non-empty value means dry run. Defaulted here so sourcing from setup.sh,
# which has no --dry-run, cannot trip `set -u`.
LINKS_DRY_RUN="${LINKS_DRY_RUN:-}"

# Always returns 0: a non-zero return would abort the caller at every bare
# call site under `set -e`. Callers learn what happened from the counters.
link_file() {
  local src="$1" dst="$2" dst_dir backup_dir

  if [ ! -e "$src" ]; then
    skip "$(basename "$dst") — source missing"
    LINK_SKIPPED=$(( LINK_SKIPPED + 1 ))
    return 0
  fi

  # Already correct: touch nothing, print nothing. Ends the churn where every
  # run removed and recreated every link.
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    LINK_OK=$(( LINK_OK + 1 ))
    return 0
  fi

  # A directory here would make `ln -s` create the link INSIDE it, at a path
  # nothing reads.
  if [ -d "$dst" ] && [ ! -L "$dst" ]; then
    warn "$(basename "$dst") is a directory — refusing to link over it"
    LINK_FAILED=$(( LINK_FAILED + 1 ))
    return 0
  fi

  if [ -n "$LINKS_DRY_RUN" ]; then
    ok "$(basename "$dst") -> ${src#"$DOTFILES_DIR"/} (dry run)"
    LINK_CHANGED=$(( LINK_CHANGED + 1 ))
    return 0
  fi

  dst_dir=$(dirname "$dst")
  if ! mkdir -p "$dst_dir" 2>/dev/null; then
    warn "$(basename "$dst") — cannot create $dst_dir"
    LINK_FAILED=$(( LINK_FAILED + 1 ))
    return 0
  fi

  if [ -f "$dst" ] && [ ! -L "$dst" ]; then
    backup_dir="$CLAUDE_DIR/.backups/setup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp "$dst" "$backup_dir/$(basename "$dst")"
    warn "Backed up existing $(basename "$dst") to $backup_dir/"
  fi

  # -f -n: atomic replace, and never descend into a symlinked directory.
  if ln -sfn "$src" "$dst" 2>/dev/null; then
    ok "$(basename "$dst") -> ${src#"$DOTFILES_DIR"/}"
    LINK_CHANGED=$(( LINK_CHANGED + 1 ))
  else
    warn "$(basename "$dst") — could not create link"
    LINK_FAILED=$(( LINK_FAILED + 1 ))
  fi
  return 0
}

# Repo CLI helpers (bin/* -> ~/.local/bin/<name>). Symlinked so a repo pull
# updates the live tools.
link_bin_tools() {
  [ -d "$DOTFILES_DIR/bin" ] || { skip "no bin/ in this checkout"; return 0; }
  local f
  for f in "$DOTFILES_DIR"/bin/*; do
    [ -f "$f" ] || continue
    chmod +x "$f"
    link_file "$f" "$HOME/.local/bin/$(basename "$f")"
  done
  return 0
}

# Claude Code hooks. The shared profile settings.json references these by
# $HOME path, so a machine that skips this step gets a "No such file or
# directory" error on every hook fire.
link_claude_hooks() {
  [ -d "$DOTFILES_DIR/hooks" ] || { skip "no hooks/ in this checkout"; return 0; }
  local f
  for f in "$DOTFILES_DIR"/hooks/*.sh "$DOTFILES_DIR"/hooks/*.py; do
    [ -f "$f" ] || continue
    # A real hook is <name>.<ext>. A dotted stem (foo.test.sh) is a repo-side
    # helper and must not be installed as a hook.
    case "$(basename "$f")" in *.*.*) continue ;; esac
    link_file "$f" "$CLAUDE_DIR/hooks/$(basename "$f")"
  done
  return 0
}

# Codex custom prompts, typed as /<name> in the Codex TUI.
link_codex_prompts() {
  [ -d "$DOTFILES_DIR/codex/prompts" ] || { skip "no codex/prompts/ in this checkout"; return 0; }
  local f
  for f in "$DOTFILES_DIR"/codex/prompts/*.md; do
    [ -f "$f" ] || continue
    link_file "$f" "$HOME/.codex/prompts/$(basename "$f")"
  done
  return 0
}

link_repo_scripts() {
  [ -d "$DOTFILES_DIR/scripts" ] || { skip "no scripts/ in this checkout"; return 0; }
  local f name
  for f in "$DOTFILES_DIR"/scripts/*.sh; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    link_file "$f" "$CLAUDE_DIR/scripts/$name"
    # Same guard as link_statusline: skip entirely under dry run (chmod is a
    # write link_file never performed), and require the link to actually
    # point at this iteration's source, not merely be a symlink — a stale
    # link left by a failed ln must not get chmod'd through. An `if`, not
    # `&&`, so the iteration's exit status never carries the test's outcome.
    if [ -z "$LINKS_DRY_RUN" ] \
       && [ "$(readlink "$CLAUDE_DIR/scripts/$name" 2>/dev/null)" = "$f" ]; then
      chmod +x "$CLAUDE_DIR/scripts/$name"
    fi
  done
  return 0
}

# The chmod follows the symlink onto the checkout's own file, which is what
# git tracks. Guarded on the link actually pointing at our source — not
# merely existing — so a stale link left in place by a failed ln (e.g.
# EACCES on $CLAUDE_DIR itself) never gets chmod'd through. Also guarded on
# dry run explicitly: chmod is itself a write, and a correct link that
# already existed before this call would satisfy the readlink match even
# though link_file made no change — dry run must not touch the filesystem.
link_statusline() {
  link_file "$DOTFILES_DIR/statusline.sh" "$CLAUDE_DIR/statusline.sh"
  if [ -z "$LINKS_DRY_RUN" ] \
     && [ "$(readlink "$CLAUDE_DIR/statusline.sh" 2>/dev/null)" = "$DOTFILES_DIR/statusline.sh" ]; then
    chmod +x "$CLAUDE_DIR/statusline.sh"
  fi
  return 0
}

# AGENTS.md/GEMINI.md all point at the assembled CLAUDE.md. The guard is
# correct for these four links and gates ONLY them — the hook, bin, and
# codex linkers moved out to relink_all, so hook installation no longer
# depends on a file unrelated to hooks.
link_agent_instructions() {
  local canonical="$CLAUDE_DIR/CLAUDE.md"
  [ -f "$canonical" ] || { warn "CLAUDE.md not found; skipping agent-instruction symlinks"; return 0; }
  link_file "$canonical" "$HOME/.codex/AGENTS.md"
  link_file "$canonical" "$HOME/.config/opencode/AGENTS.md"
  link_file "$canonical" "$HOME/.gemini/GEMINI.md"
  link_file "$canonical" "$HOME/AGENTS.md"
  return 0
}
