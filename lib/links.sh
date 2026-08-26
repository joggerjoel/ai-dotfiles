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
