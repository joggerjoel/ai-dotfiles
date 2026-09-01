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
  deploy-observability.yml              the playbook
  templates/
    observability.compose.yml.j2
    prometheus.yml.j2
    grafana-datasources.yml.j2
    grafana-providers.yml.j2
    node_exporter.service.j2
scripts/
  observability.sh                      the lever
  observability.test.sh
```

## The lever

`scripts/observability.sh` carries three subcommands.

`check` reads the fleet and prints desired against actual for every host. It
writes nothing. Run it to audit the work rather than trusting a summary.

`sync-dashboards` fetches each pinned revision from
`https://grafana.com/api/dashboards/<gnet_id>/revisions/<revision>/download`,
rewrites the `DS_*` input to the `prometheus` datasource uid, and compares
content hashes before writing. An unchanged dashboard causes no write and no
Grafana reload.

`converge` applies the manifest.

## Entry points

To deploy across the fleet, run `ansible-playbook deploy-observability.yml`.

To provision the machine you are sitting on, run `./setup.sh grafana`. It
mirrors `provision-firstmate`, which the dispatch block documents as opt-in and
never part of `setup.sh` or `setup.sh update`. The command also accepts
`--setup=grafana`, because that is the form the request used, though the house
style in this repo is a positional subcommand.

`update.sh` gains a step that refreshes dashboards from the manifest. The step
runs only on the observability host. Under `--all`, `update.yml` imports the
playbook behind an `observability` tag, so `--skip-tags observability` turns it
off.

## Idempotency

Running twice must reach the same state as running once.

The exporter reconciler compares versions before acting. `docker compose up -d`
recreates a container only when its config or image changes. The compose file
declares the existing volumes `external: true`, so Grafana dashboards, users,
and Prometheus history survive the rename. Dashboard sync compares content
hashes. The one-time migration writes a marker file at
`/opt/observability/.migrated-from-recon` and checks it before running.

## Migration

Taking ownership stops four running containers and starts them under new
names. `docker compose down` runs without `-v`, so the volumes and their data
survive. Restarting the recon compose file reverses it.

`aorus7` also runs 18 `stubhub-minter` containers. The migration does not touch
them, but it does restart a live monitoring stack on a busy host. Gate it
behind an explicit `--migrate` flag and a confirmation prompt. It must never
run as a side effect of a normal update.

## Tests

`scripts/observability.test.sh` follows the pattern in `scripts/fleet.test.sh`.

The important test asserts that the generated scrape targets equal the output
of `fleet_hosts()`. Drift then fails the suite instead of going unnoticed for
months, which is what happened to the recon target list.

Further tests cover manifest parsing, the three reconciler outcomes against
recorded version strings, and a second `converge` run reporting no change.

## Open questions

This section previously read "None. Eight design decisions were settled." Both
halves were wrong. The Decisions section holds seven subsections, and an
adversarial review found roughly fifteen critical defects in a document that
claimed to have none. Treat a self-certified completeness claim as the least
trustworthy sentence in any spec, including this one.

Open questions now tracked, none of them resolved:

- The `--migrate` gate has no producer. No subcommand or entry point accepts it.
- `./setup.sh grafana` has no check that the machine belongs to
  `observability_ai`, which reintroduces the unconstrained-targeting mistake
  this document cites against itself.
- Recon's scrape jobs live inline in its own `prometheus.yml`. Nothing extracts
  them into `extra/*.yml`, and this repo is not allowed to write them.
- Promtail is stopped by the migration and nothing restarts it.
- The reused volumes stay declared by recon's compose project, so a `down -v`
  there destroys fleet data.
- Retention, volume sizes, and container resource limits are all unspecified.
- Rewriting `prometheus.yml` does not restart the container, so a new host is
  reported converged and never scraped until someone reloads Prometheus.
- Grafana on aorus7 currently runs with a default admin password and anonymous
  access enabled. Taking ownership must fix that rather than inherit it.
