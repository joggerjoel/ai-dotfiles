# ai-dotfiles

> Turn Claude Code into an AI engineering team that plans, builds, tests, and ships real software — even if you've never written a line of code.

**[dev.nolanhu.com](https://dev.nolanhu.com)** · **[Sigma Synapses](https://sigmasynapses.com)** · **[github.com/iamnolanhu](https://github.com/iamnolanhu)** · **[@nolanhu](https://x.com/nolanhu)**

This is the actual agentic setup I use to run [Sigma Synapses](https://sigmasynapses.com) — one founder who ships real client AI agents, runs production, and talks to clients directly. It's portable: one repo, one command, works on a laptop or a headless VPS. Clone it, run `./setup.sh`, and you get the same engine.

Like a ghost in the shell, it sees beyond the data — and it's wired to make you fast.

> **New here?** After `./setup.sh`, open Claude Code and say **`help me get started`** — it walks you through building and shipping with zero coding experience. Or read **[GETTING-STARTED.md](GETTING-STARTED.md)** first.

## What you get

- **S**hip real software by describing what you want in plain words
- **I**nstall a full agentic stack — skills, plugins, MCP servers — in one command
- **G**uardrails that verify before "done," checkpoint your work, and confirm before anything risky
- **M**emory that persists across sessions, so you never re-explain a project
- **A**gents that plan, build, test, review, and deploy — routed automatically by the work

## Ship like a 100x engineer

Here's the reality: the multiplier isn't the model — any tool can call a model. It's the **discipline wired around it**. This repo ships that discipline by default:

- **A 15-plugin core** auto-installs the engine: brainstorming, test-driven development, systematic debugging, planning, multi-file feature dev, code review, persistent memory, browser-driven verification.
- **An onboarding orchestrator** (`getting-started`) detects what you're building and routes you through plan → build → verify → review → ship — narrating every step in plain language.
- **Best model by default** (opus) and **auto-accept mode** on, so you spend turns building, not approving.
- **Guardrails baked in**: nothing is "done" until it's run and shown working; working states are auto-committed; risky actions (spend, deploy, delete, secrets) require confirmation.

It's not a promise — it's how the work actually gets done below.

## Quick start

```bash
git clone https://github.com/iamnolanhu/ai-dotfiles.git
cd ai-dotfiles
./setup.sh
```

The installer detects your OS, assembles your config, installs the skills, creates a `~/Developer/Git` workspace, offers the plugin stack, and walks you through MCP setup. Full walkthrough: **[GETTING-STARTED.md](GETTING-STARTED.md)**.

**Or just ask the AI to set it up.** Open Claude Code in the cloned folder and say **"set this up for me."** It reads the repo and runs the steps for you — fewer mistakes than copy-pasting a script by hand.

**Give it your own API tokens so it actually runs the work.** Drop your tokens (GitHub, DigitalOcean, Vercel, and so on) into `~/.claude/.env`, and Claude becomes the operator, not just the author — it runs the build, commits, opens PRs, deploys, and provisions servers itself. Only add tokens you're comfortable letting it use.

## The agentic stack

| Layer                   | What you get                                                                                                                                                                     |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Layered `CLAUDE.md`** | Generic base + machine profile + gitignored personal overlay                                                                                                                     |
| **Skills** (`skills/`)  | Onboarding router, design taste, UI sourcing (react-bits/uiverse), color strategy, verify, test-and-fix, review, responsive audit, and more — installed into `~/.claude/skills/` |
| **Plugins**             | A 15-plugin core auto-installs; optional groups (backend, automation, code-intelligence, authoring, writing) are opt-in. `./scripts/bootstrap-plugins.sh`                        |
| **MCP servers**         | context7, serena, chrome-devtools, firecrawl, github, and more — picked interactively                                                                                            |
| **Statusline + hooks**  | Model, context %, cost, git state at a glance; prettier-on-write; subagent cleanup                                                                                               |

Run it your way:

```bash
./scripts/bootstrap-plugins.sh             # core + prompt for optional groups
./scripts/bootstrap-plugins.sh --core-only # core only, no prompts
claude plugin list                         # what's installed
```

## How Sigma Synapses ships with this

This isn't a demo config — it's production tooling for a real AI agency. Here's what it runs under the hood at [Sigma Synapses](https://sigmasynapses.com):

- **Monorepo + worktree discipline** — one Turborepo for products, services, and infra; isolated `.worktrees/{area}` per workstream, so parallel features never clobber each other.
- **Custom shipping skills** — `/implement-feature`, `/fix-bug`, `/add-endpoint`, `/add-migration`, `/create-pr` — the repetitive parts of the loop, automated.
- **Auto-changelog on merge** — patch bump to dev, minor to main, no manual tracking.
- **Design-system enforcement** — one source of truth for components and tokens; hardcoded colors get blocked.
- **Postmortem discipline** — every incident logged with diagnostics, so the same bug never costs twice.
- **The AI runs the operations** — with my own API tokens in `~/.claude/.env`, Claude doesn't just write code; it runs the build, commits, opens the PR, and deploys. The operator, not just the author.

One founder writes the code, runs production, and talks to clients — no handoffs. This repo is how that's possible. _Streamline the Future._

📖 The full story: **[How I ship like a team of one](https://dev.nolanhu.com/blog/2026/06/26/ship-like-a-team-of-one/)** on dev.nolanhu.com. Project page: **[dev.nolanhu.com/projects/ai-dotfiles](https://dev.nolanhu.com/projects/ai-dotfiles/)**.

## Profiles, structure & commands

Two profiles — **Desktop** (full browser tooling, 30 plugins enabled) and **VPS** (headless, 20 plugins, Docker/systemctl perms). Both default to opus + auto mode. Your `~/.claude/CLAUDE.md` is assembled from `base/` + `profiles/<profile>/` + gitignored `.local/`.

```bash
./setup.sh              # Initial setup (profile + skills + plugins + MCP)
./setup.sh add <name>   # Enable a single MCP integration
./setup.sh list         # Integration status
./setup.sh update       # Pull latest and reassemble config
```

> **Telemetry opt-out vs Remote Control** — the desktop profile ships `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. Claude Code gates feature-flag reads behind these vars, so any one of them **silently disables Remote Control (`/rc`)** and other flag-gated features, even on eligible accounts ([#4](https://github.com/iamnolanhu/ai-dotfiles/issues/4), [anthropics/claude-code#76748](https://github.com/anthropics/claude-code/issues/76748)). Setup asks whether you use Remote Control: answer **y** and `settings.json` is installed as a _copy_ with those three vars stripped (Claude Code telemetry back on); answer **n** (the default) to keep the privacy opt-out and skip `/rc`. Flip the choice later by editing `.local/.remote-control` (`yes`/`no`) and running `./setup.sh update`. The other telemetry vars (`DISABLE_ERROR_REPORTING`, `NEXT_TELEMETRY_DISABLED`, `TURBO_TELEMETRY_DISABLED`, `VERCEL_TELEMETRY_DISABLED`, `CLAUDE_MEM_TELEMETRY`) are not part of the gate and always stay off. Full symptom/fix walkthrough incl. per-host fleet commands: **[docs/rc-issues.md](docs/rc-issues.md)**.

No personal info is committed — infrastructure, IPs, and SSH live in gitignored `.local/`. Full architecture, profile details, and the capability map are in **[GETTING-STARTED.md](GETTING-STARTED.md)** (Part 3).

## Updating

The one-command path — commit, push, and update every target, runnable from
any directory (it resolves the repo from its own location):

```bash
./deploy.sh -m "feat: my change"   # or bare ./deploy.sh when already committed
./deploy.sh --check                # extra args pass through to ansible-playbook
```

Or the three layers individually:

```bash
./update.sh             # Binaries: Claude Code + the sibling agent CLIs
                        # (codex, cursor-agent, cortex, opencode, gemini).
                        # Snapshots config to backup/<timestamp>/ with a
                        # generated rollback.sh first. Offers to install
                        # missing CLIs when run interactively.
./update.sh --all       # Same, then propagates to the fleet servers via
                        # ansible-ai/update.yml --limit aorus_ai. Binaries +
                        # config everywhere in one command (servers pull
                        # origin/main — push config changes with deploy.sh).
./setup.sh update       # Config: git pull + reassemble CLAUDE.md/settings
                        # + refresh the plugin/skill stack
```

```bash
cd ansible-ai && ansible-playbook update.yml   # Fleet: both layers on every
                                               # server + this machine
```

**Hands-off option:** schedule the whole thing from the control node — one
cron entry here updates every computer daily; individual targets need nothing:

```bash
./scripts/fleet-cron-setup.sh            # daily at 6:15 (CRON_HOUR/CRON_MIN to change)
tail -f ~/.claude/.changelog/fleet-update.log
```

There's also a **push mode** for testing uncommitted config fleet-wide with no
GitHub round-trip — it rsyncs this machine's working tree to the servers and
re-applies without git (the next pull-based update reverts anything you never
committed):

```bash
cd ansible-ai && ansible-playbook push-config.yml [--limit host]
```

And a **verify step** that proves a deploy actually landed — asserts per host
that the repo is at origin/main, the profile answers are saved, settings are
a stripped copy (Remote Control unblocked, `remoteControlAtStartup` on), and
the binary responds:

```bash
cd ansible-ai && ansible-playbook verify-config.yml
```

The fleet path is pull-based: each host runs `git pull` against this repo, so
the flow is always **commit → push → playbook** — nothing reaches a host that
isn't on `origin/main` first. Details, dry-run, and per-host targeting:
**[ansible-ai/README.md](ansible-ai/README.md)**.

### Deploying changes to the fleet

Local `./setup.sh` and the fleet's unattended runs are the same engine: each
server replays `setup.sh update` with its saved profile answers, so whatever
setup produces from the repo (CLAUDE.md assembly, settings, skills, plugins,
MCP config) lands identically everywhere.

| You changed…                                                    | Deploy with                                                                                            |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Anything in the repo (skills, profiles, CLAUDE.md, plugin list) | commit → push → `ansible-playbook update.yml`                                                          |
| Nothing — just want latest binaries/plugins everywhere          | `ansible-playbook update.yml` alone                                                                    |
| Added a **new server**                                          | add it to `ansible-ai/inventory.local.yml`, then `ansible-playbook provision-ai.yml -K --limit <host>` |

Two things never deploy, by design: the gitignored personal layer (`.local/`,
`ansible-ai/inventory.local.yml`, `~/.claude/.env`) stays machine-local, and
interactive setup choices travel only if they're reflected in tracked files —
each host replays its own saved answers, not yours.

## More from the lab

Other open-source tools from the same workbench:

- **[digitalocean-skills](https://github.com/iamnolanhu/digitalocean-skills)** — Claude Code skills for DigitalOcean infra
- **[traefik-starter](https://github.com/iamnolanhu/traefik-starter)** — production-ready Traefik + Docker Compose stack
- **[namecheap_scripts](https://github.com/iamnolanhu/namecheap_scripts)** — manage DNS subdomains from the CLI

## Who built this

**Nolan Hu** — founder of [Sigma Synapses](https://sigmasynapses.com). Ex-developer at JPMorgan, HSBC, and BNY Mellon; now building AI agents that work in the real world. Brooklyn-based, still uses vim.

Want to build something together, or have AI agents handle your customer conversations? → [sigmasynapses.com](https://sigmasynapses.com) · [dev.nolanhu.com](https://dev.nolanhu.com) · [@nolanhu](https://x.com/nolanhu)

## License

MIT. Use it, fork it, ship with it. If it helped, a star or a link back is appreciated.

---

<sub>⟡ built in the shell by **Nolan Hu / Sigma Synapses** · _Streamline the Future._</sub>

<!-- build: 0xBdf1980e7Fc57DBE03874C29c203C3dff576D40c -->
