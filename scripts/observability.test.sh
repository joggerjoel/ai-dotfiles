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
# Seven outcomes, not a boolean. The original requirement said "do not install if
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

# A rejected key and a changed host key both used to arrive as "unreachable",
# which made a swapped host key look exactly like a laptop asleep.
eq "an ssh auth rejection is its own state" \
   "authfail" "$(reconcile_version authfail 1.12.1)"

eq "a changed host key is its own state" \
   "hostkey" "$(reconcile_version hostkey 1.12.1)"

# --- check does not pass on absent evidence ---------------------------------
# The regression this guards: check counted only drift, so a host it could not
# reach printed dim, incremented nothing, and the run ended on "every reachable
# host matches the manifest" with exit 0. A fleet that was entirely down
# reported success, from the one command the design tells you to trust.

rc=0
out="$(ONLY_HOST=no-such-host.invalid cmd_check 2>&1)" || rc=$?
[ "$rc" -ne 0 ] \
  && ok "check exits non-zero when a host gives no answer" \
  || ko "check exits non-zero when a host gives no answer" "exit was $rc"

case "$out" in
  *"not a pass"*) ok "check says plainly that silence is not a pass" ;;
  *)              ko "check says plainly that silence is not a pass" "got: $out" ;;
esac

case "$out" in
  *"every host answered and matches"*)
    ko "check does not claim success while blind" ;;
  *) ok "check does not claim success while blind" ;;
esac

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

  # Docker Compose does not expand `~` in a bind-mount source. The mount then
  # resolves to an empty directory, and because recon's providers all set
  # disableDeletion: false, grafana deletes the dashboards it had provisioned
  # from the shared volume. This shipped once; the test is here so it cannot
  # ship again.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
paths = [v for v in d.get('foreign', {}).values() if isinstance(v, str)]
sys.exit(1 if any(p.startswith('~') for p in paths) else 0)
"; then
    ok "no foreign path uses an unexpandable ~"
  else
    ko "no foreign path uses an unexpandable ~"
  fi

  # Recon declares its volumes bare, so they are project-owned and a
  # `docker compose down -v` in that repo deletes them. Nothing in our compose
  # file can stop that, so the stack must not sit on them at all.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
svcs = [v for k, v in d['stack'].items() if isinstance(v, dict)]
bad = [s['volume'] for s in svcs if s.get('volume', '').startswith('recon-')]
sys.exit(1 if bad else 0)
"; then
    ok "no service runs on a recon-owned volume"
  else
    ko "no service runs on a recon-owned volume"
  fi

  # Copy, never move. The untouched originals are the rollback.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
svcs = [v for k, v in d['stack'].items() if isinstance(v, dict)]
sys.exit(0 if all('migrate_from' in s for s in svcs) else 1)
"; then
    ok "every service names the volume its data is copied from"
  else
    ko "every service names the volume its data is copied from"
  fi

  # A tag can be repointed on the registry without this file changing, which is
  # the drift this design calls a bug everywhere else.
  if python3 -c "
import sys, re, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
svcs = [v for v in d['stack'].values() if isinstance(v, dict)]
ok = all(re.fullmatch(r'sha256:[0-9a-f]{64}', s.get('digest', '')) for s in svcs)
sys.exit(0 if ok else 1)
"; then
    ok "every image is pinned by digest, not only by tag"
  else
    ko "every image is pinned by digest, not only by tag"
  fi

  # Unbounded is the failure mode, not a large number. Prometheus needs both a
  # time and a size bound, because time alone does not stop a cardinality
  # explosion filling the disk inside the window.
  if python3 -c "
import sys, yaml
r = yaml.safe_load(open('$REAL_MANIFEST'))['retention']
sys.exit(0 if r['prometheus'].get('time') and r['prometheus'].get('size')
         and r['loki'].get('period') else 1)
"; then
    ok "prometheus is bounded by time and size, loki by period"
  else
    ko "prometheus is bounded by time and size, loki by period"
  fi

  # Loki ignores its retention period unless the compactor is told to enforce
  # it, and the compactor is off by default. Setting the period alone is a
  # config that reads correct and deletes nothing.
  if python3 -c "
import sys, yaml
l = yaml.safe_load(open('$REAL_MANIFEST'))['retention']['loki']
sys.exit(0 if l.get('compactor_retention_enabled') is True else 1)
"; then
    ok "loki retention is actually enforced by the compactor"
  else
    ko "loki retention is actually enforced by the compactor"
  fi

  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
svcs = [v for v in d['stack'].values() if isinstance(v, dict)]
sys.exit(0 if all(s.get('mem_limit') for s in svcs) else 1)
"; then
    ok "every service has a memory limit"
  else
    ko "every service has a memory limit"
  fi

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
