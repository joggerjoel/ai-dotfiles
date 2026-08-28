#!/usr/bin/env bash
# install-mel.sh — install or update Mel (openmel.dev), the agentic terminal.
#
# Mel ships as a plain archive from S3: no package manager, no version endpoint,
# no release feed. So "is there a newer one?" cannot be answered by asking — the
# only signal is the object's ETag, which we cache. Without that check every
# fleet update would re-pull 27-45 MB per host for a build that had not changed.
#
#   scripts/install-mel.sh            # install, or update if the object changed
#   scripts/install-mel.sh --force    # re-download even when the ETag matches
#   scripts/install-mel.sh --check    # report only; install nothing
#
# MEL_PREFIX overrides the install root (default $HOME) so this can be tested
# without touching a real machine.
#
# Deliberately NOT installing the desktop entry or icons: most hosts here are
# headless, and the vendor's own install.sh assumes an icon set and a desktop
# database. On a workstation, run that script from the unpacked archive instead.
set -uo pipefail

BASE="https://mel-downloads-818872636914.s3.ap-south-1.amazonaws.com"
PREFIX="${MEL_PREFIX:-$HOME}"
BIN_DIR="$PREFIX/.local/bin"
STATE_DIR="$PREFIX/.local/state/ai-dotfiles"
ETAG_FILE="$STATE_DIR/mel.etag"

FORCE=0; CHECK_ONLY=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

die() { echo "install-mel: $*" >&2; exit 1; }

case "$(uname -s)" in
  Darwin) OS=macos;  URL="$BASE/Mel-macos.zip" ;;
  Linux)
    [ "$(uname -m)" = "x86_64" ] || die "no Linux build published for $(uname -m) — x86_64 only"
    OS=linux; URL="$BASE/Mel-linux-x86_64.tar.gz" ;;
  *) die "unsupported OS: $(uname -s)" ;;
esac

command -v curl >/dev/null || die "curl not found"

remote_etag="$(curl -fsSI --max-time 30 "$URL" 2>/dev/null | awk 'tolower($1)=="etag:"{print $2}' | tr -d '\r"')"
[ -n "$remote_etag" ] || die "could not reach $URL"
local_etag="$(cat "$ETAG_FILE" 2>/dev/null || true)"
installed_version="$("$BIN_DIR/mel" --version 2>/dev/null | awk '{print $NF}')"

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "installed : ${installed_version:-none}"
  echo "remote tag: $remote_etag"
  echo "cached tag: ${local_etag:-none}"
  [ "$remote_etag" = "$local_etag" ] && echo "status    : current" || echo "status    : update available"
  exit 0
fi

if [ "$FORCE" -eq 0 ] && [ -n "$local_etag" ] && [ "$remote_etag" = "$local_etag" ] && [ -x "$BIN_DIR/mel" ]; then
  echo "mel ${installed_version:-?} already current (unchanged upstream)"
  exit 0
fi

tmp="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

echo "downloading mel ($OS)…"
curl -fsSL --max-time 300 -o "$tmp/pkg" "$URL" || die "download failed"

mkdir -p "$BIN_DIR" "$STATE_DIR"

if [ "$OS" = linux ]; then
  # The tarball unpacks flat (mel, mel.desktop, install.sh, icons/) — extract
  # into its own directory or it litters the cwd.
  mkdir -p "$tmp/x"
  tar xzf "$tmp/pkg" -C "$tmp/x" || die "extract failed"
  [ -f "$tmp/x/mel" ] || die "archive layout changed: no ./mel at the top level"
  install -m 755 "$tmp/x/mel" "$BIN_DIR/mel" || die "install failed"
else
  command -v unzip >/dev/null || die "unzip not found"
  ( cd "$tmp" && unzip -q pkg ) || die "extract failed"
  [ -d "$tmp/Mel.app" ] || die "archive layout changed: no Mel.app"
  APP_DIR="$PREFIX/Applications"
  mkdir -p "$APP_DIR"
  rm -rf "$APP_DIR/Mel.app"
  cp -R "$tmp/Mel.app" "$APP_DIR/Mel.app" || die "copy failed"
  # The bundle is the app; the symlink is what puts `mel` on PATH beside the
  # other harnesses, so agents-update.sh can see and version it like the rest.
  ln -sfn "$APP_DIR/Mel.app/Contents/MacOS/mel" "$BIN_DIR/mel"
fi

new_version="$("$BIN_DIR/mel" --version 2>/dev/null | awk '{print $NF}')"
[ -n "$new_version" ] || die "installed, but 'mel --version' produced nothing — check $BIN_DIR/mel"
printf '%s' "$remote_etag" > "$ETAG_FILE"

if [ -n "$installed_version" ] && [ "$installed_version" != "$new_version" ]; then
  echo "mel $installed_version -> $new_version"
else
  echo "mel $new_version installed"
fi
