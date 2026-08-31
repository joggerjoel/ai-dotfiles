#!/usr/bin/env bash
# Tests for lib/fleet.sh. Dotted stem on purpose: link_claude_hooks() excludes
# *.*.* files, so this never installs as a live hook.
#
# The inventory is gitignored, so every assertion below runs against a fixture
# except the last, which is the only one that can see the real fleet.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
. "$ROOT/lib/fleet.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

# A second group with its own hosts, because the bug this guards against is a
# list that means "the fleet" quietly including or dropping the wrong machines.
cat > "$TMP/inventory.yml" <<'YAML'
aorus_ai:
  hosts:
    aorus:
    aorus2:
    aorus9:
  vars:
    ansible_user: someone
other_group:
  hosts:
    notfleet1:
    notfleet2:
YAML

eq "every host in the fleet group is returned, in file order" \
   "aorus aorus2 aorus9" "$(fleet_hosts "$TMP/inventory.yml")"

case " $(fleet_hosts "$TMP/inventory.yml") " in
  *" notfleet1 "*|*" notfleet2 "*)
    ko "hosts in another group are not the fleet" \
       "got: $(fleet_hosts "$TMP/inventory.yml")" ;;
  *) ok "hosts in another group are not the fleet" ;;
esac

# A worker checkout has no inventory: the file is gitignored because the repo is
# public. The scripts still have to name a fleet there.
eq "an unreadable inventory falls back to the written list" \
   "$FLEET_HOSTS_FALLBACK" "$(fleet_hosts "$TMP/nope.yml")"

# `vars:` sits at the same indent as `hosts:` and its keys one deeper, which is
# the shape most likely to be mistaken for a host.
case " $(fleet_hosts "$TMP/inventory.yml") " in
  *" ansible_user "*) ko "group vars are not mistaken for hosts" ;;
  *)                  ok "group vars are not mistaken for hosts" ;;
esac

# --- drift ------------------------------------------------------------------
# The whole point of reading the inventory. aorus2 joined aorus_ai and stayed
# missing from two hand-kept copies, so auth probing and token distribution
# both skipped a managed host and neither said so. This runs only where the
# real inventory exists, which is the control node.

REAL="${AI_DOTFILES_INVENTORY:-$ROOT/ansible-ai/inventory.local.yml}"
if [ -r "$REAL" ]; then
  eq "the fallback still names the whole fleet" \
     "$(fleet_hosts "$REAL")" "$FLEET_HOSTS_FALLBACK"
else
  printf '  SKIP  the fallback still names the whole fleet (no inventory here)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
