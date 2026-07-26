## Browser Automation Tool Priority

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

**Why agent-browser first**:

- Fast Rust CLI with minimal overhead
- Simple command interface for common tasks
- Integrated Claude Code plugin with skills
- Headless by default, efficient for AI agent workflows
