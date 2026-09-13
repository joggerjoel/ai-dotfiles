# Provision Herdr Temporal workers

`ai-dotfiles` installs worker releases and checks readiness. The separate
`herdr-orchestrator` project owns execution. Temporal and its persistent database
stay on aorus4. This integration does not deploy another Temporal server, launch
agents, copy credentials, enroll machines, or migrate active work.

## Build a reviewed release

Until the orchestrator has its own release repository, distribute a checksummed
source bundle from the control checkout. The bundle contains allowlisted Python
modules, the runtime requirements, a machine template, and the launcher. It
excludes tests, synthetic smoke scripts, real machine configuration, queues,
receipts, virtual environments, and credentials. Review source before building:
a checksum proves artifact identity, not code safety or publisher authenticity.

```sh
cd ~/Developer/ai-dotfiles
just herdr-temporal-bundle "$HOME/Developer/herdr-orchestrator" /tmp/herdr-worker.tar.gz
```

Save the reported SHA-256 alongside the artifact. Bundle bytes are deterministic
for the same source content. Python 3.11 patch releases and transitive dependencies
are not fully locked yet; this is a source pin, not a bit-reproducible environment.

## Install locally or on one selected host

Prerequisites on the execution host are Python 3, `uv`, the `ai-dotfiles` checkout
with its packet validator, Herdr, Git, and the chosen coding CLI. Use the existing
Herdr provisioner for the binary, independently of this worker install:

```sh
cd ~/Developer/ai-dotfiles/ansible-ai
ansible-playbook provision-herdr.yml --limit HOST
```

Replace `HOST` with an inventory host you intend to change. The Herdr playbook
skips upgrades while its server is running. The worker provisioner expects `uv`
already installed; it does not silently install system dependencies.

For a local worker release:

```sh
cd ~/Developer/ai-dotfiles
just herdr-temporal-install /tmp/herdr-worker.tar.gz SHA256
# Equivalent setup entry point:
./setup.sh provision-herdr-temporal --artifact /tmp/herdr-worker.tar.gz --sha256 SHA256
```

For one fleet host, using the same control-machine artifact:

```sh
just fleet-temporal HOST /tmp/herdr-worker.tar.gz SHA256
```

Replace `SHA256` with the actual 64-character digest. Fleet commands require the
control machine's existing `ansible-ai/inventory.local.yml`. Nothing is published
to GitHub and nothing runs against other hosts unless selected by the limit.

Default installation path is `~/.local/share/herdr-temporal`. Each source digest
has its own release directory and `.venv`. Activation changes `current` only after
dependency installation and CLI help succeed. Launchers resolve that symlink to
an absolute release path before execution. Existing processes continue using the
old release; installation never restarts them. Failed release directories remain
available for inspection. Repeating a successful install reports `changed: false`.

Do not remove old releases while processes still use them. Automatic cleanup,
worker draining, and handoff are not implemented.

## Configure this host inside Herdr

Use the installed launchers:

```sh
export PATH="$HOME/.local/share/herdr-temporal/bin:$PATH"
herdr-master --help
herdr-temporal --help
```

Create this machine's supervisor-owned profile under
`~/.herdr-temporal/local/machines/local/`. Use
`~/.local/share/herdr-temporal/current/MACHINE.template.md` as the starting
template, filling in real repository paths, verification commands, pane names,
and an exhaustion pattern for the chosen CLI kind. Create its approved `TODO.md`
queue. Never copy another host's profile trust, enrollment marker, SQLite files,
receipt store, or pane IDs. Keep this state outside agent-writable worktrees.

From inside this host's managed Herdr session, bind the actual panes and trust the
configuration before starting the worker. Refer to the orchestrator's
`guides/temporal-herdr.md` for the profile schema and complete setup sequence.
Use `herdr-master --root "$HOME/.herdr-temporal/local"` for those setup commands.
Verify subscription authentication in the coding CLI separately. This installer
does not copy login files, create API keys, or choose a billing fallback.

The existing Temporal API binds to aorus4's loopback interface. Each other host
needs authorized SSH access to aorus4. Keep a tunnel open on the execution host:

```sh
ssh -NT -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -L 127.0.0.1:7233:127.0.0.1:7233 aorus4
```

On aorus4 itself, use `localhost:7233` without this tunnel. These are manual
connection instructions, not a service created by provisioning. No SSH config
or keys are copied. Do not expose the unauthenticated evaluation API publicly.

In a managed Herdr shell pane on the execution host:

```sh
herdr-temporal worker --profile local --kind codex
```

Submit from another shell on that same host after enrollment:

```sh
herdr-temporal submit --profile local --kind codex --run-id HOST-task-001 --wait
```

The queue name incorporates this host's enrollment UUID, profile, and agent kind.
Use unique workflow IDs across the shared namespace. Submission still reads
local approved Markdown files. Centralized remote submission, task migration,
and automatic reconciliation remain separate work. Worker timeouts do not kill
external agents; inspect unknown outcomes locally instead of deleting receipts.

## Check readiness without launching anything

```sh
just herdr-temporal-check
./setup.sh check-herdr-temporal --offline
just fleet-temporal-check HOST
```

The checker validates installed code, binaries, the packet validator, trusted
profile, repository/base ref, queue, recorded pane bindings, enrollment, receipts,
and the Temporal API/namespace. It opens existing databases read-only. It never
creates state, enrolls a worker, submits a workflow, or inspects live Herdr panes.
Exit 2 means missing setup or an unverified check. `--offline` therefore exits 2.
Even `configuration-ready` does not certify dispatch readiness: subscription
authentication and live panes are explicitly reported as not checked.

The fleet checker sends the control checkout's script over stdin. It requires no
checkout update or checker installation on the target. Inspection may report
configuration-ready while the worker is stopped; it is not a liveness monitor.

## Opt in to later updates

Plain setup/update commands do not install workers by default. For a local update,
set both `HERDR_TEMPORAL_ARTIFACT` and `HERDR_TEMPORAL_SHA256` when invoking
`./update.sh`. `--dry-run` and `--claude-only` do not install the worker release.
Use `HERDR_TEMPORAL_PREFIX` to override the local installation location.

For `just fleet-update`, explicitly configure selected hosts in the private
inventory with `herdr_temporal_enabled: true`, `herdr_temporal_artifact` pointing
to an absolute control-machine file, and `herdr_temporal_sha256`. Optional values
are `herdr_temporal_prefix`, `herdr_temporal_cache`, `herdr_temporal_root`, `herdr_temporal_profile`,
`herdr_temporal_kind`, `herdr_temporal_address`, and `herdr_temporal_namespace`.
The root/profile/address values configure readiness checks, not runtime enrollment.

Full fleet updates also perform unrelated maintenance. Use `fleet-temporal` for
the narrow installation. There is no literal `just fleet` recipe. Neither path
automatically switches running workers to a new release.

## Tests

```sh
bash scripts/herdr-temporal.test.sh
```

This fixture-only suite is discovered by `just test-all` and CI. It does not use
real coding agents or install packages. A temporary real-package installation is
a separate integration check and does not establish real-agent completion.

Observed local verification on September 13, 2026:

- 15 focused tests passed, including an isolated import of the actual source bundle.
- A real bundle installed dependencies and passed CLI help in a temporary prefix.
- The localhost-only Ansible fixture installed successfully. Its repeat run
  reported `changed=0`, `failed=0`.
- The readiness playbook reported `changed=0` and failed as expected for the
  fixture's missing supervisor profile. No supervisor root was created.
- No remote fleet host was deployed and no agent was launched. A selected-host
  pilot and real-agent verification remain outstanding.
