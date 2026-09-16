#!/bin/bash
# Shared by the scripts that keep a third-party source checkout current under
# AI_3RDPARTY_ROOT. Sourced, never executed. The caller defines ok() and warn().

clone_or_pull() {
  local url="$1" dir="$2" name="$3"
  if [ -d "$dir/.git" ]; then
    # --ff-only so a checkout someone is working in fails loudly instead of
    # being merged or rewritten under them.
    if git -C "$dir" pull --ff-only --quiet; then
      ok "$name up to date at $(git -C "$dir" rev-parse --short HEAD)"
    else
      warn "$name could not fast-forward; leaving $(git -C "$dir" rev-parse --short HEAD) alone"
    fi
  else
    mkdir -p "$(dirname "$dir")"
    git clone --quiet "$url" "$dir"
    ok "$name cloned to $dir"
  fi
}
