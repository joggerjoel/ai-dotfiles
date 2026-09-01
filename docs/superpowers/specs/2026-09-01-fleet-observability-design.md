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
| Compose | `/opt/observability/docker-compose.yml` | The named volumes and `recon-network`, both declared `external: true` |

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
scripts/
  observability.sh                      the audit lever
  observability.test.sh
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
node_exporter everywhere.

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

## Idempotency

Running twice must reach the same state as running once.

The exporter reconciler compares versions before acting. Dashboard sync
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

1. The three named volumes exist exactly as spelled in the manifest. A
   mismatched name makes Docker create a new empty volume instead of failing,
   which is a silent path to the data loss this migration promises cannot
   happen.
2. `recon-network` exists.
3. The recon monitoring directory exists at the absolute path in the manifest.
   Compose does not expand `~` in a bind-mount source, and an empty mount
   combined with `disableDeletion: false` makes Grafana delete the 20 dashboards
   it had provisioned.
4. Recon's scrape jobs have already been extracted into the `extra/` directory.
   This is work in the recon repo, not here, and the migration will not proceed
   without it. Skipping it silently drops recon's redis and mysql jobs.
5. A Grafana admin password and a `GF_SECURITY_SECRET_KEY` are available from
   `~/.claude/.env`.
6. Port 3002 is held by `recon-grafana` and nothing else.

### Steps, in this order

1. Snapshot `grafana.db` and the Prometheus and Loki volume metadata into
   `/opt/observability/backup/<timestamp>/`. This is what makes the rollback
   claim true. The earlier draft asserted reversibility without ever taking a
   copy.
2. Render every config file into `/opt/observability`. Nothing running is
   touched yet, so an interrupt here costs nothing.
3. Stop the three containers this repo replaces. Use `docker stop` on
   `recon-grafana`, `recon-prometheus`, and `recon-loki` by name, never
   `docker compose down`, which would also take `recon-promtail` with it.
4. Bring up the new stack as `obs-grafana`, `obs-prometheus`, `obs-loki`, and
   `obs-promtail`.
5. Health check with a timeout. Grafana `/api/health`, Prometheus `/-/healthy`,
   Loki `/ready`. A failure here restores from step 1 and stops.
6. Write `/opt/observability/.migrated-from-recon` only after the health check
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

### What rollback actually restores

Stop the `obs-*` stack, restore `grafana.db` from the step 1 snapshot, then
bring recon's compose file back up. The image versions in the manifest are
pinned to exactly what aorus7 runs today, specifically to avoid a Loki schema
upgrade that no snapshot can reverse.

### Residual risk this repo cannot close

Recon's compose file still declares the same volumes and the same port. A
routine `docker compose up` in that repo starts a second Grafana against the
same data, and a `docker compose down -v` there destroys fleet metrics and
dashboards. Nothing in this repository can prevent that, because writing into
another repo's working tree is the practice this whole design refuses. Record it
in the recon repo instead, and treat the step 1 snapshot as the mitigation.

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

Still open:

- Retention, volume sizes, and container resource limits are unspecified.
  Prometheus and Loki share a host with 18 other containers.
- Recon's compose file stays live and can start a duplicate Grafana or destroy
  the shared volumes with `down -v`. This repo cannot close that.
- Extracting recon's scrape jobs into `extra/` is a precondition owned by
  another repo. The migration refuses to run until it is done.
- Container images are pinned by mutable tag rather than by digest, which is the
  drift class this design otherwise treats as a bug.
- Dashboard downloads are not verified against a pinned checksum, only
  validated as well-formed.
- node_exporter listens on `:9100` on all interfaces, including a laptop that
  leaves the LAN.
- Replacing Promtail with Grafana Alloy, and shipping logs from more than one
  host.

Separate from this design, and worth doing whether or not any of it ships:
aorus7's Grafana is reachable on the LAN today with anonymous access enabled and
`admin` as the admin password.
