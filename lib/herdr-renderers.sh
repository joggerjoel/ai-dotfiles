#!/bin/bash
# apt install path for the herdr-file-viewer renderers, shared by setup.sh and
# update.sh. Sourced, never executed. Callers provide ok/warn and $SUDO.
#
# One `apt-get install bat git-delta glow` is all-or-nothing: Ubuntu 22.04 has
# no git-delta package, so the whole call failed and bat was never installed
# either. Each package is therefore checked for an apt candidate first; the
# ones apt has go in a single install, and the rest get their own fallback.

# True when apt can install the package from a configured source.
_apt_has_candidate() {
  apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [^(]'
}

# delta's release binary into ~/.local/bin: no root, and the static musl build
# does not care how old the host's glibc is.
_install_delta_release() {
  local arch tag url tmp
  case "$(uname -m)" in
    x86_64) arch="x86_64-unknown-linux-musl" ;;
    aarch64 | arm64) arch="aarch64-unknown-linux-gnu" ;;
    *) return 1 ;;
  esac
  tag=$(curl -fsSI -m 15 -o /dev/null -w '%{redirect_url}' \
    https://github.com/dandavison/delta/releases/latest) || return 1
  tag="${tag##*/}"
  [ -n "$tag" ] || return 1
  url="https://github.com/dandavison/delta/releases/download/${tag}/delta-${tag}-${arch}.tar.gz"
  tmp=$(mktemp -d) || return 1
  if curl -fsSL -m 60 "$url" | tar -xz -C "$tmp" --strip-components=1 2>/dev/null \
    && [ -x "$tmp/delta" ]; then
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$tmp/delta" "$HOME/.local/bin/delta"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

herdr_apt_install_renderers() {
  local pkg wanted="" from_apt="" no_candidate=""
  command -v batcat &>/dev/null || command -v bat &>/dev/null || wanted="$wanted bat"
  command -v delta &>/dev/null || wanted="$wanted git-delta"
  command -v glow &>/dev/null || wanted="$wanted glow"

  if [ -z "$wanted" ]; then
    ok "herdr renderers present (bat/batcat, delta, glow)"
  else
    $SUDO apt-get update -y >/dev/null 2>&1 || true
    for pkg in $wanted; do
      if _apt_has_candidate "$pkg"; then
        from_apt="$from_apt $pkg"
      else
        no_candidate="$no_candidate $pkg"
      fi
    done

    if [ -n "$from_apt" ]; then
      # shellcheck disable=SC2086
      if $SUDO apt-get install -y $from_apt >/dev/null 2>&1; then
        ok "herdr renderers installed —${from_apt}"
      else
        warn "renderer install failed — apt-get install${from_apt} (non-fatal)"
      fi
    fi

    for pkg in $no_candidate; do
      case "$pkg" in
        git-delta)
          if _install_delta_release; then
            ok "delta installed to ~/.local/bin (apt has no git-delta on this release)"
          else
            warn "delta not installed — no apt package and the release download failed (non-fatal)"
          fi
          ;;
        glow) warn "glow absent — run setup.sh to add Charm's apt repo" ;;
        *) warn "${pkg} has no apt package on this release (non-fatal)" ;;
      esac
    done
  fi

  # Debian's binary is batcat; the viewer calls `bat`. Shim it, no sudo needed.
  if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat" \
      && ok "linked batcat → ~/.local/bin/bat (viewer invokes it as 'bat')"
  fi
}
