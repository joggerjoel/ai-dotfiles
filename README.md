# claude-dotfiles

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
git clone https://github.com/iamnolanhu/claude-dotfiles.git
cd claude-dotfiles
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

📖 The full story: **[How I ship like a team of one](https://dev.nolanhu.com/blog/2026/06/26/ship-like-a-team-of-one/)** on dev.nolanhu.com. Project page: **[dev.nolanhu.com/projects/claude-dotfiles](https://dev.nolanhu.com/projects/claude-dotfiles/)**.

## Profiles, structure & commands

Two profiles — **Desktop** (full browser tooling, 30 plugins enabled) and **VPS** (headless, 20 plugins, Docker/systemctl perms). Both default to opus + auto mode. Your `~/.claude/CLAUDE.md` is assembled from `base/` + `profiles/<profile>/` + gitignored `.local/`.

```bash
./setup.sh              # Initial setup (profile + skills + plugins + MCP)
./setup.sh add <name>   # Enable a single MCP integration
./setup.sh list         # Integration status
./setup.sh update       # Pull latest and reassemble config
```

No personal info is committed — infrastructure, IPs, and SSH live in gitignored `.local/`. Full architecture, profile details, and the capability map are in **[GETTING-STARTED.md](GETTING-STARTED.md)** (Part 3).

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
