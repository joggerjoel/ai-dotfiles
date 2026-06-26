# Getting Started

Welcome. This toolkit turns Claude Code into an AI engineering team that can **plan, build, test, and ship real software for you** — whether you've written a thousand programs or zero.

This guide has three layers. Read the one that fits you (or all three):

- **[Part 1 — You don't need to code](#part-1--you-dont-need-to-code)** — start here if you've never built software.
- **[Part 2 — The map](#part-2--the-map)** — what the toolkit can actually do, and the workflow it follows.
- **[Part 3 — Power user / developer](#part-3--power-user--developer)** — architecture, profiles, and how to extend it.

> **The one thing to remember:** open Claude Code in a folder and say **`help me get started`**. That triggers a guided on-ramp that walks you through everything below. You don't have to memorize any of this.

---

## Part 1 — You don't need to code

You really don't. You describe what you want in plain words; the assistant does the building, testing, and shipping.

### Before you begin (one-time setup)

This guide assumes Claude Code is **already installed** and you've run `./setup.sh` once. If you haven't:

1. Install Claude Code — follow the official instructions: <https://docs.anthropic.com/en/docs/claude-code/setup> (it needs Node.js; the installer walks you through it).
2. Clone this toolkit and run setup — see the **Quick start** in the [README](README.md): `git clone …`, then `./setup.sh`.

Done that already? Continue below.

### How to begin

Open a terminal first (on Mac: the **Terminal** app; on Windows: use **WSL — Windows Subsystem for Linux**; if you're on Windows and unsure, search "install WSL" first). Then copy-paste these one at a time:

```bash
cd ~/Developer/Git   # your projects folder (setup created this for you)
mkdir my-project     # makes a folder for your idea
cd my-project        # moves into that folder
claude               # starts the assistant
```

Once it's running, type:

> **`help me get started`**

That's it. From there it will:

- Tell you in one sentence what you've got.
- Ask **"Have you coded before?"** — answer honestly. Saying "no" just means it explains more as it goes. There's no wrong answer and no judgment.
- Ask **"What do you want to build?"** — say it however you'd say it to a friend: "a website for my bakery," "a tool that emails me the weather every morning," "an app to track my workouts." It will pick the right technology **for you** so you never have to choose blind.

### How to talk to it

Plain language wins. You don't need technical words.

- ✅ "Make the button blue and bigger."
- ✅ "Add a page where people can leave a message."
- ✅ "This looks wrong on my phone — fix it."
- ✅ "I don't understand what that means — explain it simpler."

If something isn't what you wanted, just say so. It can always change things or rewind — to undo, simply say **"undo that"** or **"go back to before that change."**

### The safety nets (why you can relax)

The assistant is set up so a beginner can't easily break things:

- **It saves your progress automatically.** Every time something works, it quietly takes a snapshot (a "commit"). If a later change breaks something, you can go back to a working point. You'll never silently lose your work.
- **It checks its own work.** It won't tell you something is "done" until it has actually run it and seen it work. No empty promises.
- **It warns you before anything risky.** Before it does anything that could **cost money, go live to the public, or delete something**, it stops, explains in plain words what's about to happen, and waits for you to say yes.
- **It explains as it goes** — at whatever level you asked for.

### What to expect

It works in small steps: decide one thing, do it, show you it works, save it, move on. You stay in control the whole time — you're the one saying what to build; it handles how. When it's finished a piece, it shows you the real result (a live web page, a running app, actual output), not just a claim that it's done.

When you want to change something later, you don't reopen this guide — just describe the change. And you can always say **`help me get started`** again to get back on the rails.

Curious what else it can do? **[Part 2](#part-2--the-map)** maps it out — but you never need it to start.

---

## Part 2 — The map

Here's what's actually under the hood. Everything below is installed by `./setup.sh` (the core stack auto-installs; optional groups are opt-in).

### The golden workflow

The assistant follows a disciplined loop. The `help me get started` on-ramp routes you through it automatically, but it's the same loop a senior engineer would use:

```
brainstorm  →  plan  →  build  →  verify  →  review  →  ship
   │            │         │         │          │          │
 scope the    turn it   write the  prove it   catch      run / deploy,
 vague idea   into      code       works      bugs &     show it live
              steps     (TDD)      (test it)  security
```

At every step the same four guardrails apply: **verify before "done," auto-commit working checkpoints, plain-language narration, and confirm before anything risky** (spend / deploy / delete / secrets).

### Capability map (what's installed)

**The shipping engine** (core — always installed):

| Capability                                          | Skill / plugin                                       |
| --------------------------------------------------- | ---------------------------------------------------- |
| Scope a vague idea before building                  | `superpowers:brainstorming`                          |
| Turn a spec into a step-by-step plan                | `superpowers:writing-plans`                          |
| Build a feature with architecture focus             | `feature-dev`                                        |
| Test-first development                              | `superpowers:test-driven-development`                |
| Root-cause debugging                                | `superpowers:systematic-debugging`                   |
| Isolated workspaces for big changes                 | `superpowers:using-git-worktrees`                    |
| Full verification (typecheck, lint, test, build)    | `verify`                                             |
| Run tests, diagnose failures, auto-fix them         | `test-and-fix`                                       |
| Pull structured data from websites (LLM scraping)   | `scrapegraph`                                        |
| Review a diff/PR for bugs & cleanups                | `code-review`, `pr-review-toolkit`, `review-changes` |
| Simplify code after it works                        | `code-simplifier`                                    |
| Clean git commits / push / PR                       | `commit-commands`, `quick-commit`                    |
| Engineering discipline (think first, stay surgical) | `andrej-karpathy-skills`                             |
| Security guidance & review                          | `security-guidance`                                  |
| Browser automation + UI verification                | `agent-browser`, `verify-ui`                         |
| **Persistent memory across sessions**               | `claude-mem`                                         |
| Second opinion / rescue                             | `codex`                                              |
| Create your own skills                              | `skill-creator`                                      |
| TypeScript code intelligence                        | `typescript-lsp`                                     |

**Design & UI** (for anything visual):

| Capability                                               | Skill / plugin     |
| -------------------------------------------------------- | ------------------ |
| UI/UX vocabulary: styles, palettes, font pairs, UX rules | `ui-ux-pro-max`    |
| Taste, motion, polish, anti-slop                         | `design-taste`     |
| Color systems (60/30/10, OKLCH, WCAG contrast)           | `color-strategy`   |
| Production-grade whole layouts / pages                   | `frontend-design`  |
| Pre-built animated React components                      | `react-bits`       |
| Small copy-paste UI primitives (any stack)               | `uiverse`          |
| Mobile / responsive audit                                | `responsive-audit` |

**Optional groups** (opt-in during setup, reversible anytime):

- **Backend & data** — `supabase` (database/auth), `stripe` (payments), `pg` (Postgres / pgvector design).
- **Automation & research** — `autoresearch`, `n8n-mcp-skills`, `ralph-loop`.
- **Code intelligence** — `serena` (semantic navigation), `chrome-devtools-mcp`.
- **Authoring & meta** — `plugin-dev`, `hookify`, `agent-sdk-dev`, `claude-md-management`, `claude-code-setup`.
- **Writing & output** — `elements-of-style`, `learning-output-style`, plus the local `humanizer` skill.

_Also included:_ reasoning and meta skills (`first-principles`, `explore-plan-code-test`, `feature-gap-audit`, `reflection`, `context-dump`) — see the full local-skill list in [Part 3](#the-enabled-plugin-set-desktop).

### How persistent memory works

The `claude-mem` plugin gives the assistant memory that **survives across sessions** — it can recall how you solved something last time or what a project is about, even days later. Durable facts about your projects also live in `CLAUDE.md` (instructions) and an auto-maintained `MEMORY.md`, both re-loaded every session. You don't manage any of this manually; just know that "remember this" actually sticks.

---

## Part 3 — Power user / developer

### Architecture

This is a portable Claude Code config. Your effective `~/.claude/CLAUDE.md` is **assembled from three layers** by `./setup.sh`:

| Layer       | Source                          | Contains                                                                                             |
| ----------- | ------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **Base**    | `base/CLAUDE.md`                | Package managers, tool priorities, engineering standards, subagent rules — generic, no personal info |
| **Profile** | `profiles/<profile>/CLAUDE.md`  | Desktop: browser tool priorities. VPS: headless constraints                                          |
| **Local**   | `.local/CLAUDE.md` (gitignored) | Your infrastructure, SSH hosts, self-hosted service URLs                                             |

`CLAUDE.md` is **copied, not symlinked** — run `./setup.sh update` after editing any source layer to reassemble. `settings.json`, `statusline.sh`, and `scripts/*.sh` are symlinked, so edits to those reflect immediately.

### Profiles

|               | Desktop                                                            | VPS                           |
| ------------- | ------------------------------------------------------------------ | ----------------------------- |
| Browser tools | Full (agent-browser > chrome-devtools > playwright)                | Dropped                       |
| Extra perms   | —                                                                  | Docker, systemctl, journalctl |
| Model         | opus                                                               | opus                          |
| Hooks         | Prettier on write, subagent cleanup + code-simplifier gate on stop | Same (minus browser-specific) |

Pick the profile during `./setup.sh`; it's saved to `.local/.profile` for future `update` runs.

### How the onboarding layer is wired (belt & suspenders)

The "get started" on-ramp fires from three places so a new user can't miss it:

1. **The `getting-started` skill** (`skills/getting-started/SKILL.md`) — triggers on "I'm new / help me get started / I want to build X / what can this do." It's an **orchestrator**: it detects experience + intent, then routes through the real skills above (brainstorming → plan → build → verify → review → ship). It builds nothing itself, so it improves automatically as those skills improve.
2. **`setup.sh`** prints `New here? Open Claude Code and say: help me get started` on the "Setup complete!" screen.
3. **This file** and the README callout point newcomers here.

### Setup & management commands

```bash
./setup.sh                       # Initial setup (profile + integrations + plugins)
./setup.sh add <name>            # Add/enable a single MCP integration
./setup.sh list                  # Show all integrations and their status
./setup.sh env KEY [value]       # Add an API key to ~/.claude/.env
./setup.sh update                # Pull latest and reassemble config

./scripts/bootstrap-plugins.sh             # Core + prompt for optional groups
./scripts/bootstrap-plugins.sh --core-only # Core only, no prompts

claude plugin list                         # What's installed
claude plugin install <plugin>@<market>    # Add one
claude plugin uninstall <plugin>           # Remove one
```

### Extending it

- **Add a skill (this repo):** drop a folder in `skills/<name>/` with a `SKILL.md` (YAML frontmatter `name` + `description`, then a markdown body — see `skills/verify/SKILL.md` for the minimal shape). `install_skills()` copies every `skills/*/` into `~/.claude/skills/` on `setup.sh` / `update`.
- **Author a skill interactively:** use the `skill-creator` plugin.
- **Add a plugin:** declare it in `profiles/<profile>/settings.json` under `enabledPlugins`, and add its marketplace + install entry to `scripts/bootstrap-plugins.sh` (`MARKETPLACES` + `CORE`/`OPT_*`). `enabledPlugins` keys use the fully-qualified `plugin@marketplace` form (e.g. `supabase@claude-plugins-official`), not a bare name — so the marketplace in `MARKETPLACES` and the key suffix must agree, and the marketplace must be added before the install works.
- **Add an MCP integration:** add a row to the `INTEGRATIONS` array and a generator case in `mcp_json_for()` inside `setup.sh`.

### The enabled plugin set (desktop)

From `profiles/desktop/settings.json` → `enabledPlugins`:

`superpowers`, `feature-dev`, `code-review`, `pr-review-toolkit`, `code-simplifier`, `commit-commands`, `frontend-design`, `ui-ux-pro-max`, `agent-browser`, `claude-mem`, `codex`, `andrej-karpathy-skills`, `skill-creator`, `typescript-lsp`, `security-guidance`, `serena`, `supabase`, `stripe`, `pg`, `n8n-mcp-skills`, `autoresearch`, `ralph-loop`, `plugin-dev`, `hookify`, `agent-sdk-dev`, `claude-md-management`, `claude-code-setup`, `chrome-devtools-mcp`, `elements-of-style`, `learning-output-style`.

`settings.json` marks all 30 as `enabled`, but `bootstrap-plugins.sh` only auto-installs the **15 core** (the shipping engine above); the other 15 (`supabase`, `stripe`, `pg`, `autoresearch`, `n8n-mcp-skills`, `ralph-loop`, `serena`, `chrome-devtools-mcp`, `plugin-dev`, `hookify`, `agent-sdk-dev`, `claude-md-management`, `claude-code-setup`, `elements-of-style`, `learning-output-style`) are the **opt-in groups** from Part 2 — pre-enabled in the committed desktop profile but only installed if you opt in during setup. An enabled-but-not-installed plugin is simply inert until you install it (`claude plugin install <plugin>@<marketplace>`). The 15/15 split mirrors the bootstrap `CORE` vs `OPT_*` arrays exactly.

Local skills shipped by this repo (`skills/`): `getting-started`, `color-strategy`, `design-taste`, `react-bits`, `uiverse`, `verify`, `verify-ui`, `test-and-fix`, `review-changes`, `explore-plan-code-test`, `first-principles`, `feature-gap-audit`, `quick-commit`, `responsive-audit`, `humanizer`, `reflection`, `context-dump`, `scrapegraph`.

---

**New to all this?** Open Claude Code and say **`help me get started`**.
