#!/usr/bin/env bash
# Does herdr-tabwatch.test.sh actually catch a reverted fix?
#
# Twice now this branch shipped a suite that passed against broken code. First
# with detection power on one machine, then on none: an exported override meant
# the probe under test was never the one that ran. Both times the suite was
# green and the reasoning was wrong, and nothing said so.
#
# So the claim "mutation tested" stops being a sentence in a PR body and becomes
# this file. Each entry reverts one shipped fix in a scratch copy and requires
# the suite to go red. A fix nothing detects fails here.
#
# Never edits the working tree: every mutation is applied to a copy of scripts/.

HERE=$(cd "$(dirname "$0")" && pwd)
SUITE="herdr-tabwatch.test.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/tw-mutation.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ ($2)}"; fail=$((fail + 1)); }

# <label> <file> <sed program>
mutate() {
  local label="$1" file="$2" prog="$3" dir out
  dir="$TMP/$(echo "$label" | tr ' /' '__')"
  mkdir -p "$dir"
  cp -R "$HERE/." "$dir/" 2>/dev/null || true
  [ -f "$dir/$file" ] || { ko "$label" "no $file in the copy"; return; }
  sed -i.bak "$prog" "$dir/$file" && rm -f "$dir/$file.bak"
  if cmp -s "$HERE/$file" "$dir/$file"; then
    ko "$label" "the mutation changed nothing, so it tests nothing"
    return
  fi
  out=$(cd "$dir" && bash "./$SUITE" 2>&1 | tail -1)
  case "$out" in
    *"0 failed"*) ko "$label" "suite still green: $out" ;;
    *failed*)     ok "$label" ;;
    *)            ko "$label" "suite did not report a result: $out" ;;
  esac
}

# A mutation result means nothing if the tree is already red: every entry would
# read as caught. Establish the baseline before trusting any of them.
base=$(cd "$HERE" && bash "./$SUITE" 2>&1 | tail -1)
case "$base" in
  *"0 failed"*) ;;
  *) printf 'the suite is not green before mutating, so nothing below is meaningful\n  %s\n' "$base"; exit 1 ;;
esac

printf 'Reverted fixes the suite must catch\n'

mutate "identity probe resolved by absolute path" \
  "herdr-tabwatch.py" 's|"/usr/sbin/scutil"|"scutil"|'

mutate "generated plists carry /usr/sbin and /sbin" \
  "herdr-node.sh" 's|:/usr/bin:/bin:/usr/sbin:/sbin|:/usr/bin:/bin|g'

mutate "an unresolvable alias is refused, not dialled" \
  "herdr-tabwatch.py" '/target is None:/{n;s|return .*|return None|;}'

# The runner parses this shape; a summary of its own would report "? passed".
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
