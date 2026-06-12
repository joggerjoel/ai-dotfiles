# Scraping & Extraction Toolkit

A "swiss army" of web scraping / extraction tools. Each does a different job — pick by
task, not habit. This is the human-readable companion to the decision table in
`~/.claude/CLAUDE.md` ("Web scraping toolkit"). **Canonical, global, reusable across all projects.**

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
| **scrapegraph** | One-shot structured extraction, search+extract, multi-URL, free markdownify | OpenRouter key | ~¢ fractions/page (cheap LLM) | MCP `scrape.example.com` (default), local CLI `sgai`, skill `scrapegraph` |
| **firecrawl** | Extraction on JS-heavy / anti-bot / managed-scale targets | `FIRECRAWL_API_KEY` | firecrawl credits | MCP `firecrawl-mcp` |
| **parse.bot** | Build a _durable_ REST API from a site; marketplace; versioning; update-tracking | `PARSE_API_KEY` | parse.bot plan | MCP `parse` |
| **apify** | Pre-built Actors for specific popular sites; cloud-scale w/ proxies | `APIFY_TOKEN` | apify credits | REST (curl); MCP `apify` (disabled by default) |
| **crawl4ai** | Raw fetch → markdown/html, screenshot, PDF, JS exec; no LLM cost; fallback | bearer | free (self-hosted) | REST `crawl.example.com`, MCP `crawl4ai` |

## Examples

### scrapegraph — structured extraction (default)

**Default = the hosted MCP `scrape.example.com`.** When the `scrapegraph` MCP is connected,
call its tools directly (`smart_scraper`, `search_scraper`, `crawl`, `scrape_many`,
`omni_scraper`, `markdownify`) — no local browser/LLM. Bearer in
`~/Developer/Git/sigma-synapses-monorepo/.secrets/infrastructure/scrape-mcp.env`; client
config in `~/Developer/Git/scrapegraph-mcp/README.md`.

**Fallback = local CLI** (offline / MCP not loaded):

```bash
SG="uv run --directory ~/Developer/Git/scrapegraph-mcp sgai"
$SG scrape "https://example.com" "title and body as JSON"
$SG search "latest Next.js stable version + date" --max-results 3
$SG crawl "https://docs.example.com" "list every API endpoint" --depth 2
$SG scrape-many "name and price" <url1> <url2> <url3>
$SG md "https://example.com"        # page -> markdown, NO LLM cost
```

### crawl4ai — raw fetch / markdown

```bash
# Bearer token is in ~/.claude/CLAUDE.md (crawl4ai Quick Ref) — not stored here.
curl -s -X POST "https://crawl.example.com/crawl" \
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

## Cost discipline

- Prefer **crawl4ai** (free) and **scrapegraph `md`** (free) when you only need content.
- **scrapegraph** extraction is cheap (`gpt-4o-mini`); keep the cheap model unless quality demands otherwise.
- **firecrawl / parse.bot / apify** burn paid credits — use when their specific strength is needed, not for bulk/throwaway work.

## Keys / config

| Tool | Key var | Stored |
| --- | --- | --- |
| scrapegraph | `OPENROUTER_API_KEY` | `~/Developer/Git/scrapegraph-mcp/.env`, hosted bearer in `…/sigma-synapses-monorepo/.secrets/infrastructure/scrape-mcp.env` |
| firecrawl | `FIRECRAWL_API_KEY` | `~/.claude/.env` |
| parse.bot | `PARSE_API_KEY` | `~/.claude/.env`, `…/sigma-synapses-monorepo/.secrets/infrastructure/parse-bot.env` |
| apify | `APIFY_TOKEN` | `~/.claude/.env` |
| crawl4ai | bearer | `~/.claude/CLAUDE.md` (crawl4ai Quick Ref) |

Remote MCPs (`scrape.example.com`, `parse`, `crawl4ai`) are wired via the `mcp-remote` stdio
shim because of CC bug #51581 (HTTP-header `${VAR}` substitution). They load under
`claude-full`; add to `claude-dotfiles/profiles/mcp/standard.json` for the default strict `claude`.

## Project source / config

- **scrapegraph-mcp** project: `~/Developer/Git/scrapegraph-mcp` (CLI + MCP server + Dockerfile)
- Hosted deploy: behind the example.com Traefik host (Docker; host/path details kept local, not in this public ref)
- Skill: `~/.claude/skills/scrapegraph/SKILL.md`
