#!/bin/bash
# herdr-sign.sh — sign the herdr binary with the stable self-signed "herdr-local"
# identity, so macOS keeps herdr's Local Network grant across herdr updates.
#
# macOS attributes every shell in a herdr pane to the herdr server, so Local
# Network privacy checks herdr's code identity, not nc's or ssh's. Release
# binaries are ad-hoc and linker-signed with a per-build identifier
# (herdr-<hash>), so to macOS each update is a new app: the grant lapses and
# every LAN connect from a pane fails with "No route to host" while routes and
# ARP look fine. A fixed identifier plus a fixed certificate gives a designated
# requirement that survives rebuilds, so the grant is given once.
#
# Run after every herdr update (update.sh does). Idempotent: a binary already
# signed as dev.herdr.herdr by herdr-local is left alone. The first run creates
# the herdr-local identity in the login keychain; it stays untrusted
# (CSSMERR_TP_NOT_TRUSTED), which codesign accepts.
#
# A running server keeps the old image until restarted. --restart kickstarts
# dev.herdr.node, which closes every pane, including the one running this.
# After the first signing, allow herdr under System Settings > Privacy &
# Security > Local Network (or accept the prompt on the first LAN connect).
#
# Usage: herdr-sign.sh [--restart]
# Exits 0 when signed, already current, or skipped; 1 on failure. A host that
# is not macOS, or has no herdr, is a skip. HERDR_BIN overrides the binary.

set -uo pipefail

IDENTITY="herdr-local"
SIGN_ID="dev.herdr.herdr"
SERVICE="dev.herdr.node"

if [ -t 1 ]; then
  GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  GREEN=""; YELLOW=""; RED=""; DIM=""; RESET=""
fi
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
skip() { printf '  %s○ %s%s\n' "$DIM" "$1" "$RESET"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }

restart=no
case "${1:-}" in
  "") ;;
  --restart) restart=yes ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 1 ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
  skip "not macOS — herdr signing skipped"
  exit 0
fi

bin="${HERDR_BIN:-$(command -v herdr 2>/dev/null)}"
if [ -z "$bin" ] || [ ! -e "$bin" ]; then
  skip "herdr not installed — signing skipped"
  exit 0
fi
# Sign the real file: a brew install puts a symlink on PATH.
bin="$(readlink -f "$bin")"

is_signed() { # <file>
  local info
  info="$(codesign -dv --verbose=2 "$1" 2>&1)" || return 1
  printf '%s\n' "$info" | grep -qx "Identifier=$SIGN_ID" \
    && printf '%s\n' "$info" | grep -qx "Authority=$IDENTITY"
}

# Self-signed leaf with only the codeSigning EKU. /usr/bin/openssl is LibreSSL,
# whose PKCS#12 output `security import` reads without OpenSSL 3's -legacy.
ensure_identity() {
  security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" && return 0
  local d rc=0
  d="$(mktemp -d "${TMPDIR:-/tmp}/herdr-sign.XXXXXX")" || return 1
  cat > "$d/c.cnf" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$IDENTITY
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$d/c.cnf" \
      -keyout "$d/k.pem" -out "$d/c.pem" >/dev/null 2>&1 \
    && /usr/bin/openssl pkcs12 -export -inkey "$d/k.pem" -in "$d/c.pem" \
      -name "$IDENTITY" -out "$d/h.p12" -passout pass:herdr-sign >/dev/null 2>&1 \
    && security import "$d/h.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
      -P herdr-sign -T /usr/bin/codesign >/dev/null 2>&1 \
    || rc=1
  rm -rf "$d"
  [ "$rc" -eq 0 ] && ok "created code-signing identity $IDENTITY in the login keychain"
  return "$rc"
}

# codesign needs the private key, so the login keychain must be unlocked. A
# server restarted by launchctl can hand its panes a locked keychain, and there
# codesign fails with errSecInternalComponent instead of prompting.
ensure_unlocked() {
  local kc="$HOME/Library/Keychains/login.keychain-db"
  security show-keychain-info "$kc" >/dev/null 2>&1 && return 0
  if [ -t 0 ]; then
    warn "login keychain is locked — enter your login password to unlock it"
    security unlock-keychain "$kc" && return 0
  fi
  fail "login keychain is locked — run: security unlock-keychain, then re-run"
  return 1
}

if is_signed "$bin"; then
  ok "herdr: already signed as $SIGN_ID by $IDENTITY ($bin)"
else
  ensure_unlocked || exit 1
  if ! ensure_identity; then
    fail "could not create the $IDENTITY identity — run: security find-identity -p codesigning"
    exit 1
  fi
  # Sign a copy and rename it in: rewriting the file a running server has
  # mapped can kill it on its next page-in.
  if ! cp -p "$bin" "$bin.new" \
      || ! codesign -f -s "$IDENTITY" --identifier "$SIGN_ID" "$bin.new" >/dev/null 2>&1 \
      || ! is_signed "$bin.new" \
      || ! mv -f "$bin.new" "$bin"; then
    rm -f "$bin.new"
    fail "herdr: signing failed — $bin left as it was"
    exit 1
  fi
  ok "herdr: signed as $SIGN_ID by $IDENTITY ($bin)"
  [ "$restart" = yes ] || warn "restart the server to load it: $(basename "$0") --restart (closes every pane)"
fi

if [ "$restart" = yes ]; then
  ok "restarting $SERVICE"
  launchctl kickstart -k "gui/$(id -u)/$SERVICE" || { fail "launchctl kickstart $SERVICE failed"; exit 1; }
fi
exit 0
