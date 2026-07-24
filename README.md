# ai-dotfiles

> A fine-tuned **AI workforce** you run yourself — one command provisions every machine with the
> skills, models, safety rails, and fleet plumbing that turn a general coding agent into a
> specialized engineering team. Talk to one agent; it does the work.

<p align="center">
  <img src="assets/ai-tooling-overview.png" alt="ai-dotfiles at a glance: the pass (just — one menu that fires every order), firstmate the optional crew manager on top, the base kitchen — 40+ skills, three model tiers, 7 harnesses — and the supply line underneath: ansible + setup.sh + agents-update keeping a chain of 8 machines provisioned, restocked, and health-checked" width="100%" />
</p>

It started as dotfiles. It's now the **config + provisioning + orchestration** layer for running an
AI workforce across a fleet of machines. The name stuck; the scope didn't.

> **Lineage:** forked from **[iamnolanhu/ai-dotfiles](https://github.com/iamnolanhu/ai-dotfiles)**
> (Nolan Hu / Sigma Synapses) — kept its clean one-command provisioning core, then grew a
> model-routing gateway, a multi-agent review pipeline, a node/HUD/worker fleet, and optional crew
> orchestration. Credit + link at the bottom.

> **New here?** Run `./setup.sh`, then open Claude Code and say **`help me get started`** — it walks
> you through building and shipping. Or read **[GETTING-STARTED.md](GETTING-STARTED.md)** first.

## What this is (the two layers)

- **The base — `ai-dotfiles` (required).** Stocks every machine and gives you a working AI toolkit
  that runs on its own: **40+ skills**, **three model tiers**, **7 harnesses**, guardrails, memory,
  and ansible fleet ops. This is the whole system for most work.
- **The crew manager — `firstmate` (optional, on top).** One agent that spawns and supervises many
  agents in parallel, provisioned onto your always-on node by ai-dotfiles. Add it only when
  juggling many jobs at once is the real bottleneck.

The overview image above is the map: base at the bottom, crew manager on top. For the **runtime
view** — the six-layer stack (operator → `just` → provisioning → herdr session → crew → models),
machine roles, and how a typed command flows through it — see
**[docs/orchestration.md](docs/orchestration.md)**.

## What you get

- **One menu for everything** — `just` lists every workflow (herdr, fleet, firstmate, lifecycle);
  each recipe knows _where_ it runs, so you never think about which machine you're on.
- **One-command provisioning** of any machine — CLIs, skills, MCP servers, tokens, safety rails —
  and an **agentic install/maintain lifecycle**: a Setup-hook census plus `/install` and
  `/maintain` prompts that read the logs, close gaps, and carry the known-issues playbook.
- **Persistent sessions on an always-on node** — herdr keeps the crew running when your laptop
  closes; attach from anywhere on the mesh (`just attach`).
- **On-demand multi-agent power commands** — `/fusion`, `/council`, `isolate`, `/ship` — plus a
  40+-skill library (review, plan, design, write, web, dev).
- **Three model tiers, routed by the work** — frontier (subscription), bulk (9router: 458 models
  across 57 providers), and local (ollama).
- **Guardrails baked in** — dangerous commands blocked, risky actions confirmed, telemetry opt-out.
- **A multi-machine fleet** — node / HUD / workers, driven by ansible, pull-based and reproducible.
- **Optional crew orchestration** — talk to one agent (`firstmate`) that runs the rest.

## Power commands — the review pipeline

The multiplier isn't the model; it's the discipline wired around it. These ship by default:

| Command        | What it does                                                                                      |
| -------------- | ------------------------------------------------------------------------------------------------- |
| **`/fusion`**  | Two models answer independently, a third merges them — consensus, divergence, what got discarded. |
| **`/council`** | An 8-lens adversarial audit of a plan or spec before any code is written.                         |
| **`isolate`**  | One cold, zero-context reviewer — finds the gaps an author's own context hides.                   |
| **`/ship`**    | The SHIPIT pipeline: `isolate → council → write-back → isolate` to convergence, then commit.      |

Full write-up: **[FUSE.md](FUSE.md)** (why isolation finds what authors miss) and
**[SHIPIT.md](SHIPIT.md)** (the exact review-and-ship sequence).

## Models & harnesses

**Harnesses** are how you talk to a model; the **model** is the brain. ai-dotfiles installs and
keeps current 7 harnesses (`claude`, `codex`, `pi`, `grok`, `opencode`, `gemini`, `cursor-agent`)
and routes across three model tiers:

| Tier            | For                            | Reached via                                        |
| --------------- | ------------------------------ | -------------------------------------------------- |
| 💎 **Frontier** | hard reasoning, design         | subscription harnesses (Claude, GPT, Grok, Gemini) |
| ⚡ **Bulk**     | cheap/fast mechanical subtasks | **9router** gateway (458 models · 57 providers)    |
| 🏠 **Local**    | private, free to run           | **ollama** on your own machines                    |

**9router** (an internal OpenAI-compatible gateway) and **headroom** (a context-optimization proxy)
are deployed and managed by the ansible layer. Frontier credentials stay _out_ of the gateway by
policy — a leaked gateway key can only spend cheap capacity.

## Quick start (one machine)

```bash
git clone https://github.com/joggerjoel/ai-dotfiles.git
cd ai-dotfiles
./setup.sh
```

Detects your OS, assembles config, installs the skills, offers the plugin stack, walks you through
MCP. Or open Claude Code in the folder and say **"set this up for me."** Drop tokens into
`~/.claude/.env` and the agent becomes the operator — it builds, commits, opens PRs, deploys.

## The launchpad — type `just`

Every workflow in this repo — herdr, fleet ansible, firstmate, install/maintain — is indexed in the
[`justfile`](justfile). How the layers fit together (operator → launchpad → provisioning → session →
crew → models) and how one command flows through them:
**[docs/orchestration.md](docs/orchestration.md)** — the high-level map. The menu itself:

```bash
just                # list every recipe (setup.sh installs `just`; fleet-wide: `just fleet-just`)
just attach         # laptop → the node's herdr session
just captain        # firstmate on the node — you're the captain
just fleet-update   # ansible update across every host
just install-hil    # agentic, human-in-the-loop machine onboarding
```

The justfile is the single source of truth for commands — recipes are documented there, not
duplicated here. New machine or new engineer? `git clone && just install-hil`: the Claude Code
**Setup hook** ([.claude/settings.json](.claude/settings.json)) runs a deterministic tool census
(`claude --init` → `scripts/setup-init.sh`, logged to `~/.claude/logs/setup.log`), then the
`/install` command reads that log, closes the gaps, and walks you through role choices
(HUD / node / worker). `just maintain` is the same pattern for upkeep — report-first, confirm
before mutating. The agentic prompts live in [commands/](commands/) and carry the known-issues
playbook, so second-order fixes live in the repo, not in one engineer's memory.

## The fleet — deployment

The workforce runs across machines with distinct roles, all provisioned from this repo:

| Role                  | Machine (example) | Runs                                                     |
| --------------------- | ----------------- | -------------------------------------------------------- |
| **Node** (always-on)  | macstudio         | `firstmate` + crew + herdr session; the cockpit host     |
| **HUD** (ephemeral)   | MacBook           | an SSH viewport into the node's session — holds no state |
| **Workers** (servers) | aorus fleet       | where server programs run; reached by crewmates over SSH |
| **Gateways**          | aorus4 / aorus8   | 9router + headroom                                       |

Deployment is **pull-based and reproducible**: hosts run `git pull` against this repo, so the flow
is always **commit → push → playbook**. Nothing reaches a host that isn't on `origin/main` first.

```bash
./deploy.sh -m "feat: my change"   # commit, push, and update every target in one shot
./update.sh                        # this machine: Claude Code + sibling CLIs (codex, cursor,
                                   #   cortex, opencode, gemini, pi, grok, headroom) + config
./update.sh --all                  # …then propagate to the fleet via ansible
```

Scoped ansible playbooks (in `ansible-ai/`, each targeting its own inventory group):

| Playbook                                | Targets               | Does                                                              |
| --------------------------------------- | --------------------- | ----------------------------------------------------------------- |
| `update.yml`                            | whole fleet           | Claude + sibling CLIs + config; imports the gateway/proxy refresh |
| `provision-ai.yml`                      | a new host            | first-time install of the base + harnesses                        |
| `deploy-9router.yml`                    | `ninerouter_ai`       | the 9router Docker stack (aorus4/aorus8)                          |
| `deploy-headroom-proxy.yml`             | `headroom_native_ai`  | the headroom proxy (systemd user unit)                            |
| `provision-firstmate.yml`               | `firstmate_ai`        | stand up the always-on **node** (herdr + toolchain + firstmate)   |
| `provision-firstmate-worker.yml`        | `firstmate_worker_ai` | a **worker**: herdr + harnesses for attachable server sessions    |
| `push-config.yml` / `verify-config.yml` | fleet                 | rsync uncommitted config for testing / prove a deploy landed      |

Opt-in, per-machine (never part of a fleet-wide `update`):

```bash
./setup.sh provision-firstmate          # make THIS machine the firstmate node
./setup.sh provision-firstmate-worker   # make THIS machine a firstmate worker
```

Hands-off: `./scripts/fleet-cron-setup.sh` schedules a daily fleet update from the control node.
Full dry-run / per-host detail: **[ansible-ai/README.md](ansible-ai/README.md)**.

**Two things never deploy, by design:** the gitignored personal layer (`.local/`,
`ansible-ai/inventory.local.yml`, `~/.claude/.env`) stays machine-local, and interactive setup
choices travel only if reflected in tracked files — each host replays its own saved answers.

## firstmate — the optional crew manager

[firstmate](https://github.com/kunchenguid/firstmate) is a separate agent distro (a crew
orchestrator). ai-dotfiles doesn't replace it — it **provisions** it: `provision-firstmate.yml`
builds its toolchain (herdr, treehouse, no-mistakes, the axi tools) and clones it onto your node,
and the base's `isolate`/`fusion`/`council` commands become crew skills. You talk to one agent; it
runs the fleet. Integration plan and topology: kept in a sibling
`firstmate-integration` repo. It's genuinely optional — the base is a complete system without it.

## Under the hood — profiles & config assembly

How the dotfiles layer assembles itself (the machinery `just`/`setup.sh` drive for you — most days
you won't touch this directly). Two profiles — **Desktop** (full browser tooling) and **VPS**
(headless, Docker/systemctl perms).
Your `~/.claude/CLAUDE.md` is assembled from `base/` + `profiles/<profile>/` + gitignored `.local/`.

```bash
./setup.sh              # Initial setup (profile + skills + plugins + MCP)
./setup.sh add <name>   # Enable a single MCP integration
./setup.sh list         # Integration status
./setup.sh update       # Pull latest and reassemble config
```

> **Telemetry opt-out vs Remote Control** — the desktop profile ships `DISABLE_TELEMETRY`,
> `DO_NOT_TRACK`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. Claude Code gates feature-flag
> reads behind these, so any one **silently disables Remote Control (`/rc`)**
> ([#4](https://github.com/iamnolanhu/ai-dotfiles/issues/4),
> [anthropics/claude-code#76748](https://github.com/anthropics/claude-code/issues/76748)). Setup
> asks whether you use Remote Control: **y** installs `settings.json` as a copy with those three
> vars stripped; **n** (default) keeps the privacy opt-out and skips `/rc`. Flip later via
> `.local/.remote-control` + `./setup.sh update`. Full walkthrough:
> **[docs/rc-issues.md](docs/rc-issues.md)**.

## Lineage & credit

Forked from **[iamnolanhu/ai-dotfiles](https://github.com/iamnolanhu/ai-dotfiles)** by
**Nolan Hu / [Sigma Synapses](https://sigmasynapses.com)** — the one-command provisioning core,
profile system, and much of the ansible fleet plumbing are his. This fork adds the model-routing
gateway, the multi-agent review pipeline, the node/HUD/worker topology, and the firstmate
integration. If the upstream helped you, star it.

## License

MIT. Use it, fork it, ship with it.
