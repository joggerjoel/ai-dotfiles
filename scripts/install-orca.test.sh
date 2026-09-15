#!/usr/bin/env bash
# Tests for scripts/install-orca.sh and setup.sh's ensure_orca wrapper. Dotted
# stem on purpose: link_claude_hooks() excludes *.*.* files, so this never
# installs as a live hook.
#
# Orca is a macOS-only Homebrew cask marked auto_updates, and every invariant
# here is one that a plain `brew install --cask` got wrong on a real host:
#   1. Off macOS or off brew it is a report, not an install, and brew is never
#      invoked; setup.sh's wrapper turns that into a skip and continues.
#   2. The tap is trusted BEFORE any install. Homebrew 7 refuses casks from an
#      untrusted third-party tap, so an install that runs first fails on every
#      fresh Mac.
#   3. The app bundle's own version decides the action, never brew's receipt:
#      for an auto_updates cask --adopt records the cask version over ANY
#      existing app (macstudio: a 1.4.188 app adopted as 1.4.203, then never
#      upgraded again). Behind the cask means replace (--force) or reinstall;
#      at or ahead means adopt or leave alone. Ahead is never rolled back.
#   4. --check mutates nothing and exits 1 while an action is pending.
#   5. A failed install exits 1 without claiming success, and setup.sh's
#      wrapper warns and lets the run continue.
#   6. No brew call names the cask by the bare token `orca`: homebrew/cask has
#      an unrelated `orca` (Plotly's chart exporter), so a bare
#      `brew upgrade --cask orca` would swap this IDE for that program.
#   7. The bundled agent skills are installed when any is missing from
#      ~/.agents/skills or when the app moved this run (the guides are
#      version-matched), and not otherwise. A skills failure exits 1 without
#      claiming success.
#
# Stubs are plain scripts that log their argv. Nothing here touches the network.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SCRIPT="$ROOT/scripts/install-orca.sh"
SETUP="$ROOT/setup.sh"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/orca.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/bin" "$TMP/home"
for t in bash sh dirname basename cat cksum mktemp sed grep awk id rm mkdir ln \
         cut sort tr head tail env date chmod find printf; do
  src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$TMP/bin/$t"
done
for leaked in brew orca defaults uname; do
  if [ -e "$TMP/bin/$leaked" ]; then
    printf '  FAIL  sandbox leaked a %s onto PATH\n' "$leaked"
    exit 1
  fi
done

ARGV="$TMP/brew.argv"
APP="$TMP/Orca.app"
CASK_VER="1.4.203"

# <os name> — uname stub, so the suite also runs on a Linux CI box.
make_uname_stub() {
  printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$TMP/bin/uname"
  chmod +x "$TMP/bin/uname"
}

# <app version or ""> — creates or removes the fake app bundle, and a defaults
# stub that reports its version.
set_app() {
  rm -rf "$APP"
  if [ -n "$1" ]; then
    mkdir -p "$APP/Contents"
    printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$TMP/bin/defaults"
  else
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/defaults"
  fi
  chmod +x "$TMP/bin/defaults"
}

# <rc for `list --cask`> <rc for install/reinstall> — brew stub. `info` answers
# with the cask's version line, as the real one does; trust and tap succeed.
make_brew_stub() {
  local list_rc="$1" install_rc="$2"
  cat > "$TMP/bin/brew" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV"
case "\$1" in
  info) echo "==> orca: $CASK_VER (auto_updates)" ;;
  list) exit $list_rc ;;
  install | reinstall) exit $install_rc ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/brew"
}

ORCA_ARGV="$TMP/orca.argv"
SKILLS=(computer-use orca-cli orchestration)

# <rc for `skills install`> — orca stub. `skills list --json` names the bundled
# set; `skills install --all` logs and, on success, writes each SKILL.md where
# the real skills CLI would.
make_orca_stub() {
  local install_rc="$1"
  cat > "$TMP/bin/orca" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ORCA_ARGV"
case "\$*" in
  --version) echo "$CASK_VER" ;;
  "skills list --json") printf '{"topics":[{"name":"computer-use"},{"name":"orca-cli"},{"name":"orchestration"}]}\n' ;;
  "skills install --all")
    [ $install_rc -eq 0 ] || exit $install_rc
    for n in ${SKILLS[*]}; do mkdir -p "$TMP/home/.agents/skills/\$n"; : > "$TMP/home/.agents/skills/\$n/SKILL.md"; done ;;
esac
exit 0
STUB
  chmod +x "$TMP/bin/orca"
}

# present | missing | partial — the skill dirs under the sandbox HOME.
set_skills() {
  rm -rf "$TMP/home/.agents/skills"
  case "$1" in
    present) for n in "${SKILLS[@]}"; do mkdir -p "$TMP/home/.agents/skills/$n"; : > "$TMP/home/.agents/skills/$n/SKILL.md"; done ;;
    partial) mkdir -p "$TMP/home/.agents/skills/orca-cli"; : > "$TMP/home/.agents/skills/orca-cli/SKILL.md" ;;
  esac
}

skills_installed_count() { grep -c -- '^skills install --all$' "$ORCA_ARGV" || true; }

run_script() {
  : > "$ARGV"; : > "$ORCA_ARGV"
  PATH="$TMP/bin" HOME="$TMP/home" ORCA_APP="$APP" bash "$SCRIPT" "$@" 2>&1
}

# <label> <expected brew verb line> — the mutating call the script must make.
expect_call() {
  if grep -qx -- "$2" "$ARGV"; then
    ok "$1"
  else
    ko "$1" "argv log: [$(tr '\n' '|' < "$ARGV")]"
  fi
}
expect_no_mutation() {
  if grep -qE '^(install|reinstall|upgrade)' "$ARGV"; then
    ko "$1" "argv log: [$(tr '\n' '|' < "$ARGV")]"
  else
    ok "$1"
  fi
}

# --- 1. not macOS: report, exit 1, never call brew -------------------------
make_uname_stub Linux; make_brew_stub 1 0; set_app ""
got=$(run_script); rc=$?
[ "$rc" -ne 0 ] && ok "off macOS the script exits non-zero" || ko "off macOS the script exits non-zero" "rc=$rc, output: [$got]"
[ -s "$ARGV" ] && ko "off macOS the script never invokes brew" "argv log: [$(tr '\n' '|' < "$ARGV")]" || ok "off macOS the script never invokes brew"
make_uname_stub Darwin
make_orca_stub 0; set_skills present

# --- 2. fresh Mac: plain install, tap trusted first -------------------------
make_brew_stub 1 0; set_app ""
got=$(run_script); rc=$?
expect_call "fresh install runs a plain cask install" "install --cask stablyai/orca/orca"
trust_line=$(grep -n '^trust --tap stablyai/orca$' "$ARGV" | cut -d: -f1 | head -1)
install_line=$(grep -nE '^(install|reinstall)' "$ARGV" | cut -d: -f1 | head -1)
if [ -n "$trust_line" ] && [ -n "$install_line" ] && [ "$trust_line" -lt "$install_line" ]; then
  ok "the tap is trusted before the install"
else
  ko "the tap is trusted before the install" "argv log: [$(tr '\n' '|' < "$ARGV")]"
fi
case "$got" in *"orca installed"*) ok "fresh install says installed" ;; *) ko "fresh install says installed" "output: [$got]" ;; esac

# --- 3. app at the cask version, not brew-managed: adopt --------------------
make_brew_stub 1 0; set_app "$CASK_VER"
got=$(run_script)
expect_call "matching hand-installed app is adopted" "install --adopt --cask stablyai/orca/orca"

# --- 4. app behind the cask, not brew-managed: force, never adopt -----------
make_brew_stub 1 0; set_app "1.4.188"
got=$(run_script)
expect_call "stale hand-installed app is replaced with --force" "install --force --cask stablyai/orca/orca"
grep -q -- '--adopt' "$ARGV" && ko "stale app is never adopted" "adopt would record the cask version over a 1.4.188 app" || ok "stale app is never adopted"

# --- 5. app behind the cask, brew-managed: reinstall (the receipt lies) -----
make_brew_stub 0 0; set_app "1.4.188"
got=$(run_script)
expect_call "stale brew-managed app is reinstalled" "reinstall --cask stablyai/orca/orca"

# --- 6. app current and brew-managed: nothing ------------------------------
make_brew_stub 0 0; set_app "$CASK_VER"
got=$(run_script); rc=$?
expect_no_mutation "current brew-managed app is left alone"
[ "$rc" -eq 0 ] && ok "current brew-managed app exits 0" || ko "current brew-managed app exits 0" "rc=$rc, output: [$got]"
case "$got" in *"orca current"*) ok "current brew-managed app says current" ;; *) ko "current brew-managed app says current" "output: [$got]" ;; esac

# --- 7. app ahead of the cask: never rolled back ----------------------------
make_brew_stub 0 0; set_app "1.4.250"
got=$(run_script)
expect_no_mutation "brew-managed app ahead of the cask is left alone"
make_brew_stub 1 0; set_app "1.4.250"
got=$(run_script)
expect_call "hand-installed app ahead of the cask is adopted, not replaced" "install --adopt --cask stablyai/orca/orca"

# --- 8. --check: no mutation, exit 1 while an action is pending -------------
make_brew_stub 1 0; set_app "1.4.188"
got=$(run_script --check); rc=$?
expect_no_mutation "--check installs nothing"
[ "$rc" -ne 0 ] && ok "--check exits non-zero with an action pending" || ko "--check exits non-zero with an action pending" "rc=$rc"
case "$got" in *"would run: brew install --force"*) ok "--check names the pending action" ;; *) ko "--check names the pending action" "output: [$got]" ;; esac
make_brew_stub 0 0; set_app "$CASK_VER"
run_script --check >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "--check exits 0 when current" || ko "--check exits 0 when current" "rc=$rc"

# --- 9. install fails: exit 1, no claim of success --------------------------
make_brew_stub 1 1; set_app ""
got=$(run_script); rc=$?
[ "$rc" -ne 0 ] && ok "a failed install exits non-zero" || ko "a failed install exits non-zero" "rc=$rc"
case "$got" in *"install failed"*) ok "a failed install says so" ;; *) ko "a failed install says so" "output: [$got]" ;; esac
case "$got" in *"orca installed"*) ko "a failed install does not claim success" "output: [$got]" ;; *) ok "a failed install does not claim success" ;; esac

# --- 10. no bare `orca` token, in the script or the update roster ----------
if grep -qE 'brew (install|reinstall|upgrade|list|info)[^|]* orca([ ";]|$)' "$SCRIPT" "$ROOT/scripts/agents-update.sh"; then
  ko "no brew call names the cask by the bare token" \
     "$(grep -nE 'brew (install|reinstall|upgrade|list|info)[^|]* orca([ ";]|$)' "$SCRIPT" "$ROOT/scripts/agents-update.sh")"
else
  ok "no brew call names the cask by the bare token"
fi

# --- 12. skills: installed when missing or when the app moved, else left ---
make_brew_stub 0 0; set_app "$CASK_VER"; set_skills present
got=$(run_script); rc=$?
[ "$(skills_installed_count)" = "0" ] && ok "current app with all skills present installs no skills" || ko "current app with all skills present installs no skills" "orca argv: [$(tr '\n' '|' < "$ORCA_ARGV")]"
case "$got" in *"skills current"*) ok "current app with all skills present says skills current" ;; *) ko "current app with all skills present says skills current" "output: [$got]" ;; esac

make_brew_stub 0 0; set_app "$CASK_VER"; set_skills partial
got=$(run_script); rc=$?
[ "$(skills_installed_count)" = "1" ] && ok "a missing skill triggers 'skills install --all' exactly once" || ko "a missing skill triggers 'skills install --all' exactly once" "orca argv: [$(tr '\n' '|' < "$ORCA_ARGV")]"
[ "$rc" -eq 0 ] && ok "skills install on a current app exits 0" || ko "skills install on a current app exits 0" "rc=$rc, output: [$got]"
[ -f "$TMP/home/.agents/skills/orchestration/SKILL.md" ] && ok "the skills CLI stub landed the missing skill" || ko "the skills CLI stub landed the missing skill"

make_brew_stub 0 0; set_app "1.4.188"; set_skills present
got=$(run_script)
[ "$(skills_installed_count)" = "1" ] && ok "an app that moved refreshes the version-matched skills" || ko "an app that moved refreshes the version-matched skills" "orca argv: [$(tr '\n' '|' < "$ORCA_ARGV")]"

make_brew_stub 0 0; set_app "$CASK_VER"; set_skills missing
got=$(run_script --check); rc=$?
[ "$(skills_installed_count)" = "0" ] && ok "--check installs no skills" || ko "--check installs no skills"
[ "$rc" -ne 0 ] && ok "--check exits non-zero with skills missing" || ko "--check exits non-zero with skills missing" "rc=$rc"
case "$got" in *"skills missing:"*) ok "--check names the missing skills" ;; *) ko "--check names the missing skills" "output: [$got]" ;; esac

make_orca_stub 1; make_brew_stub 0 0; set_app "$CASK_VER"; set_skills missing
got=$(run_script); rc=$?
[ "$rc" -ne 0 ] && ok "a failed skills install exits non-zero" || ko "a failed skills install exits non-zero" "rc=$rc"
case "$got" in *"skills install failed"*) ok "a failed skills install says so" ;; *) ko "a failed skills install says so" "output: [$got]" ;; esac
make_orca_stub 0; set_skills present

# --- 11. setup.sh's ensure_orca: skip off brew, wrap the script on brew -----
DISPATCH=$(grep -n '^case "${1:-}" in' "$SETUP" | cut -d: -f1)
if [ -z "$DISPATCH" ]; then
  ko "locate the setup.sh dispatch case" "test needs updating"
else
  sed -n "1,$((DISPATCH - 1))p" "$SETUP" > "$TMP/defs.sh"
  run_setup() {
    PATH="$TMP/bin" HOME="$TMP/home" SUDO="" ORCA_APP="$APP" bash -c "
      set -euo pipefail
      source '$TMP/defs.sh' >/dev/null 2>&1
      PKG_MANAGER='$1'
      DOTFILES_DIR='$ROOT'
      ensure_orca; printf 'REACHED_END'
    " 2>&1
  }
  make_brew_stub 1 0; set_app ""; : > "$ARGV"
  got=$(run_setup apt)
  case "$got" in *REACHED_END*) ok "ensure_orca off brew does not abort the run" ;; *) ko "ensure_orca off brew does not abort the run" "output: [$got]" ;; esac
  [ -s "$ARGV" ] && ko "ensure_orca off brew never invokes brew" "argv log: [$(tr '\n' '|' < "$ARGV")]" || ok "ensure_orca off brew never invokes brew"

  make_brew_stub 1 1; set_app ""
  got=$(run_setup brew)
  case "$got" in *REACHED_END*) ok "ensure_orca survives a failed install under set -e" ;; *) ko "ensure_orca survives a failed install under set -e" "output: [$got]" ;; esac
  case "$got" in *"install failed"*) ok "ensure_orca surfaces the script's failure" ;; *) ko "ensure_orca surfaces the script's failure" "output: [$got]" ;; esac

  make_brew_stub 1 0; set_app "$CASK_VER"
  got=$(run_setup brew)
  expect_call "ensure_orca on brew runs the converge script" "install --adopt --cask stablyai/orca/orca"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
