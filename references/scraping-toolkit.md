# Scraping & Extraction Toolkit

A "swiss army" of web scraping / extraction tools. Each does a different job — pick by
task, not habit. Companion to the decision table in `~/.claude/CLAUDE.md`
("Web scraping toolkit"). **Canonical, global, reusable across all projects.**

> Personal/infra specifics (your hosted endpoint hostnames, bearer tokens, secret-store
> paths) live in **`~/.claude/CLAUDE.md`** + `~/.claude/.env` — not in this public reference.
> Placeholders below (`<your-…-host>`, `$VAR`) point at those.

## Pick-by-task

```
Need just the page content (markdown/html/screenshot/PDF)?      → crawl4ai
Need specific fields as JSON from a page / search + extract?     → scrapegraph   (default)
   …but the site is JS-heavy / anti-bot / needs managed scale?   → firecrawl
Want a persistent REST API you can call repeatedly + versioned?  → parse.bot
Scraping a popular site (Maps, IG, LinkedIn, Amazon) or at scale?→ apify
Anything erroring / want zero LLM cost?                          → crawl4ai (fallback)
```

## The tools

| Tool | Best for | Auth | Cost | Access |
| --- | --- | --- | --- | --- |
| **scrapegraph** | One-shot structured extraction, search+extract, multi-URL, free markdownify | OpenRouter key | ~¢ fractions/page (cheap LLM) | hosted MCP (default) + local CLI `sgai` + skill `scrapegraph` |
| **firecrawl** | Extraction on JS-heavy / anti-bot / managed-scale targets | `FIRECRAWL_API_KEY` | firecrawl credits | MCP `firecrawl-mcp` |
| **parse.bot** | Build a _durable_ REST API from a site; marketplace; versioning; update-tracking | `PARSE_API_KEY` | parse.bot plan | MCP `parse` |
| **apify** | Pre-built Actors for specific popular sites; cloud-scale w/ proxies | `APIFY_TOKEN` | apify credits | REST (curl); MCP `apify` (disabled by default) |
| **crawl4ai** | Raw fetch → markdown/html, screenshot, PDF, JS exec; no LLM cost; fallback | bearer | free (self-hosted) | REST (self-hosted) + MCP `crawl4ai` |

## Examples

### scrapegraph — structured extraction (default)

**Default = your hosted `scrapegraph` MCP** (endpoint + bearer in `~/.claude/CLAUDE.md`).
When connected, call its tools directly (`smart_scraper`, `search_scraper`, `crawl`,
`scrape_many`, `omni_scraper`, `markdownify`) — no local browser/LLM. **Fallback = local CLI**
(offline / MCP not loaded):

```bash
SG="uv run --directory ~/Developer/Git/scrapegraph-mcp sgai"
$SG scrape "https://example.com" "title and body as JSON"
$SG search "latest Next.js stable version + date" --max-results 3
$SG crawl "https://docs.example.com" "list every API endpoint" --depth 2
$SG scrape-many "name and price" <url1> <url2> <url3>
$SG md "https://example.com"        # page -> markdown, NO LLM cost
```

Don't have a hosted instance yet? See **Self-hosting** below.

### crawl4ai — raw fetch / markdown

```bash
# Host + bearer are in ~/.claude/CLAUDE.md (crawl4ai Quick Ref) — not stored here.
curl -s -X POST "https://<your-crawl4ai-host>/crawl" \
  -H "Authorization: Bearer $CRAWL4AI_TOKEN" -H "Content-Type: application/json" \
  -d '{"urls":["https://example.com"]}' | jq '.results[0].markdown'
# also: /screenshot, /pdf, /execute_js
```

### apify — pre-built Actors (MCP off by default; enable on-demand)

The `apify` MCP is intentionally kept `disabled` in `~/.claude.json` to save context.
**Leave it off by default.** When a task needs apify:

- **One-off → REST via curl** (works immediately, no enable):
  ```bash
  # Find an Actor:
  curl -s "https://api.apify.com/v2/store?search=google+maps&token=$APIFY_TOKEN" | jq '.data.items[].name'
  # Run an Actor synchronously and get dataset items:
  curl -s -X POST "https://api.apify.com/v2/acts/<actor-id>/run-sync-get-dataset-items?token=$APIFY_TOKEN" \
    -H "Content-Type: application/json" -d '{ ...actor input... }'
  ```
- **Substantial/iterative work → enable the MCP**: set `mcpServers.apify.disabled=false` in
  `~/.claude.json` (needs a CC restart to load), use it, then set it back to `true` when done.

### parse.bot — build a reusable API (via MCP `parse`)

```
1. marketplace_search "<topic>"   ← ALWAYS first; reuse before building
2. create_api  url="https://target.com"  (if nothing matches)
3. call_endpoint  scraper_id=…  endpoint_name=…  params=…
4. check_updates / merge_updates  ← keep it current as the source site changes
```

### firecrawl — extraction on hard targets (via MCP `firecrawl-mcp`)

Use the `extract` format with a JSON schema when scrapegraph's local Chromium gets
bot-blocked or the page is heavily JS-rendered.

## Self-hosting (optional)

`scrapegraph` and `crawl4ai` can run as your own hosted HTTP MCP behind a reverse proxy
with bearer auth — handy for sharing across machines/agents. **Full agent-followable runbook:
`~/Developer/Git/scrapegraph-mcp/DEPLOY.md`.** In short: build the Docker image (Chromium
baked in), set `OPENROUTER_API_KEY` + a generated `SGAI_MCP_TOKEN` in the host env, route a
subdomain → container `:8765` via your proxy (TLS), add the DNS record, then connect via the
`mcp-remote` shim (`--header "Authorization:${VAR}"`, CC bug #51581). Keep tokens host-side,
never in a repo.

## Cost discipline

- Prefer **crawl4ai** (free) and **scrapegraph `md`** (free) when you only need content.
- **scrapegraph** extraction is cheap (`gpt-4o-mini`); keep the cheap model unless quality demands otherwise.
- **firecrawl / parse.bot / apify** burn paid credits — use when their specific strength is needed, not for bulk/throwaway work.

## Keys / config

Reference by env-var name; actual values live in `~/.claude/.env` and your secret store
(see `~/.claude/CLAUDE.md`).

| Tool | Key var |
| --- | --- |
| scrapegraph | `OPENROUTER_API_KEY` (+ hosted bearer `SGAI_MCP_TOKEN`) |
| firecrawl | `FIRECRAWL_API_KEY` |
| parse.bot | `PARSE_API_KEY` |
| apify | `APIFY_TOKEN` |
| crawl4ai | bearer `CRAWL4AI_TOKEN` |

Remote MCPs (hosted scrapegraph, `parse`, `crawl4ai`) are wired via the `mcp-remote` stdio
shim because of CC bug #51581 (HTTP-header `${VAR}` substitution). They load under
`claude-full`; add to `claude-dotfiles/profiles/mcp/standard.json` for the default strict `claude`.

## Project source

- **scrapegraph-mcp** project: `~/Developer/Git/scrapegraph-mcp` (CLI + MCP server + Dockerfile + `DEPLOY.md`)
- Skill: `~/.claude/skills/scrapegraph/SKILL.md`
