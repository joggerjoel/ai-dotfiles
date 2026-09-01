#!/usr/bin/env bash
# Tests for scripts/observability.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# reconcile_version is pure, so every version assertion runs on recorded strings
# and needs no fleet. Only the last block reads the real inventory.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
. "$ROOT/scripts/observability.sh"
pass=0 fail=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/obs.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ (${2})}"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected [$2] got [$3]"; }

# --- the reconciler ---------------------------------------------------------
# Five outcomes, not a boolean. The original requirement said "do not install if
# it already exists", which collapses behind and current into one answer and
# would have left the whole fleet on 1.10.2.

eq "a host with no binary is absent" \
   "absent" "$(reconcile_version absent 1.12.1)"

eq "a host that ssh could not reach is not evidence of anything" \
   "unreachable" "$(reconcile_version unreachable 1.12.1)"

eq "a matching version needs no action" \
   "current" "$(reconcile_version 1.12.1 1.12.1)"

eq "an older version is behind" \
   "behind" "$(reconcile_version 1.10.2 1.12.1)"

# Ahead means the manifest is stale, not the host. Treating it as behind would
# downgrade a host on every run.
eq "a newer version is ahead, not behind" \
   "ahead" "$(reconcile_version 1.13.0 1.12.1)"

# The bug this guards: a plain string compare puts 1.9.0 after 1.12.1, because
# "9" sorts above "1". That reads as ahead and silently skips the upgrade.
eq "1.9.0 is behind 1.12.1, not ahead of it" \
   "behind" "$(reconcile_version 1.9.0 1.12.1)"

eq "a two-digit minor is compared numerically" \
   "ahead" "$(reconcile_version 1.12.1 1.9.0)"

# --- the manifest boundary --------------------------------------------------
# Every value is validated once, here. Nothing downstream re-checks it.

cat > "$TMP/manifest.yml" <<'YAML'
node_exporter:
  version: "9.9.9"
stack:
  dir: /opt/observability
YAML

eq "a nested key is read from the manifest" \
   "9.9.9" "$(MANIFEST="$TMP/manifest.yml" manifest_get node_exporter.version)"

if MANIFEST="$TMP/manifest.yml" manifest_get node_exporter.nope >/dev/null 2>&1; then
  ko "a missing key fails loudly instead of returning empty"
else
  ok "a missing key fails loudly instead of returning empty"
fi

# An empty value would otherwise flow into the reconciler and mark every host
# ahead of nothing.
if MANIFEST="$TMP/nonexistent.yml" manifest_validate >/dev/null 2>&1; then
  ko "an unreadable manifest is rejected"
else
  ok "an unreadable manifest is rejected"
fi

# --- the real manifest ------------------------------------------------------

REAL_MANIFEST="$ROOT/ansible-ai/observability.yml"
if [ -r "$REAL_MANIFEST" ]; then
  v=$(MANIFEST="$REAL_MANIFEST" manifest_get node_exporter.version)
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) ok "the committed manifest pins a semver node_exporter" ;;
    *) ko "the committed manifest pins a semver node_exporter" "got [$v]" ;;
  esac

  eq "the committed manifest pins Node Exporter Full by its grafana.com id" \
     "1860" "$(python3 -c "
import yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
print(next(x['gnet_id'] for x in d['dashboards'] if x['name'] == 'node-exporter-full'))
")"

  # A dashboard without a revision tracks whatever grafana.com publishes, which
  # makes the deploy non-reproducible.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
sys.exit(0 if all('revision' in x for x in d['dashboards']) else 1)
"; then
    ok "every dashboard is pinned to a revision"
  else
    ko "every dashboard is pinned to a revision"
  fi
else
  printf '  SKIP  the committed manifest (not present here)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
