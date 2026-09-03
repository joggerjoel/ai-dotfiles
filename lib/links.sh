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

# Assigned, not defaulted: ${VAR:-0} does not stop an exported value leaking
# in — `LINK_CHANGED=7 bash -c 'echo ${LINK_CHANGED:-0}'` prints 7.
#
# Extracted so a caller can zero the counters right after sourcing this file,
# before calling link_file directly (e.g. install_settings) — link_file
# always increments one of these on every call, and under `set -u` an unset
# counter is fatal. relink_all also calls this itself, so each relink_all run
# starts from zero regardless of what ran before it in the same shell.
links_reset_counters() {
  LINK_CHANGED=0
  LINK_OK=0
  LINK_SKIPPED=0
  LINK_FAILED=0
}

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

# Remove dangling symlinks in <dir> whose target is inside this checkout. A
# source retired from the repo (scripts/herdr-*.sh and bin/herdr-new-project
# left with the herdr extraction) otherwise stays behind as a dangling link on
# every host, forever — the linkers only ever add. Only links that point INTO
# this repo are ours to remove; a dangling link the user made elsewhere is not
# our business. Same rule install_skills applies through its manifest.
# Dry-run aware, and counted as a change so the relink_all summary reflects
# it. Always returns 0, like link_file.
prune_dangling_links() {
  local dir="$1" f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -L "$f" ] || continue
    case "$(readlink "$f")" in
      "$DOTFILES_DIR"/*) ;;
      *) continue ;;
    esac
    [ -e "$f" ] && continue
    if [ -n "$LINKS_DRY_RUN" ]; then
      ok "$(basename "$f") — would prune dangling link (dry run)"
    else
      rm -f "$f" && ok "$(basename "$f") — pruned dangling link"
    fi
    LINK_CHANGED=$(( LINK_CHANGED + 1 ))
  done
  return 0
}

# Repo CLI helpers (bin/* -> ~/.local/bin/<name>). Symlinked so a repo pull
# updates the live tools. Pruning of retired tools happens in relink_all,
# through prune_dangling_links, not here.
link_bin_tools() {
  [ -d "$DOTFILES_DIR/bin" ] || { skip "no bin/ in this checkout"; return 0; }
  local f
  for f in "$DOTFILES_DIR"/bin/*; do
    [ -f "$f" ] || continue
    # Below the dry-run check, not above it: this chmod writes to the repo's
    # own file (git tracks the mode bit), so a dry run must not touch it.
    # `|| true`: unlike link_file, a bare chmod can return non-zero (e.g. a
    # read-only or root-owned bin/*), and under `set -u`+`set -e` in the
    # caller that would abort update.sh mid-run — a failure mode it never had
    # before this file existed.
    if [ -z "$LINKS_DRY_RUN" ]; then
      chmod +x "$f" 2>/dev/null || true
    fi
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
    # A real script is <name>.sh. A dotted stem (foo.test.sh) is a repo-side
    # test helper and must not deploy fleet-wide. Same filter as link_claude_hooks.
    case "$name" in *.*.*) continue ;; esac
    link_file "$f" "$CLAUDE_DIR/scripts/$name"
    # Same guard as link_statusline: skip entirely under dry run (chmod is a
    # write link_file never performed), and require the link to actually
    # point at this iteration's source, not merely be a symlink — a stale
    # link left by a failed ln must not get chmod'd through. An `if`, not
    # `&&`, so the iteration's exit status never carries the test's outcome.
    if [ -z "$LINKS_DRY_RUN" ] \
       && [ "$(readlink "$CLAUDE_DIR/scripts/$name" 2>/dev/null)" = "$f" ]; then
      # `|| true`: chmod, unlike link_file, can return non-zero (e.g. EACCES
      # on a read-only $CLAUDE_DIR/scripts) and must not abort the caller.
      chmod +x "$CLAUDE_DIR/scripts/$name" 2>/dev/null || true
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
    # `|| true`: chmod, unlike link_file, can return non-zero (e.g. EACCES
    # on a read-only $CLAUDE_DIR) and must not abort the caller.
    chmod +x "$CLAUDE_DIR/statusline.sh" 2>/dev/null || true
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

# The single entry point. Every call site calls this and nothing else.
#
# link_agent_instructions runs INSIDE this function rather than before it: if
# it ran first, its link_file failures would increment LINK_FAILED and then be
# erased by the reset below, so a failed AGENTS.md link would print under
# "0 failed". Inside, every link is counted once and update.sh gains the
# ability to repair those four links, which it otherwise could not reach.
relink_all() {
  : "${DOTFILES_DIR:?relink_all requires DOTFILES_DIR}"
  : "${CLAUDE_DIR:?relink_all requires CLAUDE_DIR}"

  links_reset_counters

  # Prune before linking, so a retired source's stale link never survives a
  # run — and so the prune lands in the same summary as the links.
  prune_dangling_links "$CLAUDE_DIR/scripts"
  prune_dangling_links "$CLAUDE_DIR/hooks"
  prune_dangling_links "$HOME/.local/bin"
  prune_dangling_links "$HOME/.codex/prompts"

  link_statusline
  link_repo_scripts
  link_claude_hooks
  link_bin_tools
  link_codex_prompts
  link_agent_instructions

  local summary
  summary="$LINK_CHANGED changed, $LINK_OK verified, $LINK_SKIPPED skipped, $LINK_FAILED failed"
  # `if`, not `&&`: with `&&` this would be the last statement executed
  # whenever LINKS_DRY_RUN is unset, so the function's implicit return would
  # carry the failed test's exit status and kill the caller under `set -e`.
  if [ -n "$LINKS_DRY_RUN" ]; then
    summary="$summary  (dry run)"
  fi
  if [ "$LINK_CHANGED" -gt 0 ] || [ "$LINK_FAILED" -gt 0 ]; then
    warn "$summary"
  else
    ok "$summary"
  fi
  return 0
}
