# Fleet observability design

Date: 2026-09-01
Status: approved design, not yet implemented

## What this is for

The fleet has nine hosts and no owned view of their health. Metrics collection
already runs on seven of them, but nothing in this repo put it there, nothing
here knows what version it runs, and nothing here can bring a tenth host to the
same state. This design makes ai-dotfiles the owner of that layer.

The scope is metrics for every host, one Grafana on one assigned host, and a
dashboard set that `update.sh` keeps current from a pinned manifest.

## What is already running

Every fact below came from probing the live fleet on 2026-09-01. None of it is
assumed.

Seven Ubuntu hosts run `node_exporter` 1.10.2 as a systemd unit on `*:9100`.
Upstream is 1.12.1, so all seven are two minor versions behind. The two Macs
and the control node have no exporter at all.

`aorus7` runs a full observability stack in Docker, but the
`stubhub-recon-gui` repo owns it. The containers are `recon-grafana` on
`0.0.0.0:3002`, `recon-prometheus` and `recon-loki` on loopback, and
`recon-promtail`. Grafana 12.3.3 and Prometheus 3.9.1. Their config
bind-mounts from `~/Developer/stubhub-recon-gui/monitoring/`, and the
containers share an external Docker network named `recon-network`.

That Prometheus config hand-writes its scrape targets. A comment in the file
says the list came from probing `:9100` across `192.168.1.0/24`. The list is
already stale, because it omits both Macs.

`aorus7` runs Ubuntu 22.04.3, has no Tailscale, and its port 3000 belongs to an
unrelated Node process. Grafana sits on 3002 for that reason.

## The gap this closes

| Host | Exporter now | Target | Action |
| --- | --- | --- | --- |
| aorus, aorus2, aorus4, aorus5, aorus6, aorus7, aorus8 | 1.10.2 | 1.12.1 | Upgrade |
| macstudio, macair | absent | 1.12.1 | Install with Homebrew |
| control node (this Mac) | absent | 1.12.1 | Install with Homebrew |
| Dashboard 1860 | vendored, revision unknown | revision 45 | Reprovision |

## Decisions

### Assign the Grafana host through an inventory group

`inventory.local.yml` gains a subset group.

```yaml
observability_ai:
  hosts:
    aorus7:
```

`ninerouter_ai` and `firstmate_ai` already work this way, so the pattern needs
no explanation to the next reader. The playbook targets `observability_ai` and
never `aorus_ai`. The header of `deploy-9router.yml` records what happens
otherwise, because targeting the whole fleet once installed the gateway on
every host.

### Split ownership rather than share files

ai-dotfiles takes ownership of the stack on `aorus7`, and the recon project
keeps its own dashboards and scrape jobs. Neither repo writes the other's
files. The split repeats in three places.

| Surface | ai-dotfiles owns | recon keeps |
| --- | --- | --- |
| Dashboards | The `infra` provider, in the Fleet folder | The `Recon` and `Ticket Exchange` providers, bind-mounted read only |
| Prometheus | `prometheus.yml`, holding the fleet jobs | `/etc/prometheus/extra/*.yml`, pulled in by `scrape_config_files` |
| Compose | `/opt/observability/docker-compose.yml` and the `obs_*` volumes | Its own `recon-monitoring_*` volumes, plus `recon-network`, which both stacks share |

Grafana 12.3.3 already runs three dashboard providers, one of them an
`Infrastructure` provider reading `dashboards/infra`. Prometheus 3.9.1 supports
`scrape_config_files`, which arrived in 2.43. Both mechanisms are verified on
the running instances, so the split needs no new software.

The alternative was to write ai-dotfiles config into
`~/Developer/stubhub-recon-gui/monitoring/`. Reject it. A `git checkout` in
that repo would silently revert the fleet config, and the two repos would
fight over the same files.

Service names stay `prometheus`, `loki`, and `grafana`, because the
provisioned datasources address them by container DNS. Container names change
from `recon-*` to `obs-*`.

### Keep one manifest as the source of truth

`ansible-ai/observability.yml` holds every version and every dashboard.

```yaml
node_exporter:
  version: "1.12.1"
dashboards:
  - name: node-exporter-full
    gnet_id: 1860
    revision: 45
    folder: Fleet
    datasource: prometheus
stack:
  grafana:    { image: "grafana/grafana:12.3.3", port: 3002, bind: "0.0.0.0" }
  prometheus: { image: "prom/prometheus:v3.9.1", port: 9090, bind: "127.0.0.1" }
  loki:       { image: "grafana/loki:3.6.0",     port: 3100, bind: "127.0.0.1" }
```

The Ansible playbook, the `setup.sh` entry point, the `update.sh` step, and
the tests all read this file. A version appears once.

The naive shape was a playbook full of conditionals asking whether the host is
the Grafana host, whether the exporter exists, whether it is current, and
whether the dashboard is stale. Each new requirement adds a branch to that
chain, which is the failure the model-the-domain principle names. A manifest
plus a reconciler deletes the chain.

### Generate scrape targets from the inventory

`prometheus.yml.j2` walks `groups['aorus_ai']` and emits
`{{ hostvars[h].ansible_host }}:9100` with a `host` label per target. The
inventory becomes the only fleet roster.

`lib/fleet.sh` exists because a second roster drifted twice, and its comments
name both incidents. The recon `prometheus.yml` is a third roster and it has
already drifted. Generating the targets ends that.

The control node gets its own `control_node` job. It is a laptop that sleeps
and leaves the LAN, so mixing it into the server job would make any fleet
health panel read as broken by default.

### Converge versions, do not merely check presence

Every host resolves to one of seven outcomes. Absent means install. Behind
means upgrade. Current means do nothing. Ahead means the manifest is stale
rather than the host, so converge reports it and changes nothing. Unreachable,
authfail, and hostkey all mean the host produced no evidence, which is not a
pass and must not be counted as one.

"Do not install if it already exists" and "ensure it has the latest update"
are different rules, and the second contains the first. All seven Ubuntu hosts
report the exporter as `active`, which reads as done and is not. They are on
1.10.2 against an upstream 1.12.1. Presence was never the right question.

Linux hosts get a systemd unit. macOS hosts get Homebrew and `brew services`.
All three Macs are arm64.

### Bind Grafana to the LAN

Grafana listens on `0.0.0.0:3002`, which is the port it already uses, so
existing bookmarks keep working. Prometheus and Loki stay on loopback, because
nothing outside the host reads them directly. `node_exporter` listens on
`:9100`, which is what the seven Ubuntu hosts already do.

Tailscale binding was the first choice and it is not available. No fleet host
runs Tailscale except `macair`, which reaches the tailnet by hostname.

### Keep Loki scoped to aorus7

Loki and its log agent stay on the Grafana host. Shipping logs from the other
eight hosts needs an agent on each one, and Promtail reached end of life in
early 2025, so that work means deploying Grafana Alloy fleet wide. It is worth
doing later. It is not worth blocking metrics on now.

## Repository layout

```
ansible-ai/
  observability.yml                     manifest, the source of truth
  deploy-observability.yml              three plays, described below
  templates/
    observability.compose.yml.j2
    prometheus.yml.j2
    grafana-datasources.yml.j2
    grafana-providers.yml.j2
    node_exporter.service.j2
  templates/
    node-listening-ports.timer.j2
  dashboards/
    fleet-listening-ports.json          hand authored, no published equivalent
scripts/
  observability.sh                      the audit lever
  observability.test.sh
  node-listening-ports.sh               textfile collector, runs on every host
  node-listening-ports.test.sh
```

## Where each entry point stops

`setup.sh` configures the machine it runs on and nothing else. It gains no
observability subcommand. An earlier draft proposed `./setup.sh grafana` to
provision whichever machine you happened to be sitting on, with no check that
the machine belonged to `observability_ai`. That is the same unconstrained
targeting that once installed the 9router gateway on every fleet host, which
`deploy-9router.yml` records in its header. Deleting the entry point is a
better fix than guarding it, because the inventory group then becomes the only
way a host acquires the stack.

Convergence belongs to the ansible path, where group membership decides
placement and every step is written to be re-runnable.

| Command | Runs | Reaches |
| --- | --- | --- |
| `just fleet-update` | `update.yml`, no limit | `ai_all`, so every fleet host and the control node |
| `update.sh --all` | `update.yml --limit aorus_ai` | the nine fleet hosts, never the control node |
| `ansible-playbook deploy-observability.yml` | this playbook alone | whatever its plays target |

`just fleet-update` is the canonical command. It is the only one that converges
the control node, because `update.sh --all` limits itself to `aorus_ai` on
purpose, and the control node lives in `local_ai`.

`update.yml` imports this playbook the way it already imports `deploy-9router.yml`.

```yaml
- import_playbook: deploy-observability.yml
  tags: [observability]
```

`--skip-tags observability` turns the whole thing off.

## The playbook

Three plays, because one host pattern cannot serve all three jobs. An earlier
draft claimed the playbook "targets `observability_ai` and never `aorus_ai`",
which contradicted its own requirement to install exporters fleet wide.

**Play 1, `hosts: aorus_ai:local_ai`, tags `[exporter]`.** Converges
node_exporter everywhere, sets its textfile directory, installs the listening
port collector, and renders its timer.

**Play 2, `hosts: observability_ai`, tags `[stack]`.** Renders the compose file,
the datasources, the providers, and the generated `prometheus.yml`, then brings
the stack up and reloads Prometheus.

**Play 3, `hosts: observability_ai`, tags `[migrate, never]`.** The one-time
takeover. Ansible's built-in `never` tag means these tasks are skipped unless
someone names the `migrate` tag on the command line. A normal
`just fleet-update` cannot reach them. This replaces an earlier plan to gate the
migration behind a `--migrate` flag on a shell script, a flag no described
subcommand ever accepted.

## Acquiring node_exporter

The distribution packages cannot satisfy the version requirement. The apt
candidate is 1.3.1 on Ubuntu 22.04 and 1.7.0 on 24.04, against a manifest that
pins 1.12.1, so a package install would reintroduce the "present but stale"
state this design exists to end.

Linux hosts therefore get the upstream release tarball. Download
`node_exporter-<version>.linux-<arch>.tar.gz` from the GitHub release, verify it
against the `sha256sums.txt` published with that release, install the binary to
`/usr/local/bin/node_exporter`, and render the systemd unit. That matches how
the running 1.10.2 was installed, so this is an upgrade in place rather than a
new layout: the unit already lives at `/etc/systemd/system/node_exporter.service`
and already runs as a dedicated `node_exporter` user.

macOS hosts get Homebrew, which installs whatever the formula currently ships
and cannot pin an arbitrary version. Those three hosts are therefore
report-only. The reconciler prints the gap and does not fail the run. Say this
plainly rather than letting the gap table imply an exact-version guarantee the
mechanism cannot deliver.

## Seeing which ports are taken

Twice now this project has been surprised by a port. Grafana sits on 3002
because an unidentified Node process holds 3000 on aorus7, and recon's compose
still binds 3002 so a stray `up` there collides with the fleet stack.

Nothing off the shelf answers "what is bound to 3002". node_exporter ships no
collector for listening sockets, and `node_netstat_*` and `node_sockstat_*` are
aggregate counters. A grafana.com search for listening-port dashboards returns
zero results, because the metric does not exist to build one on. The nearest
published dashboards solve different problems. 14788 "Port General" reads SNMP
switch-interface bandwidth out of InfluxDB, where "port" means a physical
interface. 23614 "Prometheus Net Discovery" does find open ports, but by
scanning the network from outside, so it returns no process names and puts a
recurring sweep on the LAN.

Producing the metric is cheaper than working around its absence. The textfile
collector is compiled into node_exporter and enabled by default; its directory
just defaults to empty, which is why every unit on the fleet currently reads
`ExecStart=/usr/local/bin/node_exporter` and publishes nothing.

The exporter play therefore does three things beyond installing the binary. It
sets `--collector.textfile.directory`. It installs
`scripts/node-listening-ports.sh`. It renders a systemd timer that runs the
script as root every five minutes.

```
node_listening_port{port="3000",addr="0.0.0.0",proc="node"} 1
```

Reading from inside the host is what gets the process name, and it costs no port
scan. Root matters: `ss -p` only names processes the caller owns, so an
unprivileged run reports `proc="unknown"` for everything else, which looks like
data rather than like a permissions problem.

Three details in the script exist because each one silently destroys the metric.
The file is written to a temp name and renamed, because node_exporter reads the
directory on every scrape and a half-written file parses as a truncated metric
set. Addresses are split on the last colon, because `[::]:22` split on the first
yields an empty port and a dropped socket. Identical label sets are deduplicated,
because sshd binding 22 on both IPv4 and IPv6 normalises to one series, and
Prometheus rejects an entire textfile containing a duplicate, so the whole file
would vanish rather than double count.

The dashboard is hand authored and lives in this repo, since no published one
exists. The panel that pays for it is a table of `node_listening_port` grouped
by port and host. Before binding anything, `node_listening_port{port="3002"}`
lists every host already using it.

Running the parser against 44 real sockets from aorus7 produced 44 metric lines,
no duplicates, and no malformed output.

### What the fleet binds today

Captured on 2026-09-01, externally reachable ports only. This is the survey the
metric makes continuous.

| Host | Ports |
| --- | --- |
| aorus | 22 80 3306 4000 4369 5672 6379 9100 9104 9121 15672 15692 25672 |
| aorus2 | 22 4000 6379 7070 9100 9121 |
| aorus4 | 22 80 3000 3101 5005 5056 5432 5435 6379 6543 8000 8010 8080 8082 8083 8084 8096 8401 8402 8443 9100 9121 9876 |
| aorus5 | 22 4000 9100 |
| aorus6 | 22 2379 2380 4000 5000 9000 9100 |
| aorus7 | 22 80 3000 3002 4000 4369 5000 5672 8080 8081 8082 8083 8724 8790 9100 15672 25672 |
| aorus8 | 22 1777 4000 4317 4318 4369 5000 5672 9100 9411 12340 14250 14268 15672 25672 |

Two things worth acting on separately. Port 9121 is redis_exporter, and it runs
on aorus, aorus2, and aorus4, while recon's Prometheus scrapes only the one on
aorus. Two exporters have been running unscraped, which is the roster drift the
inventory-generated config exists to end. And aorus8 is running a tracing stack
on 4317, 4318, 9411, 14250, and 14268, which nothing in this design accounts for.

## The lever

`scripts/observability.sh check` reads the fleet from the control node and
prints desired against actual for every host. It writes nothing.

`check` counts hosts that gave no answer separately from hosts that drifted,
and exits non-zero for either. An earlier version counted only drift, so a host
it could not reach incremented nothing and the run ended green. A fleet that was
entirely down reported success, from the one command this document tells you to
trust. An audit that treats silence as a pass is worse than no audit, because it
is believed.

Convergence itself is not a subcommand. Ansible owns it.

## Capacity, retention, and pinning

Every number here was measured on aorus7 on 2026-09-01.

### A docker volume has no size to set

Volumes on the local driver are directories under `/var/lib/docker`. They grow
until the filesystem fills, and there is no quota. An earlier review asked for
volume sizes, and there is no such setting to write. Retention is the sizing
mechanism, so the bounds live on the applications instead.

### Prometheus

Prometheus carries 20,138 active series at 1,115 samples per second. At roughly
two bytes per compressed sample that is about 193 MB a day, and the three hosts
this design adds bring it to roughly 215 MB a day. It currently runs on the
default 15 day retention with no size bound.

Set both a time bound of 90 days and a size bound of 25 GB. Ninety days is about
19 GB against 788 GB free, so the time bound is what normally applies. The size
bound exists for the failure that time alone cannot catch: one bad label
multiplies series and fills the disk well inside the window. Whichever bound is
hit first wins.

### Loki

Loki has no retention configured, so logs grow forever. It holds 1.3 MB today
only because aorus7 is the sole host shipping logs, and shipping fleet wide
would multiply that.

Set a 30 day period, shorter than the metrics window on purpose. Logs are bulky
per unit of insight and are mostly read within days. Metrics are what you go
back a quarter to compare against.

Loki also ignores its retention period unless the compactor is told to enforce
it, and the compactor is off by default. Setting the period alone produces a
config that reads correct and deletes nothing, so `retention_enabled` and a
`delete_request_store` are set with it.

### Memory limits bound a runaway, they are not a capacity plan

aorus7 has 187 GB of RAM with 98 GB available and 32 cores. All four
observability containers together use 328 MB, which is grafana 133, prometheus
81, loki 73, and promtail 40. A review called this a critical risk of the host
running out of memory. On these numbers it is not.

Limits are still worth setting, at roughly ten times observed usage, so they
never bind in normal running and still cap a cardinality explosion. Prometheus
gets 4 GB because it is the one whose memory scales with series count. Grafana
gets 1 GB, Loki 2 GB, promtail 512 MB. The total ceiling is under 4 percent of
host RAM.

No CPU limits. The cores sit near idle for these services, and a CPU cap adds
latency without preventing any failure observed here.

### Images are pinned by digest

A tag can be repointed on the registry without this repository changing, which
is the drift this design treats as a bug everywhere else. Every service now
carries both a tag, for humans, and a digest, which is what Docker resolves.

One caveat found while resolving them. Recon runs Grafana and Prometheus from
`:latest`, so the version numbers in the manifest were read from the running
binaries rather than from image tags. Pinning those two pulls a different image
object than the one running now, even though the versions match. Loki and
promtail digests are byte-identical to what is live. Treat the Grafana and
Prometheus cutover as a version change to verify, not a no-op.

## Idempotency

Running twice must reach the same state as running once.

`docker volume create` on an existing volume is a no-op, and the volume copy
runs only inside the migration play, which the `never` tag keeps out of every
routine run. A second migration is blocked by the marker file. The exporter
reconciler compares versions before acting. Dashboard sync
validates that a download is JSON carrying the expected `uid` before it hashes
or writes anything, so a 404 body or a rate-limit page cannot overwrite a
working dashboard, and a fetch failure leaves the existing file untouched.

Rendering `prometheus.yml` does not restart Prometheus, because the file is
bind-mounted and neither the compose config nor the image changed. Adding a
fleet host would otherwise report converged and never be scraped. The play
therefore reloads Prometheus over `/-/reload` whenever the rendered content hash
changes, which requires `--web.enable-lifecycle` on the container.

## Migration

This section is rewritten. The previous version was three sentences and an
adversarial review found six defects in it, including a path that would have
deleted another project's dashboards.

The migration transfers ownership of the stack on aorus7 from
`stubhub-recon-gui` to this repo. It stops running containers on a host that
also runs 18 `stubhub-minter` containers, so it runs only when someone asks for
it by name.

### Preconditions, all verified before anything stops

Fail closed. If any check fails, change nothing and report which one.

1. Every `migrate_from` volume in the manifest exists, spelled exactly. Docker
   creates an empty volume for an unknown name instead of failing, so a typo
   would copy nothing and the new stack would come up blank while reporting
   success.
2. `/var/lib/docker` has room for the copy. It is about 92 MB today, against
   788 GB free, so this check exists to catch a full disk rather than a large
   copy.
3. `recon-network` exists.
4. The recon monitoring directory exists at the absolute path in the manifest.
   Compose does not expand `~` in a bind-mount source, and an empty mount
   combined with `disableDeletion: false` makes Grafana delete the 20 dashboards
   it had provisioned.
5. Recon's scrape jobs have already been extracted into the `extra/` directory.
   This is work in the recon repo, not here, and the migration will not proceed
   without it. Skipping it silently drops recon's redis and mysql jobs.
6. A Grafana admin password and a `GF_SECURITY_SECRET_KEY` are available from
   `~/.claude/.env`.
7. Port 3002 is held by `recon-grafana` and nothing else.

### Steps, in this order

1. Create the four `obs_*` volumes with `docker volume create`. Idempotent, and
   a no-op on a second run.
2. Render every config file into `/opt/observability`. Nothing running is
   touched yet, so an interrupt here costs nothing.
3. Stop the four recon containers by name with `docker stop`, never with
   `docker compose down`. Grafana must not be writing to `grafana.db` while it
   is copied, and `compose down` would additionally remove the containers that
   make rollback a single `up` away.
4. Copy each volume's contents into its `obs_*` counterpart with a throwaway
   container, `cp -a` from one mount to the other. The sources are opened read
   only and are never modified. Around 92 MB in total.
5. Bring up the new stack as `obs-grafana`, `obs-prometheus`, `obs-loki`, and
   `obs-promtail`, on the `obs_*` volumes.
6. Health check with a timeout. Grafana `/api/health`, Prometheus `/-/healthy`,
   Loki `/ready`. On failure, stop the `obs-*` stack and start recon's again.
   The original volumes are untouched, so that restores the previous state
   exactly.
7. Write `/opt/observability/.migrated-from-recon` only after the health check
   passes.

The marker is written last on purpose. An interrupt at any earlier point leaves
no marker, so a re-run starts from the preconditions and converges. Steps 3 and
4 are both no-ops when already applied.

### Promtail is adopted, not dropped

The running stack has four containers and an earlier draft defined three, so
`recon-promtail` was stopped and nothing restarted it. Loki would have kept
running with nothing feeding it while this document claimed "Loki and its log
agent stay on the Grafana host".

This repo now owns the promtail container and recon keeps owning its config,
bind-mounted read only. That is the same split already used for dashboards and
scrape jobs, so there is one rule rather than three. Promtail is end of life
upstream and replacing it with Grafana Alloy is deferred, tracked below.

### Separate volumes are what make this reversible

The stack runs on `obs_grafana_data`, `obs_prometheus_data`, `obs_loki_data`,
and `obs_promtail_data`. It does not reuse recon's.

An earlier draft reused the `recon-monitoring_*` volumes and called the survival
of their contents a feature. That was wrong in a way no wording could fix.
Recon's compose declares its volumes bare, with no `external: true`, which makes
them project-owned, so a `docker compose down -v` in that repo deletes them.
Declaring the same volumes `external` on our side stops us from deleting them
and does nothing about recon.

Copying instead of sharing buys three things at once. Recon can run any compose
command it likes without touching fleet data. Our own `down -v` cannot delete
the volumes either, since they are external to us as well. And the untouched
originals are the rollback, a byte-for-byte copy still wired to recon's compose
file.

Rollback is therefore: stop the `obs-*` stack, then `docker compose up -d` in
recon's monitoring directory. No restore step, because nothing was moved. The
manifest also pins every image to what aorus7 runs today, so no schema upgrade
happens that a rollback could not undo.

The two stacks diverge from the moment of cutover, which is expected. Recon's
volumes hold the state as of migration and stop advancing.

### Residual risk this repo cannot close

Recon's compose still binds port 3002 and joins `recon-network`. A routine
`docker compose up` in that repo starts a second Grafana that collides on the
port and shows stale data. That is now a confusing afternoon rather than data
loss, which is the whole gain from copying. Record it in the recon repo, since
writing into another repo's working tree is the practice this design refuses.

The container rename from `recon-*` to `obs-*` also breaks any peer on
`recon-network` that addresses those containers by name. Service names stay
`prometheus`, `loki`, and `grafana`, so DNS by service name keeps working. Audit
the peers before renaming, or keep the old container names, which cost nothing.

### Fix the credentials during the migration, not after

aorus7's Grafana currently runs with `GF_SECURITY_ADMIN_PASSWORD=admin` and
`[auth.anonymous] enabled = true`, bound to `0.0.0.0:3002`. The reused volume
also carries every user, service account, and API key the recon project created,
and its stored datasource secrets are encrypted under Grafana's default key
because no `GF_SECURITY_SECRET_KEY` is set.

Inheriting that while widening the instance from one project's app metrics to
fleet-wide infrastructure data is how a dormant problem becomes a larger one.
The migration sets a real admin password, sets `GF_SECURITY_SECRET_KEY`,
disables anonymous access, and enumerates the inherited accounts and API keys so
you can decide what to keep.

## Tests

`scripts/observability.test.sh` follows the pattern in `scripts/fleet.test.sh`.

The important test asserts that the generated scrape targets equal the output
of `fleet_hosts()`. Drift then fails the suite instead of going unnoticed for
months, which is what happened to the recon target list.

Further tests cover manifest parsing, all seven reconciler outcomes against
recorded version strings, and a second converge run reporting no change.

Two tests exist because the defect they guard already shipped once.

- `check` exits non-zero when a host gives no answer. It did not, and a fleet
  that was entirely down reported success.
- No path in the manifest starts with `~`. One did, and Compose would have
  resolved the mount to an empty directory and let Grafana delete recon's
  dashboards.

A third is required when the playbook lands. Assert that the `migrate` play
carries the `never` tag, so a routine `just fleet-update` cannot restart a live
stack on a busy host. The gate is worthless if a later edit drops the tag.

## Open questions

This section previously read "None. Eight design decisions were settled." Both
halves were wrong. The Decisions section holds seven subsections, and an
adversarial review found roughly fifteen critical defects in a document that
claimed to have none. Treat a self-certified completeness claim as the least
trustworthy sentence in any spec, including this one.

Resolved since that review, by moving convergence into the ansible path:

- The migration gate now uses ansible's `never` tag, so a normal run cannot
  reach it. The earlier `--migrate` flag had no producer.
- `./setup.sh grafana` is deleted rather than guarded. Inventory membership is
  the only way a host gets the stack.
- The playbook is three plays with three host patterns, so installing exporters
  fleet wide no longer contradicts targeting the Grafana host.
- Promtail is adopted instead of orphaned.
- Prometheus is reloaded when the rendered target list changes.
- Dashboard downloads are validated before they overwrite anything.
- The rollback claim is backed by an actual snapshot step.
- Package managers are ruled out with evidence, and the macOS path is stated as
  report-only.

- Retention, memory limits, and digest pinning are all set, from measured
  numbers rather than guesses. Volume size turned out to have no setting to
  write, so retention does that job.

Still open:
- Recon's compose file stays live and still binds port 3002, so a routine
  `docker compose up` there starts a second Grafana that collides on the port
  and shows stale data. It can no longer destroy fleet data, because the two
  stacks no longer share volumes.
- Extracting recon's scrape jobs into `extra/` is a precondition owned by
  another repo. The migration refuses to run until it is done.
- Dashboard downloads are not verified against a pinned checksum, only
  validated as well-formed.
- Cutting Grafana and Prometheus over from `:latest` to a pinned digest is a
  real version change on those two, not a no-op. Verify them after migration.
- node_exporter listens on `:9100` on all interfaces, including a laptop that
  leaves the LAN.
- Replacing Promtail with Grafana Alloy, and shipping logs from more than one
  host.

Separate from this design, and worth doing whether or not any of it ships:
aorus7's Grafana is reachable on the LAN today with anonymous access enabled and
`admin` as the admin password.
