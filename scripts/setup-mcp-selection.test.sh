#!/usr/bin/env bash
# Tests for setup.sh's MCP integration picker. Dotted stem on purpose:
# link_claude_hooks() excludes *.*.* files, so this never installs as a live hook.
#
# The bug these guard against left the entire fleet without MCP servers, while
# every provisioning run reported success.
#
# provision-ai.yml drives setup.sh unattended by piping a fixed set of answers:
#
#     printf '<profile>\n<github-user>\n<hide-ai>\n' | bash setup.sh
#
# Three answers go in. The MCP picker is reached AFTER those are consumed, so
# its `read` sees EOF and yields "" — and "" is the picker's own encoding of
# "skip everything". Nothing errored, nothing warned, and every fleet host
# ended up with `mcpServers: null` looking like a clean install. The gap held
# until someone noticed a box had no MCP servers at all.
#
# The fix is DOTFILES_MCP, which answers the picker out of band. The invariants:
#
#   1. a selection by NAME resolves to exactly those integrations
#   2. an unknown name is fatal — a playbook typo must stop the run, never
#      silently provision a smaller set than was asked for
#   3. menu numbers still work, and still line up with what the menu printed,
#      on both profiles
#   4. the DOTFILES_MCP value committed in provision-ai.yml actually resolves
#
# Runs under bash 3.2 (stock macOS) as well as bash 5 — no associative arrays,
# no mapfile. setup.sh is `#!/bin/bash`, which on a Mac IS 3.2.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SETUP="$ROOT/setup.sh"
PLAYBOOK="$ROOT/ansible-ai/provision-ai.yml"
pass=0 fail=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/setupmcp.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

# setup.sh dispatches on "$1" at the very bottom; everything above is
# definitions, so sourcing that prefix gets the functions without running one.
DISPATCH=$(grep -n '^case "${1:-}" in' "$SETUP" | cut -d: -f1)
if [ -z "$DISPATCH" ]; then
  printf '  FAIL  cannot locate the setup.sh dispatch case — test needs updating\n'
  printf '\n0 passed, 1 failed\n'
  exit 1
fi
sed -n "1,$((DISPATCH - 1))p" "$SETUP" > "$TMP/defs.sh"

# Resolve a selection to a comma-joined list of integration NAMES, which is what
# the assertions below are written against. Indices would make every expectation
# churn whenever the registry gains a row, which is the same brittleness that
# made name-based selection the right interface in the first place.
names_for() {
  local selection="$1" profile="$2"
  bash -c "
    source '$TMP/defs.sh' >/dev/null 2>&1
    for i in \$(integration_selection '$selection' '$profile' 2>/dev/null); do
      printf '%s,' \"\$(get_field \"\${INTEGRATIONS[\$i]}\" 1)\"
    done
  " | sed 's/,$//'
}

# Exit status only, stderr and stdout discarded.
selection_rc() {
  bash -c "
    source '$TMP/defs.sh' >/dev/null 2>&1
    integration_selection '$1' '$2' >/dev/null 2>&1
  "
}

# --- the regression: selection by name ----------------------------------------

got=$(names_for "context7,serena,morphllm-fast-apply,headroom" vps)
want="context7,serena,morphllm-fast-apply,headroom"
[ "$got" = "$want" ] \
  && ok "a name list resolves to exactly those integrations" \
  || ko "a name list resolves to exactly those integrations" "got '$got' want '$want'"

got=$(names_for "serena" desktop)
[ "$got" = "serena" ] \
  && ok "a single name resolves" \
  || ko "a single name resolves" "got '$got'"

got=$(names_for " context7 , serena " desktop)
[ "$got" = "context7,serena" ] \
  && ok "surrounding whitespace in a name list is ignored" \
  || ko "surrounding whitespace in a name list is ignored" "got '$got'"

# --- the regression: EOF must still mean skip, and must not crash -------------

got=$(names_for "" vps)
[ -z "$got" ] \
  && ok "an empty selection (interactive Enter, or stdin at EOF) selects nothing" \
  || ko "an empty selection selects nothing" "got '$got'"

selection_rc "" vps \
  && ok "an empty selection is not an error" \
  || ko "an empty selection is not an error" "returned non-zero"

got=$(names_for "none" vps)
[ -z "$got" ] \
  && ok "'none' selects nothing" \
  || ko "'none' selects nothing" "got '$got'"

# --- a typo must be fatal, not silently smaller -------------------------------

if selection_rc "context7,headrooom" vps; then
  ko "an unknown name returns non-zero" "returned 0 — a playbook typo would install silently"
else
  ok "an unknown name returns non-zero"
fi

# The dangerous shape of this bug is not the error, it is a PARTIAL result being
# treated as the whole answer. Assert the caller cannot mistake one for the other.
got=$(names_for "context7,headrooom,serena" vps)
if [ "$got" = "context7,serena" ]; then
  ko "an unknown name does not yield a usable partial list" \
     "resolved to '$got' — caller could act on it"
else
  ok "an unknown name does not yield a usable partial list"
fi

# --- menu numbers keep working, and match what the menu printed ---------------

first_desktop=$(names_for "1" desktop)
[ "$first_desktop" = "context7" ] \
  && ok "menu number 1 still resolves on the desktop profile" \
  || ko "menu number 1 still resolves on the desktop profile" "got '$first_desktop'"

got=$(names_for "1-3" desktop)
[ "$got" = "context7,serena,morphllm-fast-apply" ] \
  && ok "a menu range still resolves" \
  || ko "a menu range still resolves" "got '$got'"

# Numbering is per-profile: vps hides desktop-only rows, so the same number is a
# different integration there. Both must agree with their own menu.
menu_names_for() {
  bash -c "
    source '$TMP/defs.sh' >/dev/null 2>&1
    for i in \$(visible_integration_indices '$1'); do
      printf '%s,' \"\$(get_field \"\${INTEGRATIONS[\$i]}\" 1)\"
    done
  " | sed 's/,$//'
}

for prof in desktop vps; do
  menu=$(menu_names_for "$prof")
  # grep -c, not wc -l: the menu has no trailing newline, so wc undercounts the
  # last entry by one and the range silently stops one short.
  n=$(printf '%s' "$menu" | tr ',' '\n' | grep -c .)
  picked=$(names_for "1-$n" "$prof")
  [ "$picked" = "$menu" ] \
    && ok "selecting the full menu range on ${prof} returns the printed menu" \
    || ko "selecting the full menu range on ${prof} returns the printed menu" \
          "range gave '$picked' menu is '$menu'"

  picked=$(names_for "all" "$prof")
  [ "$picked" = "$menu" ] \
    && ok "'all' on ${prof} returns the printed menu" \
    || ko "'all' on ${prof} returns the printed menu" "got '$picked' menu is '$menu'"
done

# --- profile filtering: hidden is a notice, not an abort ----------------------

# chrome-devtools is desktop_only. Naming it on a vps must not kill the run, so
# that one shared DOTFILES_MCP list can serve mixed hosts.
if selection_rc "context7,chrome-devtools" vps; then
  ok "a desktop-only name on vps is not fatal"
else
  ko "a desktop-only name on vps is not fatal" "returned non-zero"
fi

got=$(names_for "context7,chrome-devtools" vps)
[ "$got" = "context7" ] \
  && ok "a desktop-only name is dropped from the vps selection" \
  || ko "a desktop-only name is dropped from the vps selection" "got '$got'"

got=$(names_for "context7,chrome-devtools" desktop)
[ "$got" = "context7,chrome-devtools" ] \
  && ok "the same list keeps chrome-devtools on desktop" \
  || ko "the same list keeps chrome-devtools on desktop" "got '$got'"

# --- headroom is registered, not hand-configured -----------------------------

# Before this, headroom existed in exactly one ~/.claude.json that someone had
# edited by hand; no code path could produce it.
json=$(bash -c "source '$TMP/defs.sh' >/dev/null 2>&1; mcp_json_for headroom")
if printf '%s' "$json" | jq -e '.command == "headroom" and .args == ["mcp","serve"]' >/dev/null 2>&1; then
  ok "headroom has an MCP JSON generator"
else
  ko "headroom has an MCP JSON generator" "got '$json'"
fi

# --- the committed playbook value actually resolves --------------------------

# The whole fix is worthless if the value shipped to the fleet has a typo in it.
# Read it out of the playbook rather than restating it here, so the two cannot
# drift: a test that hardcodes its own copy guards nothing.
dm=$(sed -n 's/^ *dotfiles_mcp: *"\(.*\)" *$/\1/p' "$PLAYBOOK" | head -1)
if [ -z "$dm" ]; then
  ko "provision-ai.yml declares dotfiles_mcp" "no dotfiles_mcp key found"
else
  ok "provision-ai.yml declares dotfiles_mcp"

  if selection_rc "$dm" vps; then
    ok "the committed dotfiles_mcp resolves on the vps profile"
  else
    ko "the committed dotfiles_mcp resolves on the vps profile" "'$dm' contains an unknown name"
  fi

  got=$(names_for "$dm" vps)
  want=$(printf '%s' "$dm" | tr -d ' ')
  [ "$got" = "$want" ] \
    && ok "the committed dotfiles_mcp selects every name it lists" \
    || ko "the committed dotfiles_mcp selects every name it lists" "got '$got' want '$want'"

  # The failure that started all this: a fleet host with no MCP servers.
  [ -n "$got" ] \
    && ok "an unattended fleet run selects at least one MCP server" \
    || ko "an unattended fleet run selects at least one MCP server" "selected nothing"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
