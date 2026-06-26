# Claude Code Configuration

<!-- claude-dotfiles · built by Nolan Hu / Sigma Synapses · https://github.com/iamnolanhu/claude-dotfiles -->
<!-- build: 0xBdf1980e7Fc57DBE03874C29c203C3dff576D40c -->

## Key File Locations

| File                              | Purpose                                                 |
| --------------------------------- | ------------------------------------------------------- |
| `~/.claude.json`                  | **MCP config** - edit this for MCP servers              |
| `~/.claude/settings.json`         | Hooks, permissions, plugin settings                     |
| `~/.claude/CLAUDE.md`             | This file - Claude instructions                         |
| `~/.claude/.env`                  | **Global API keys** - Claude references across projects |
| `~/.claude/TROUBLESHOOTING.md`    | **Known issues & fixes** - check first when debugging   |
| `~/.claude/.backups/CHANGELOG.md` | Log of config changes and fixes applied                 |

**Reference files** (read on-demand, not loaded by default):

| File                                        | Content                                         |
| ------------------------------------------- | ----------------------------------------------- |
| `~/.claude/references/tool-priorities.md`   | Detailed tool selection guide with examples     |
| `~/.claude/references/project-templates.md` | Turborepo template packages, commands, patterns |

## MCP Configuration

**Config File**: `~/.claude.json` (verify with `/mcp` command)

**Core**: context7, serena, morphllm-fast-apply
**Optional**: chrome-devtools, firecrawl, github, openrouter, apify, digitalocean, n8n, crawl4ai, playwright, browser-tools, magic
**Disabled**: Check `~/.claude.json` for full list. Enable with `./setup.sh add <name>`.

## Tool Priority (tl;dr)

Prefer fast, authenticated tools. Full details: `~/.claude/references/tool-priorities.md`

| Task               | Use                                             | Not                         |
| ------------------ | ----------------------------------------------- | --------------------------- |
| Browser automation | `agent-browser` CLI                             | chrome-devtools, Playwright |
| GitHub operations  | `gh` CLI                                        | WebFetch github.com         |
| Library docs       | context7 MCP                                    | WebSearch                   |
| Web scraping       | crawl4ai REST (URL/token from `~/.claude/.env`) | firecrawl, WebFetch         |
| JS/TS packages     | `bun` / `bunx`                                  | npm / npx                   |
| Python packages    | `uv` / `uvx`                                    | pip / pipx                  |

**Fallback** to npm/pip only when project explicitly uses them (check lockfiles) or compatibility issues arise.

## crawl4ai Quick Ref

Primary endpoint (use this, not `/md`):

```bash
curl -s -X POST "$CRAWL4AI_URL/crawl" \
  -H "Authorization: Bearer $CRAWL4AI_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://example.com"]}' | jq '.results[0].markdown'
```

Other endpoints: `/screenshot`, `/pdf`, `/execute_js`. Full examples: `~/.claude/references/tool-priorities.md`

## Global API Keys

**Location**: `~/.claude/.env` (600 perms, never commit).
Reference by env var name only. Use `.env.example` with placeholders for docs.

## Agent & Subagent Rules

- **2-minute timeout** on any single operation — abandon and try alternative
- **30-second progress updates** — never go silent
- Use fastest tools (gh > WebFetch, context7 > WebSearch)
- Parent: use `run_in_background: true`, check periodically, `TaskStop` after 5min silence

## Secret & API Key Handling

Never expose secrets: don't commit `.env`, don't log keys, don't hardcode. Reference by variable name only. Verify `.gitignore` before any git operation.

## Git Commit Policy

{{GIT_COMMIT_POLICY}}

## Claude Code Auto-Update Fix

```bash
rm -rf ~/.nvm/versions/node/$(node -v)/lib/node_modules/@anthropic-ai/.claude-code-* && npm update -g @anthropic-ai/claude-code
```

## Engineering Excellence Standards

| Principle                     | Rule                                   |
| ----------------------------- | -------------------------------------- |
| **DRY**                       | Repeat in >1 file? Abstract it.        |
| **KISS**                      | Simple > clever; readable > concise    |
| **YAGNI**                     | Don't build until needed               |
| **Single Source of Truth**    | One canonical location per data/config |
| **Composition > Inheritance** | Small, focused pieces                  |
| **Separation of Concerns**    | UI != logic; data fetch != display     |
| **Fail Fast**                 | Validate at boundaries, throw early    |

Before committing: no duplication, simplest solution, no speculative features, strict TypeScript (no `any`/`@ts-ignore`).

## Config Backup Strategy

Before editing any config: `cp <file> ~/.claude/.backups/<folder>/<filename>.$(date +%Y%m%d_%H%M%S)`
Then log: `echo "$(date '+%Y-%m-%d %H:%M') | <file> | <reason>" >> ~/.claude/.backups/CHANGELOG.md`

## Documentation Organization

Use `inventory/` (facts) + `guides/` (instructions) pattern for project docs with 3+ files.
Full pattern details in auto-memory (`MEMORY.md`).

## Project Templates

**Turborepo template**: Next.js 16, Tailwind v4, Bun, TypeScript strict.
Dual-deploy (self-hosted Docker+Traefik or Vercel+Supabase). Setup: `./scripts/setup.sh <name>`
Full details: `~/.claude/references/project-templates.md`

## Design Skills (Auto-Invoke on UI Work)

For **any** task involving UI, components, layout, CSS, animation, or visual design — auto-invoke these skills before writing code:

1. **`ui-ux-pro-max`** — general UI/UX vocabulary, 50+ styles, color/font systems, chart picks (plugin: `ui-ux-pro-max-skill`)
2. **`design-taste`** (`~/.claude/skills/design-taste/SKILL.md`) — taste, motion, polish, anti-slop. Sources: Emil Kowalski, [animations.dev](https://animations.dev/), [impeccable.style](https://impeccable.style/), [styles.refero.design](https://styles.refero.design/) (real-product design refs + AI-readable `DESIGN.md` specs + MCP). Deep reference: `~/.claude/references/design-engineering-emil.md`
3. **`react-bits`** (`~/.claude/skills/react-bits/SKILL.md`) — source pre-built **animated React components** (130+: animated text, backgrounds, cursor/scroll/hover effects, interactive components) from [reactbits.dev](https://reactbits.dev) instead of hand-rolling motion. Auto-invoke for any React/Next.js UI wanting animation; skip for non-React stacks. Source, then tune the motion with `design-taste`. MIT + Commons Clause.
4. **`uiverse`** (`~/.claude/skills/uiverse/SKILL.md`) — source small copy-paste UI **primitives** (buttons, loaders, toggles, inputs, cards, tooltips) from [uiverse.io](https://uiverse.io) (7000+, MIT) as HTML/CSS, Tailwind, React, or Figma. **Framework-agnostic.** Re-tokenize colors + audit a11y after pasting.
5. **`color-strategy`** (`~/.claude/skills/color-strategy/SKILL.md`) — 60/30/10 distribution, OKLCH scales, semantic color, WCAG contrast. Auto-invoke on color decisions; skip if a project design-system governs color.
6. **Project `/design-system` skill** when in a monorepo that has one — for brand tokens and canonical components.

**Pick the source:** small primitive (any stack) → `uiverse`; large animated React component / hero text / background → `react-bits`; whole layout → `frontend-design`. All compose. Trigger: "any 1% chance the task touches UI" → invoke.

## Things Claude Should NOT Do

- Don't edit config files without backing up first to `~/.claude/.backups/`
- Don't try to use crawl4ai MCP - it's broken (SSE bug #1594). Use REST API via curl
- Don't use `any` type in TypeScript without explicit approval
- Don't skip error handling or swallow errors silently
- Don't commit without running tests first
- Don't make breaking API changes without discussion
- Don't add unnecessary dependencies when stdlib suffices
- Don't over-engineer simple solutions
- Don't guess at file paths or URLs - verify they exist first
- Don't assume package manager - check for lockfiles first
- Don't scrape GitHub URLs when `gh` CLI can retrieve the same data
- Don't commit or log secrets, API keys, or `.env` file contents
- Don't let subagents run silently for >2 minutes without progress updates
- Don't use slow tools (WebFetch) when fast authenticated tools exist (gh, context7)
- Don't let subagent processes accumulate - kill with: `ps aux | grep "disallowedTools" | grep -v grep | awk '{print $2}' | xargs kill -9`
- Don't enable SSE-type MCP servers without testing - they can cause Claude Code to hang on startup
- Don't invent or guess email addresses - ask the user which email to use

---

_Update this file when Claude makes mistakes. Every error is a learning opportunity._
