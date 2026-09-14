#!/usr/bin/env bash
# Tests for setup.sh's ensure_firecrawl and ensure_playwright_cli. Dotted stem
# on purpose: link_claude_hooks() excludes *.*.* files, so this never installs
# as a live hook.
#
# Both functions install an npm CLI and then its agent skills, so they share a
# shape and share these invariants. What must hold, and why each matters:
#   1. ensure_firecrawl is OPTIONAL tooling, so a host with no npm and no
#      firecrawl warns and lets setup continue. Under `set -euo pipefail` an
#      unguarded failing command kills the whole run, which is how a missing
#      optional dependency once took six fleet hosts down mid-update.
#   2. It runs `firecrawl init -y --skip-install --skip-auth` exactly once, and
#      probes auth with `credit-usage` exactly once. `--status` exits 0 with a
#      bad key, so using it as the probe would report every host authenticated.
#   3. A failing probe is a report, not an error: setup.sh must never try to log
#      in (firecrawl login needs a browser no fleet host has).
#   4. Every playwright-cli install call carries --global. Without it the CLI
#      initialises the CURRENT DIRECTORY as a workspace, so a setup run inside a
#      repo would drop .playwright/ and .claude/skills/ into that repo.
#
# Stubs are plain scripts that log their argv. Nothing here touches the network.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SETUP="$ROOT/setup.sh"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/setupfc.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# setup.sh dispatches on "$1" at the very bottom; everything above is
# definitions, so sourcing that prefix gets the functions without running one.
DISPATCH=$(grep -n '^case "${1:-}" in' "$SETUP" | cut -d: -f1)
if [ -z "$DISPATCH" ]; then
  printf '  FAIL  cannot locate the setup.sh dispatch case — test needs updating\n'
  exit 1
fi
sed -n "1,$((DISPATCH - 1))p" "$SETUP" > "$TMP/defs.sh"

# A PATH holding only what the definitions need. Can't strip PATH outright:
# sourcing runs `dirname` for DOTFILES_DIR. Can't stub the tools as shell
# functions either — `command -v` finds functions, which is the opposite of
# absent, and absence is exactly what case 1 tests.
mkdir -p "$TMP/bin"
for t in bash sh dirname basename cat cksum mktemp sed grep awk uname id rm \
         mkdir ln cut sort tr head tail env date chmod find printf; do
  src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$TMP/bin/$t"
done
for leaked in npm firecrawl playwright-cli; do
  if [ -e "$TMP/bin/$leaked" ]; then
    printf '  FAIL  sandbox leaked a %s onto PATH\n' "$leaked"
    exit 1
  fi
done

ARGV="$TMP/firecrawl.argv"
PW_ARGV="$TMP/playwright.argv"

# <exit code for credit-usage> — writes a firecrawl stub onto the sandbox PATH.
make_firecrawl_stub() {
  local credit_rc="$1"
  cat > "$TMP/bin/firecrawl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ARGV"
case "\$1" in
  credit-usage) exit $credit_rc ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TMP/bin/firecrawl"
}

# <exit code for the agents skill install> — writes a playwright-cli stub.
make_playwright_stub() {
  local agents_rc="$1"
  cat > "$TMP/bin/playwright-cli" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PW_ARGV"
case "\$*" in
  *--skills=agents*) exit $agents_rc ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$TMP/bin/playwright-cli"
}

# `set -euo pipefail` is ON deliberately: the regression these guard against is
# an ABORT, not a wrong value, so the assertion is "did the snippet reach its
# last line". ensure_firecrawl is called BARE, never `ensure_firecrawl || true`:
# bash disables errexit for a whole function body invoked in a tested context,
# which would suppress the very abort under test.
run_setup() {
  PATH="$TMP/bin" HOME="$TMP/home" SUDO="" bash -c "
    set -euo pipefail
    source '$TMP/defs.sh' >/dev/null 2>&1
    $1
  " 2>&1
}

# --- 1. no npm and no firecrawl: warn, do not abort -------------------------
rm -f "$TMP/bin/firecrawl" "$ARGV"
got=$(run_setup 'ensure_firecrawl; printf "REACHED_END"')
case "$got" in
  *REACHED_END*) ok "ensure_firecrawl without npm or firecrawl does not abort the run" ;;
  *) ko "ensure_firecrawl without npm or firecrawl does not abort the run" \
        "run died early, output: [$got]" ;;
esac

case "$got" in
  *"installed"*) ko "ensure_firecrawl does not claim an install it did not do" \
                    "claimed success with no npm, output: [$got]" ;;
  *) ok "ensure_firecrawl does not claim an install it did not do" ;;
esac

# --- 2. with firecrawl present: init once, credit-usage once ----------------
make_firecrawl_stub 0
: > "$ARGV"
got=$(run_setup 'ensure_firecrawl; printf "REACHED_END"')

inits=$(grep -c -- '^init -y --skip-install --skip-auth$' "$ARGV" || true)
if [ "$inits" = "1" ]; then
  ok "ensure_firecrawl runs 'init -y --skip-install --skip-auth' exactly once"
else
  ko "ensure_firecrawl runs 'init -y --skip-install --skip-auth' exactly once" \
     "saw $inits, argv log: [$(tr '\n' '|' < "$ARGV")]"
fi

credits=$(grep -c -- '^credit-usage$' "$ARGV" || true)
if [ "$credits" = "1" ]; then
  ok "ensure_firecrawl probes auth with 'credit-usage' exactly once"
else
  ko "ensure_firecrawl probes auth with 'credit-usage' exactly once" \
     "saw $credits, argv log: [$(tr '\n' '|' < "$ARGV")]"
fi

# --status exits 0 with a bad key, so it can never be the probe.
if grep -q -- '^--status$' "$ARGV"; then
  ko "ensure_firecrawl does not use '--status' to judge auth" \
     "--status cannot distinguish a good key from a bad one"
else
  ok "ensure_firecrawl does not use '--status' to judge auth"
fi

# setup.sh must never open a browser flow.
if grep -q -- '^login' "$ARGV"; then
  ko "ensure_firecrawl never runs 'firecrawl login'" "a setup run cannot drive a browser"
else
  ok "ensure_firecrawl never runs 'firecrawl login'"
fi

case "$got" in
  *REACHED_END*) ok "ensure_firecrawl with an authenticated CLI does not abort the run" ;;
  *) ko "ensure_firecrawl with an authenticated CLI does not abort the run" \
        "run died early, output: [$got]" ;;
esac

# --- 3. failing credit-usage: report, do not fail ---------------------------
make_firecrawl_stub 1
: > "$ARGV"
got=$(run_setup 'ensure_firecrawl; printf "REACHED_END"')
case "$got" in
  *REACHED_END*) ok "ensure_firecrawl survives an unauthenticated CLI" ;;
  *) ko "ensure_firecrawl survives an unauthenticated CLI" \
        "run died early, output: [$got]" ;;
esac

case "$got" in
  *"not authenticated"*) ok "ensure_firecrawl says the CLI is not authenticated" ;;
  *) ko "ensure_firecrawl says the CLI is not authenticated" "output: [$got]" ;;
esac


# --- 4. playwright-cli: no npm and no binary, warn and continue -------------
rm -f "$TMP/bin/playwright-cli" "$PW_ARGV"
got=$(run_setup 'ensure_playwright_cli; printf "REACHED_END"')
case "$got" in
  *REACHED_END*) ok "ensure_playwright_cli without npm or the binary does not abort the run" ;;
  *) ko "ensure_playwright_cli without npm or the binary does not abort the run" \
        "run died early, output: [$got]" ;;
esac

case "$got" in
  *"installed"*) ko "ensure_playwright_cli does not claim an install it did not do" \
                    "claimed success with no npm, output: [$got]" ;;
  *) ok "ensure_playwright_cli does not claim an install it did not do" ;;
esac

# --- 5. playwright-cli present: both skill targets, exactly once each -------
make_playwright_stub 0
: > "$PW_ARGV"
got=$(run_setup 'ensure_playwright_cli; printf "REACHED_END"')

claude_skill=$(grep -c -- '^install --skills --global$' "$PW_ARGV" || true)
if [ "$claude_skill" = "1" ]; then
  ok "ensure_playwright_cli runs 'install --skills --global' exactly once"
else
  ko "ensure_playwright_cli runs 'install --skills --global' exactly once" \
     "saw $claude_skill, argv log: [$(tr '\n' '|' < "$PW_ARGV")]"
fi

agent_skill=$(grep -c -- '^install --skills=agents --global$' "$PW_ARGV" || true)
if [ "$agent_skill" = "1" ]; then
  ok "ensure_playwright_cli runs 'install --skills=agents --global' exactly once"
else
  ko "ensure_playwright_cli runs 'install --skills=agents --global' exactly once" \
     "saw $agent_skill, argv log: [$(tr '\n' '|' < "$PW_ARGV")]"
fi

# The one that would litter whatever directory setup.sh happened to run in.
ungl=$(grep -- '^install' "$PW_ARGV" | grep -v -- '--global' || true)
if [ -z "$ungl" ]; then
  ok "every ensure_playwright_cli install call carries --global"
else
  ko "every ensure_playwright_cli install call carries --global" \
     "workspace-initialising call: [$(printf '%s' "$ungl" | tr '\n' '|')]"
fi

case "$got" in
  *REACHED_END*) ok "ensure_playwright_cli with a working CLI does not abort the run" ;;
  *) ko "ensure_playwright_cli with a working CLI does not abort the run" \
        "run died early, output: [$got]" ;;
esac

# --- 6. a failing skill install is a warning, not an abort -----------------
make_playwright_stub 1
: > "$PW_ARGV"
got=$(run_setup 'ensure_playwright_cli; printf "REACHED_END"')
case "$got" in
  *REACHED_END*) ok "ensure_playwright_cli survives a failing skill install" ;;
  *) ko "ensure_playwright_cli survives a failing skill install" \
        "run died early, output: [$got]" ;;
esac

case "$got" in
  *"--skills=agents --global"*) ok "ensure_playwright_cli names the command that failed" ;;
  *) ko "ensure_playwright_cli names the command that failed" "output: [$got]" ;;
esac

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
