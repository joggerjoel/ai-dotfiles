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

# --- the probe resolves binaries off PATH -----------------------------------
# ssh runs a non-login shell whose PATH often omits /usr/local/bin. macstudio
# was reported absent while node_exporter ran there as root out of that exact
# directory, and converge would have reinstalled over a working host. This is a
# shape assertion on purpose: the failure is someone simplifying the probe back
# to a bare `command -v`, and there is no hermetic way to fake a non-login PATH
# for a remote shell.
case "$probe_cmd" in
  *"/usr/local/bin/node_exporter"*) ok "the probe falls back to /usr/local/bin" ;;
  *) ko "the probe falls back to /usr/local/bin" ;;
esac
case "$probe_cmd" in
  *"/opt/homebrew/bin/node_exporter"*) ok "the probe falls back to the arm64 homebrew prefix" ;;
  *) ko "the probe falls back to the arm64 homebrew prefix" ;;
esac

# --- the scrape template renders valid YAML ---------------------------------
# The first version of this template used jinja whitespace-control dashes and
# emitted `- targets:` at column 0 under an indented static_configs. That is
# invalid YAML, prometheus refuses to load it, and a converge run would have
# reported success against a dead config. Render it here rather than trusting
# that it looks right.

TPL="$ROOT/ansible-ai/templates/prometheus.yml.j2"

# trim_blocks and lstrip_blocks are what keep the indentation correct, and
# ansible only applies them because the template declares them on line 1.
if head -1 "$TPL" | grep -q 'trim_blocks: True' && head -1 "$TPL" | grep -q 'lstrip_blocks: True'; then
  ok "the scrape template declares the jinja flags its indentation depends on"
else
  ko "the scrape template declares the jinja flags its indentation depends on"
fi

if python3 - "$TPL" <<'PY' 2>/dev/null
import sys, yaml, jinja2

src = open(sys.argv[1]).read().split("\n", 1)[1]          # drop the #jinja2 header
src = src.replace("{{ ansible_managed | comment }}", "# managed")

groups = {
    "aorus_ai": ["aorus", "aorus2", "macair"],
    "redis_ai": ["aorus", "aorus2"],
}
hostvars = {
    "aorus":     {"ansible_host": "10.0.0.1"},
    "aorus2":    {"ansible_host": "10.0.0.2", "scrape_address": "10.9.9.9"},
    "macair":    {"ansible_host": "tail.name", "scrape_skip": True},
    "localhost": {"scrape_address": "10.0.0.99"},
}
obs = {
    "retention": {"scrape_interval": "15s"},
    "exporters": {"redis": {"group": "redis_ai", "job": "redis", "port": 9121}},
}

env = jinja2.Environment(trim_blocks=True, lstrip_blocks=True)
out = env.from_string(src).render(groups=groups, hostvars=hostvars, obs=obs)

d = yaml.safe_load(out)                                    # invalid YAML raises
jobs = {j["job_name"]: j for j in d["scrape_configs"]}

node = [t for s in jobs["node"]["static_configs"] for t in s["targets"]]
assert "10.0.0.1:9100" in node, node
# scrape_address must win over ansible_host: the address ansible connects on is
# not always the one prometheus can reach.
assert "10.9.9.9:9100" in node, node
assert "10.0.0.2:9100" not in node, node
# scrape_skip must remove the host entirely, not render it unreachable.
assert not any("tail.name" in t for t in node), node
assert len(node) == 2, node
PY
then
  ok "the scrape template renders valid YAML with the right targets"
else
  ko "the scrape template renders valid YAML with the right targets"
fi

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

  # A grafana.com dashboard without a revision tracks whatever upstream
  # publishes, which makes the deploy non-reproducible. A local dashboard is
  # pinned by living in the repo, so it needs a file instead.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
def pinned(x):
    if 'gnet_id' in x: return 'revision' in x
    return bool(x.get('file'))
sys.exit(0 if all(pinned(x) for x in d['dashboards']) else 1)
"; then
    ok "every dashboard is pinned, by revision or by a repo file"
  else
    ko "every dashboard is pinned, by revision or by a repo file"
  fi

  # Every exporter role must name the inventory group that places it. Without
  # one, the scrape job has no hosts to generate from and the dashboard stays
  # empty for the same reason it is empty today.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
need = ('group', 'job', 'port', 'dashboard')
bad = [k for k, v in d['exporters'].items() if not all(f in v for f in need)]
if bad: print('incomplete:', bad, file=sys.stderr)
sys.exit(1 if bad else 0)
"; then
    ok "every exporter names a group, job, port and dashboard"
  else
    ko "every exporter names a group, job, port and dashboard"
  fi

  # Same pinning rule as the fleet dashboards. An unpinned revision tracks
  # whatever grafana.com publishes next.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
bad = [k for k, v in d['exporters'].items()
       if not (v['dashboard'].get('gnet_id') and v['dashboard'].get('revision'))]
sys.exit(1 if bad else 0)
"; then
    ok "every exporter dashboard is pinned by id and revision"
  else
    ko "every exporter dashboard is pinned by id and revision"
  fi

  # The groups the manifest names must exist in the inventory, or the generated
  # scrape job silently renders with no targets.
  INV="$ROOT/ansible-ai/inventory.local.yml"
  if [ -r "$INV" ]; then
    if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
inv = yaml.safe_load(open('$INV'))
missing = [v['group'] for v in d['exporters'].values() if v['group'] not in inv]
if missing: print('absent from inventory:', missing, file=sys.stderr)
sys.exit(1 if missing else 0)
"; then
      ok "every exporter group exists in the inventory"
    else
      ko "every exporter group exists in the inventory"
    fi

    # The group the whole design hangs on. It was designed, written about at
    # length, and never actually added, which the exporter-group check above
    # did not cover.
    if python3 -c "
import sys, yaml
inv = yaml.safe_load(open('$INV'))
hosts = (inv.get('observability_ai') or {}).get('hosts') or {}
sys.exit(0 if len(hosts) == 1 else 1)
"; then
      ok "observability_ai exists and names exactly one host"
    else
      ko "observability_ai exists and names exactly one host"
    fi
  else
    printf '  SKIP  every exporter group exists in the inventory (no inventory here)\n'
  fi

  # discover matches bound ports against these, so an exporter without them is
  # invisible to introspection and its group silently stays hand-maintained.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
bad = [k for k, v in d['exporters'].items()
       if not ((v.get('detect') or {}).get('service') and (v.get('detect') or {}).get('exporter'))]
if bad: print('no detect block:', bad, file=sys.stderr)
sys.exit(1 if bad else 0)
"; then
    ok "every exporter declares service and exporter ports for discovery"
  else
    ko "every exporter declares service and exporter ports for discovery"
  fi

  # A collector naming a script that does not exist renders a timer that fails
  # on every fire, and a missing metric reads identically to a host with no
  # listening sockets.
  if python3 -c "
import sys, os, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
root = '$ROOT'
cs = d['node_exporter'].get('textfile_collectors', [])
missing = [c['script'] for c in cs if not os.path.exists(os.path.join(root, c['script']))]
if missing: print('missing:', missing, file=sys.stderr)
sys.exit(1 if missing or not cs else 0)
"; then
    ok "every textfile collector names a script that exists"
  else
    ko "every textfile collector names a script that exists"
  fi

  # The whole point of the collector is defeated if the unit never reads the
  # directory. The fleet's current units carry no flags at all.
  if python3 -c "
import sys, yaml
d = yaml.safe_load(open('$REAL_MANIFEST'))
sys.exit(0 if d['node_exporter'].get('textfile_dir') else 1)
"; then
    ok "a textfile directory is configured for node_exporter to read"
  else
    ko "a textfile directory is configured for node_exporter to read"
  fi
else
  printf '  SKIP  the committed manifest (not present here)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
