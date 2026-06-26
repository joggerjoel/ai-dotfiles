---
name: scrapegraph
description: LLM-powered web scraping — extract structured data from a URL/page using a plain-language prompt, or answer a question by searching the web. Use when the user wants to "scrape", "extract data from", "pull info from a website", "get structured JSON from a page", "crawl and extract", or search the web and extract a structured answer. Backed by ScrapeGraphAI + OpenRouter (cheap models).
---

# scrapegraph

LLM-driven scraping (ScrapeGraphAI + Playwright, OpenRouter-backed). Give it a URL and a
natural-language prompt; it returns structured JSON. Prefer this over raw HTML fetching
when the user wants _specific fields_ extracted ("titles and prices", "founders and socials").

> **Setup required.** This skill assumes a [ScrapeGraphAI](https://github.com/ScrapeGraphAI/Scrapegraph-ai)
> MCP server and/or its `sgai` CLI wrapper are available. Either run a hosted MCP instance and
> point your MCP config at its URL, or install the CLI locally. Replace the placeholders below
> (`<scrapegraph-mcp-host>`, `<scrapegraph-mcp-dir>`) with your own. Without one of these, use
> `crawl4ai` or `firecrawl` instead.

**Default = a hosted ScrapeGraphAI MCP instance** (the `scrapegraph` MCP, URL set in your MCP
config). Use its MCP tools (`smart_scraper`, `search_scraper`, `crawl`, `scrape_many`,
`omni_scraper`, `markdownify`) when available — no local browser/LLM needed. **Fall back to the
local CLI** (below) only when the MCP isn't loaded or you're offline.

## When to use

- "Scrape X and extract Y" / "pull the prices from this page" / "get structured data from <url>"
- "What does this company do? (from their site)" — single-page extraction
- "Search the web for X and give me a structured answer" — uses web search + extraction

For a plain page dump (no field extraction), prefer crawl4ai. For known library docs, use context7.

## How to run

**Primary — hosted MCP:** if the `scrapegraph` MCP is connected, just call its tools directly
(`smart_scraper`, `markdownify`, etc.). Nothing to install locally.

**Fallback — local CLI:** when the MCP isn't available. Point `<scrapegraph-mcp-dir>` at your
local ScrapeGraphAI wrapper and invoke through `uv`:

```bash
# prefix each with: uv run --directory <scrapegraph-mcp-dir>
sgai scrape "<url>" "<what to extract>"          # extract from one URL/file/HTML
sgai search "<question>" --max-results 3         # web search + extract
sgai crawl "<url>" "<what to extract>" --depth 2 # multi-page extraction by link-depth
sgai scrape-many "<prompt>" <url1> <url2> ...    # one prompt across many URLs
sgai omni "<url>" "<prompt>"                     # extract incl. images (vision model)
sgai md "<url|file>"                             # page -> clean markdown (NO LLM cost)
```

Output is JSON on stdout (plus verbose node logs on stderr — ignore those).

Tool/command picking:

- Just need the page text? Use `md` (free, no LLM).
- Specific fields from one known URL? `scrape`.
- Don't have the URL / need the web? `search`.
- Same fields from a list of URLs? `scrape-many`.
- Whole-site / follow links? `crawl` (keep `--depth` 1–2; cost grows fast).
- Need image/visual content understood? `omni`.

## Cost discipline (default: cheap)

The default model is `openai/gpt-4o-mini` (OpenRouter's cheap tier) — keep it unless the
user asks for higher quality. Extraction tasks rarely need a frontier model. Override only
when justified:

```bash
uv run --directory <scrapegraph-mcp-dir> sgai --model google/gemini-2.0-flash-001 scrape "<url>" "<prompt>"
```

Cheap, reliable extraction models on OpenRouter: `openai/gpt-4o-mini`, `openai/gpt-4.1-nano`,
`google/gemini-2.0-flash-001`. Avoid expensive models (opus/sonnet/gpt-4o) for bulk scraping.

## Tips

- `search` scrapes `--max-results` pages — keep it small (1–3) to conserve credits.
- If a site needs JS, Playwright (headless Chromium) is already installed and used automatically.
- Default to the hosted `scrapegraph` MCP tools; the local CLI is the offline / MCP-unavailable fallback.
