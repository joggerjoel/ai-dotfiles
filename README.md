# claude-dotfiles

Portable Claude Code configuration with profile-based setup. One repo, works on any machine — desktop or headless VPS.

> **New here?** After running `./setup.sh`, open Claude Code and say **`help me get started`** — it'll walk you through building and shipping, even with zero coding experience. Or read **[GETTING-STARTED.md](GETTING-STARTED.md)** first.

## What this does

- **Layered CLAUDE.md** — generic base + environment profile + personal overlay
- **Profile system** — desktop (full browser tools, opus) vs VPS (headless, opus, minimal plugins)
- **Interactive installer** — picks profile, sets GitHub username, configures MCP servers
- **Cross-platform scripts** — OS-aware (macOS + Linux) subagent cleanup, statusline, gate scripts
- **No personal info committed** — infrastructure, IPs, SSH shortcuts live in gitignored `.local/`

## Quick start

```bash
git clone https://github.com/iamnolanhu/claude-dotfiles.git
cd claude-dotfiles
./setup.sh
```

The installer will:

1. Ask your machine type (Desktop / VPS)
2. Ask your GitHub username (optional, for commit policy)
3. Ask if you want AI attribution hidden in commits
4. Link settings, scripts, and statusline to `~/.claude/`
5. Copy reference files and install global skills into `~/.claude/`
6. Assemble `CLAUDE.md` from base + profile + local layers
7. Walk you through MCP server selection

During setup you're offered the **agentic plugin stack** — this is what makes the workflow "100x". A **core** set auto-installs (superpowers, ui-ux-pro-max, feature-dev, code-review, pr-review-toolkit, code-simplifier, commit-commands, frontend-design, agent-browser, claude-mem, codex, karpathy guidelines, skill-creator, typescript-lsp, security-guidance). **Optional** plugins (backend/data, automation/research, code-intelligence, authoring, writing) are opt-in by group and reversible anytime.

Run it standalone too:

```bash
./scripts/bootstrap-plugins.sh             # core + prompt for optional groups
./scripts/bootstrap-plugins.sh --core-only # core only, no prompts
```

Manage later: `claude plugin list` · `claude plugin install <plugin>@<marketplace>` · `claude plugin uninstall <plugin>`.

## Structure

```
claude-dotfiles/
├── setup.sh                     # Interactive installer
├── base/
│   └── CLAUDE.md               # Generic instructions (no personal info)
├── profiles/
│   ├── desktop/
│   │   ├── CLAUDE.md           # Browser automation priorities
│   │   └── settings.json       # Full plugins, opus, prettier hook
│   └── vps/
│       ├── CLAUDE.md           # Headless constraints, resource limits
│       └── settings.json       # Minimal plugins, sonnet, docker perms
├── skills/                      # Global skills, copied into ~/.claude/skills/
│   ├── design-taste/           # Taste, motion, anti-slop (Emil Kowalski et al.)
│   ├── react-bits/             # Source animated React components (reactbits.dev)
│   ├── uiverse/                # Source small UI primitives (uiverse.io)
│   └── color-strategy/         # 60/30/10, OKLCH, semantic color, WCAG
├── examples/
│   └── local-CLAUDE.md         # Template for personal config
├── .local/                      # Gitignored — your machine-specific config
│   └── CLAUDE.md               # Infrastructure, SSH, self-hosted services
├── scripts/
│   ├── cleanup-subagents.sh    # Kill stale subagents by age + count
│   ├── code-simplifier-gate.sh # Cooldown gate for code review hook
│   └── kill-all-orphans.sh     # Nuclear cleanup for orphaned processes
├── statusline.sh                # Multi-line statusline (git, cost, context %)
├── .env.example                 # API key template
└── .gitignore
```

## How CLAUDE.md assembly works

Your final `~/.claude/CLAUDE.md` is built from three layers:

| Layer       | Source                         | Contains                                                                 |
| ----------- | ------------------------------ | ------------------------------------------------------------------------ |
| **Base**    | `base/CLAUDE.md`               | Package managers, tool priorities, engineering standards, subagent rules |
| **Profile** | `profiles/<profile>/CLAUDE.md` | Desktop: browser tools. VPS: headless constraints                        |
| **Local**   | `.local/CLAUDE.md`             | Your infrastructure, SSH hosts, self-hosted service URLs                 |

Run `./setup.sh update` after editing any source layer to reassemble.

## Profiles

### Desktop

- Full plugin set (30 enabled: 15 core auto-installed + 15 opt-in, including agent-browser, frontend-design)
- Browser automation tool priority (agent-browser > chrome-devtools > playwright)
- Prettier formatting hook on file writes
- Code simplifier gate on session stop
- Default model: **opus**

### VPS

- A reduced headless plugin set (20 enabled — drops browser/UI tooling like agent-browser, frontend-design, chrome-devtools-mcp, ui-ux-pro-max), same hooks and model as desktop
- No browser tools offered during MCP setup
- Docker, systemctl, and journalctl permissions added
- Default model: **opus**

## Commands

```bash
./setup.sh              # Initial setup (profile + integrations)
./setup.sh add <name>   # Add/enable a single MCP integration
./setup.sh list         # Show all integrations and their status
./setup.sh env KEY [v]  # Add an API key to ~/.claude/.env
./setup.sh update       # Pull latest and reassemble config
```

## Personalizing

After running setup, edit `.local/CLAUDE.md` with your machine-specific config. See `examples/local-CLAUDE.md` for the template. Common additions:

- Server IPs and Tailscale topology
- SSH shortcuts and port forwards
- Self-hosted service URLs (crawl4ai, n8n, etc.)
- Project template references
- File sharing and sync setup

## MCP Integrations

| Integration         | Needs API Key | Desktop Only |
| ------------------- | :-----------: | :----------: |
| context7            |               |              |
| serena              |               |              |
| morphllm-fast-apply |               |              |
| chrome-devtools     |               |     yes      |
| firecrawl           |      yes      |              |
| github              |      yes      |              |
| openrouter          |      yes      |              |
| apify               |      yes      |              |
| digitalocean        |      yes      |              |
| n8n                 |      yes      |              |
| crawl4ai            |      yes      |              |
| playwright          |               |     yes      |
| browser-tools       |               |     yes      |
| magic               |               |     yes      |
