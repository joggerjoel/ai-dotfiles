#!/usr/bin/env bash
# Tests for setup.sh's dependency guards on the `update` path. Dotted stem on
# purpose: link_claude_hooks() excludes *.*.* files, so this never installs as
# a live hook.
#
# The bug these guard against took the whole fleet down in one run. `setup.sh
# update` never called detect_pkg_manager, so PKG_MANAGER stayed "" — a third
# state that neither ensure_zsh's `= "unknown"` guard nor pkg_install's case
# expected. pkg_install fell through to its `*)` catch-all and returned 1
# WITHOUT EVER RUNNING apt, and because that call sat unguarded on its own line,
# `set -euo pipefail` killed the script before the `|| fail` on the next line
# could run. Six hosts died at "zsh missing — installing..." with no apt output
# at all, having applied no config, and the ansible recap only said `failed=1`.
#
# Two invariants keep that from recurring:
#   1. the update path detects a package manager before it installs anything
#   2. a failed OPTIONAL dependency warns and lets the update continue; only
#      the script's own prerequisites are fatal (setup.sh's header contract)

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SETUP="$ROOT/setup.sh"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/setupupd.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# setup.sh dispatches on "$1" at the very bottom; everything above is
# definitions, so sourcing that prefix gets the functions without running one.
DISPATCH=$(grep -n '^case "${1:-}" in' "$SETUP" | cut -d: -f1)
if [ -z "$DISPATCH" ]; then
  printf '  FAIL  cannot locate the setup.sh dispatch case — test needs updating\n'
  exit 1
fi
sed -n "1,$((DISPATCH - 1))p" "$SETUP" > "$TMP/defs.sh"

# A PATH with no zsh on it. Can't just strip PATH: sourcing the definitions runs
# `dirname` for DOTFILES_DIR. Can't stub zsh as a shell function either —
# `command -v` finds functions, which is the opposite of absent. So: a bin dir
# holding symlinks to what the definitions need, and deliberately no zsh.
mkdir -p "$TMP/bin"
for t in bash sh dirname basename cat cksum mktemp sed grep awk uname id rm \
         mkdir ln cut sort tr head tail env date chmod find; do
  src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$TMP/bin/$t"
done
if command -v zsh >/dev/null 2>&1 && [ -e "$TMP/bin/zsh" ]; then
  printf '  FAIL  sandbox leaked a zsh onto PATH\n'
  exit 1
fi

# Run a snippet against setup.sh's definitions with zsh absent. `set -euo
# pipefail` is ON deliberately: the regression is an ABORT, not a wrong value,
# so the assertion is "did the snippet reach its last line".
run_without_zsh() {
  PATH="$TMP/bin" HOME="$TMP/home" bash -c "
    set -euo pipefail
    source '$TMP/defs.sh' >/dev/null 2>&1
    $1
  " 2>&1
}

# --- 1. the update path must detect a package manager ----------------------
# The root cause. detect_pkg_manager lived only inside ensure_dependencies,
# which cmd_update never calls, so every install on the update path ran against
# an empty PKG_MANAGER. Scoped to cmd_update's own body: a call anywhere else in
# the file is exactly the arrangement that broke.
body=$(awk '/^cmd_update\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SETUP")
if printf '%s' "$body" | grep -q 'detect_pkg_manager'; then
  ok "cmd_update detects a package manager before installing anything"
else
  ko "cmd_update detects a package manager before installing anything" \
     "no detect_pkg_manager call in cmd_update's body"
fi

# --- 2. detect_pkg_manager never leaves the sentinel unset ------------------
# "" and "unknown" mean the same thing to a human and different things to
# `[ "$PKG_MANAGER" = "unknown" ]`. Only one of them may ever escape.
got=$(run_without_zsh 'detect_pkg_manager; printf "%s" "${PKG_MANAGER:-EMPTY}"')
case "$got" in
  apt|brew|unknown) ok "detect_pkg_manager always sets a known sentinel" ;;
  *) ko "detect_pkg_manager always sets a known sentinel" "got [$got]" ;;
esac

# --- 3. ensure_zsh must not abort the update when zsh cannot be installed ---
# The exact fleet failure: PKG_MANAGER empty, zsh absent, set -e armed.
#
# Every ensure_zsh below is called BARE, never `ensure_zsh || true`. Bash
# disables errexit for a whole function body when the function is invoked in a
# tested context (`if`, `&&`, `||`, `!`) — so the `|| true` spelling suppresses
# the abort this test exists to catch, and passes against the broken code.
got=$(run_without_zsh 'PKG_MANAGER=""; ensure_zsh; printf "REACHED_END"')
case "$got" in
  *REACHED_END*) ok "ensure_zsh with an empty PKG_MANAGER does not abort the run" ;;
  *) ko "ensure_zsh with an empty PKG_MANAGER does not abort the run" \
        "run died early, output: [$got]" ;;
esac

got=$(run_without_zsh 'PKG_MANAGER="unknown"; ensure_zsh; printf "REACHED_END"')
case "$got" in
  *REACHED_END*) ok "ensure_zsh with an unknown PKG_MANAGER does not abort the run" ;;
  *) ko "ensure_zsh with an unknown PKG_MANAGER does not abort the run" \
        "run died early, output: [$got]" ;;
esac

# --- 4. ensure_zsh must not claim a success it did not have ----------------
# A host that silently "installed" a zsh it does not have is worse than a loud
# skip: the recap goes green and the shell config is a fiction.
got=$(run_without_zsh 'PKG_MANAGER=""; ensure_zsh')
case "$got" in
  *"zsh installed"*) ko "ensure_zsh does not report installing a zsh it lacks" \
                        "claimed success with no package manager" ;;
  *) ok "ensure_zsh does not report installing a zsh it lacks" ;;
esac

# --- 5. an unavailable zsh must not take the config update with it ---------
# install_zsh_modules is called from cmd_update AFTER the git pull but BEFORE
# nothing — it is late in the run, and aborting there still stranded the host.
# Optional shell tooling is not a prerequisite; the update has to survive it.
got=$(run_without_zsh 'PKG_MANAGER=""; install_zsh_modules; printf "REACHED_END"')
case "$got" in
  *REACHED_END*) ok "install_zsh_modules survives an unavailable zsh" ;;
  *) ko "install_zsh_modules survives an unavailable zsh" \
        "run died early, output: [$got]" ;;
esac

# --- 6. pkg_install's silent catch-all is guarded at every call site --------
# `*) return 1` is correct but mute — it is indistinguishable from a real apt
# failure. Every caller must therefore handle it ON THE SAME LINE, because a
# handler on the following line is dead code under `set -e`.
# Join backslash-continued lines first: `pkg_install x && ok ... \` with the
# `|| fail` on the next physical line is correctly guarded, and reading the
# lines separately reports it as a bug.
unguarded=$(awk '{ line = line $0
                   if (sub(/\\$/, "", line)) next
                   n++
                   if (line ~ /(^|;|&&|\|\||then|else|do)[[:space:]]*pkg_install[[:space:]]/ \
                       && line !~ /\|\|/ && line !~ /^[[:space:]]*#/)
                     printf "%d:%s ", NR, line
                   line = "" }' "$SETUP")
if [ -z "$unguarded" ]; then
  ok "every pkg_install call handles failure on its own line"
else
  ko "every pkg_install call handles failure on its own line" \
     "unguarded under set -e: $(printf '%s' "$unguarded" | tr '\n' ' ')"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
