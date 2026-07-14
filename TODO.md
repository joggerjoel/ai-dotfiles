# New-Build Setup Checklist

Everything needed to bring a fresh machine to a fully-working Claude Code config.
`setup.sh` automates most of it; the ⚠️ items are manual and easy to forget.

---

## 1. Prerequisites (install first)

- [ ] **Core tools:** `jq`, `git`, `curl` — `setup.sh` aborts without them
- [ ] **Claude Code CLI:** `npm install -g @anthropic-ai/claude-code`
- [ ] **Runtimes as needed:** Node (nvm), `bun`/`bunx`, `uv`/`uvx` (serena, some MCPs)
- [ ] ⚠️ **`gh` CLI** — not installed by `setup.sh`; needed for PR/issue workflows (`apt install gh`, then `gh auth login`)

## 2. Run the installer

- [ ] `cd claude-dotfiles && ./setup.sh`
  - [ ] Pick **profile**: desktop / vps
  - [ ] Set **GitHub username** + AI-attribution preference (commit policy)
  - [ ] **Remote Control** choice (desktop only — strips telemetry opt-out vars)
  - [ ] Select **MCP integrations** (context7, serena, etc.)
  - [ ] **Supabase** fork: Cloud or Internal (see §4)
  - [ ] Install the **agentic plugin stack** (Y) — runs `scripts/bootstrap-plugins.sh`

## 3. Secrets & keys ⚠️

- [ ] Fill in `~/.claude/.env` (600 perms) — copied from `.env.example`, starts empty
  - [ ] Per-key MCPs you enabled (firecrawl, openrouter, apify, digitalocean, n8n, crawl4ai)
  - [ ] Any project API keys you rely on globally
- [ ] Add a key later with: `./setup.sh add <name>` or `./setup.sh env KEY value`

## 4. Supabase (Cloud vs Internal) ⚠️

The `supabase` plugin's MCP is **Cloud-only** (`mcp.supabase.com`). Self-hosted needs a
different server, so pick the fork per machine:

- [ ] **Cloud:** `./setup.sh supabase cloud` → then run the plugin's **OAuth** once inside
      Claude Code (`/mcp`, authenticate `supabase`)
- [ ] **Internal (self-hosted, e.g. `your-db-host`):** `./setup.sh supabase internal` → paste the
      connection string `postgresql://postgres:<pw>@your-db-host:5432/postgres`
      (registers a direct Postgres MCP via `@henkey/postgres-mcp-server`)
- [ ] Mode is saved to `.local/.supabase-mode` and re-applied by `./setup.sh update`

## 5. Scheduled jobs ⚠️

- [ ] **Marketplace auto-refresh cron:** `./scripts/cron-setup.sh`
      (daily ~2:10am; `--dry-run` to preview, `--remove` to undo)

## 6. Plugin / MCP authentication ⚠️

Installed ≠ authenticated. In Claude Code, run `/mcp` and complete any auth for:

- [ ] Supabase (Cloud OAuth)
- [ ] Stripe, GitHub, or other OAuth/token MCPs you enabled
- [ ] Restart Claude Code so newly installed plugins load

## 7. Verify

- [ ] `claude` launches, statusline renders
- [ ] `./setup.sh list` shows expected MCPs as **active**
- [ ] `jq empty ~/.claude/settings.json` → valid
- [ ] `crontab -l | grep marketplace` → one entry
- [ ] `/mcp` shows connected servers (green)
- [ ] Supabase MCP responds (Cloud: lists projects · Internal: lists tables)

---

### Per-machine variations at a glance

| Dimension        | Desktop                          | VPS / headless              |
| ---------------- | -------------------------------- | --------------------------- |
| Profile          | `desktop`                        | `vps`                       |
| Desktop-only MCPs| chrome-devtools, playwright, …   | skipped automatically       |
| Remote Control   | prompted                         | n/a                         |
| Supabase         | Cloud **or** Internal (`your-db-host`) | usually Internal            |

### Re-running / updating

- `./setup.sh update` — pull latest, reassemble CLAUDE.md, re-link scripts, re-apply
  Supabase fork (non-interactive; preserves stored connection string).
- `.local/` holds this machine's saved choices (`.profile`, `.supabase-mode`, etc.) and is
  gitignored — never committed.
