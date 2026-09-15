#!/usr/bin/env bash
# Tests for scripts/observability-tools.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# uv_install_cmd is pure, so the whole suite runs against a fake pyenv on PATH.
# Nothing clones, nothing builds, nothing reaches the network.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=observability-tools.sh
. "$ROOT/scripts/observability-tools.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/obstools.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ (${2})}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

# A fake pyenv, so every assertion below is about this script's choice rather
# than about whatever interpreters this particular machine happens to carry.
fake_pyenv() {
  local dir="$TMP/$1" global="$2" versions="$3"
  mkdir -p "$dir"
  cat >"$dir/pyenv" <<EOF
#!/bin/sh
case "\$1" in
  global)   printf '%s\n' '$global' ;;
  versions) printf '%s\n' '$versions' ;;
esac
EOF
  chmod +x "$dir/pyenv"
  printf '%s\n' "$dir"
}

BARE="$TMP/bare"
mkdir -p "$BARE"

with_path() { PATH="$1" "${@:2}"; }

# --- pyenv present -----------------------------------------------------------
# The command that actually works on a pyenv machine. claude-tap's
# .python-version asks for a 3.13 that is not installed, so an unpinned `uv`
# dies in the shim before uv itself runs.

dir=$(fake_pyenv withpyenv "3.11.8" "3.10.4
3.11.8
3.11.12")
got=$(with_path "$dir:/usr/bin:/bin" uv_install_cmd | tr '\n' ' ')
eq "a pyenv machine pins the interpreter the shim will accept" \
   "env PYENV_VERSION=3.11.8 uv tool install --python 3.11 --editable . --reinstall " "$got"

# --- pyenv absent ------------------------------------------------------------
# No shim to get past, so pinning a version this machine never configured would
# invent a constraint rather than remove one.

got=$(with_path "$BARE:/usr/bin:/bin" uv_install_cmd | tr '\n' ' ')
eq "a machine without pyenv uses plain uv" \
   "uv tool install --editable . --reinstall " "$got"

# --- pyenv global names an uninstalled version -------------------------------
# This is the exact state that produces the shim failure. Trusting `pyenv
# global` blindly would pin PYENV_VERSION to a 3.13 that does not exist and
# reproduce the bug the pin was added to fix.

dir=$(fake_pyenv stale "3.13.1" "3.10.4
3.11.8")
got=$(with_path "$dir:/usr/bin:/bin" uv_install_cmd | tr '\n' ' ')
eq "a configured version that is not installed is not used" \
   "env PYENV_VERSION=3.11.8 uv tool install --python 3.11 --editable . --reinstall " "$got"

# --- pyenv with no python 3 at all -------------------------------------------
# Falling back to plain uv is right here: there is nothing to pin to, and a
# pin to an empty string would break every invocation.

dir=$(fake_pyenv empty2 "2.7.18" "2.7.18")
got=$(with_path "$dir:/usr/bin:/bin" uv_install_cmd | tr '\n' ' ')
eq "a pyenv with no python 3 falls back to plain uv" \
   "uv tool install --editable . --reinstall " "$got"

# --- the minor version passed to --python ------------------------------------
# uv wants a minor like 3.12, not the patch level. Passing the patch pins uv to
# a build it may not be able to resolve.

dir=$(fake_pyenv minor "3.12.7" "3.12.7")
got=$(with_path "$dir:/usr/bin:/bin" uv_install_cmd | grep -A1 -- '--python' | tail -1)
eq "--python takes the minor version, not the patch" "3.12" "$got"

# --- the argv is a list, not a string ----------------------------------------
# The installer expands it into an array. One line per element is what makes a
# path with a space in it survive.

dir=$(fake_pyenv lines "3.11.8" "3.11.8")
got=$(with_path "$dir:/usr/bin:/bin" uv_install_cmd | wc -l | tr -d ' ')
eq "the pyenv argv is ten elements on ten lines" "10" "$got"

# --- the install is idempotent by construction -------------------------------
# --reinstall is what makes a second run converge instead of failing on "tool
# already installed", and --editable is what makes the checkout the install.
for flag in --reinstall --editable; do
  if uv_install_cmd | grep -qx -- "$flag"; then
    ok "the uv command carries $flag"
  else
    ko "the uv command carries $flag"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
