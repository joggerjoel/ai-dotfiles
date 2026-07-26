# Tool Priority Reference

Detailed tool selection guide. Referenced from ~/.claude/CLAUDE.md.

## Browser Automation

**Prefer agent-browser CLI** for all browser automation tasks:

| Task            | Use                        | Instead of                        |
| --------------- | -------------------------- | --------------------------------- |
| Screenshots     | `agent-browser screenshot` | chrome-devtools, claude-in-chrome |
| Navigation      | `agent-browser navigate`   | chrome-devtools, claude-in-chrome |
| Click/Fill      | `agent-browser click/fill` | chrome-devtools, claude-in-chrome |
| Page content    | `agent-browser snapshot`   | chrome-devtools, firecrawl        |
| Form automation | `agent-browser fill-form`  | chrome-devtools                   |

**Fallback to other tools** when:

- **chrome-devtools MCP** (bundled by the `chrome-devtools-mcp` plugin): Need DevTools-specific features (network interception, performance traces, console access)
- **claude-in-chrome**: Need to drive your real, already-logged-in Chrome profile and tabs
- **firecrawl-mcp**: Need large-scale web scraping or crawling multiple pages

**Not installed** — add before reaching for them:

- **Playwright MCP** (`./setup.sh add playwright`): Cross-browser testing (Firefox, WebKit) or complex test scenarios
- **browser-tools-mcp** (`./setup.sh add browser-tools`): Performance monitoring or cross-browser compatibility testing

Why agent-browser first: Fast Rust CLI, minimal overhead, simple command interface, headless by default.

## GitHub Access

**Always use `gh` CLI (authenticated)** for all GitHub operations:

| Task             | Use                                           | Instead of              |
| ---------------- | --------------------------------------------- | ----------------------- |
| View repo        | `gh repo view`                                | WebFetch github.com     |
| List issues      | `gh issue list`                               | Scraping issues page    |
| View PR          | `gh pr view`                                  | WebFetch PR URL         |
| Get file content | `gh api repos/{owner}/{repo}/contents/{path}` | Raw GitHub URLs         |
| Search code      | `gh search code`                              | WebFetch search results |
| View release     | `gh release view`                             | WebFetch releases page  |

Avoids rate limits, uses existing auth, full private repo access.

**Fallback to WebFetch** only when `gh` CLI doesn't support the operation or accessing non-GitHub redirect URLs.

## Documentation Lookup

**Use context7 MCP** for library/framework documentation before web search:

| Task               | Use                         | Instead of                   |
| ------------------ | --------------------------- | ---------------------------- |
| Library API docs   | `context7:get-library-docs` | WebSearch "react hooks docs" |
| Framework patterns | `context7:get-library-docs` | WebFetch random blog posts   |
| Package usage      | `context7:get-library-docs` | Stack Overflow answers       |

Authoritative, up-to-date, structured output optimized for code generation.

**Fallback to WebSearch** when researching general concepts, bleeding-edge features, or comparing multiple libraries.

## Web Scraping (crawl4ai)

**Use crawl4ai REST API** (PRIMARY) for all web scraping. Self-hosted, free, no rate limits.

**Base URL**: `$CRAWL4AI_URL` (set in `~/.claude/.env`)
**Auth**: `Authorization: Bearer $CRAWL4AI_TOKEN` (set in `~/.claude/.env`)

### Endpoints

| Task         | Endpoint      | Method | Notes                                       |
| ------------ | ------------- | ------ | ------------------------------------------- |
| Crawl URL(s) | `/crawl`      | POST   | **Primary** - returns markdown, HTML, links |
| Screenshot   | `/screenshot` | POST   | Returns base64 image                        |
| Generate PDF | `/pdf`        | POST   | Returns base64 PDF                          |
| Execute JS   | `/execute_js` | POST   | Run JS on page                              |
| Get markdown | `/md`         | POST   | Requires server LLM config (broken)         |
| Query docs   | `/ask`        | POST   | Requires server LLM config (broken)         |

### Primary Usage (crawl)

```bash
curl -s -X POST "$CRAWL4AI_URL/crawl" \
  -H "Authorization: Bearer $CRAWL4AI_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://example.com"]}' | jq '.results[0].markdown'
```

Response fields: `raw_markdown`, `markdown_with_citations`, `references_markdown`

### Screenshot

```bash
curl -s -X POST "$CRAWL4AI_URL/screenshot" \
  -H "Authorization: Bearer $CRAWL4AI_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","screenshot_wait_for":2}'
```

### Execute JavaScript

```bash
curl -s -X POST "$CRAWL4AI_URL/execute_js" \
  -H "Authorization: Bearer $CRAWL4AI_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","scripts":["document.title"]}'
```

### Notes

- `/md` endpoint returns `{"detail":"'llm'"}` without server LLM config. Use `/crawl` instead.
- **Fallback to firecrawl-mcp**: crawl4ai down, need sitemap crawling, or structured extraction schemas
- **Fallback to WebFetch**: Simple static pages, quick content where quality isn't critical
- crawl4ai MCP is broken (SSE bug #1594). Use REST API via curl only.
