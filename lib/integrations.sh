#!/bin/bash
# Asset registry shared by setup.sh and scripts/preflight.sh.
# Sourced, never executed. Defines data and one pure function; no side effects.

# Format: name|description|needs_key|key_var|disabled_by_default|extra_vars|desktop_only
INTEGRATIONS=(
  "context7|Documentation lookup|no||||no"
  "serena|Semantic code assistant|no||||no"
  "morphllm-fast-apply|Fast code application|no||||no"
  "chrome-devtools|Browser DevTools (desktop only)|no||yes||yes"
  "firecrawl|Web scraping (large-scale)|yes|FIRECRAWL_API_KEY|||no"
  "github|GitHub repo/issue/PR management|yes|GITHUB_PERSONAL_ACCESS_TOKEN|yes||no"
  "openrouter|OpenRouter AI models|yes|OPENROUTER_API_KEY|yes||no"
  "apify|Web scraping actors|yes|APIFY_TOKEN|yes||no"
  "digitalocean|DigitalOcean infrastructure|yes|DIGITALOCEAN_API_TOKEN|yes||no"
  "n8n|Workflow automation|yes|N8N_JWT|yes|N8N_URL|no"
  "crawl4ai|Self-hosted web scraping (SSE)|yes|CRAWL4AI_TOKEN|yes|CRAWL4AI_URL|no"
  "playwright|Browser automation & testing|no||yes||yes"
  "browser-tools|Advanced browser tools|no||yes||yes"
  "magic|UI component generation|no||yes||yes"
)

# CLIs the CLAUDE.md tool-priority tables name as required. Declared here rather
# than scraped from markdown: table formatting changes break a parser, and a
# parser cannot tell a mandated tool from one merely mentioned.
MANDATED_CLIS=(
  "agent-browser"
  "gh"
  "bun"
  "uv"
  "just"
  "jq"
)

# Map an integration name to its key in ~/.claude.json.
mcp_key_for() {
  case "$1" in
    browser-tools) echo "browser-tools-mcp" ;;
    firecrawl)     echo "firecrawl-mcp" ;;
    openrouter)    echo "openrouterai" ;;
    digitalocean)  echo "digitalocean-mcp" ;;
    n8n)           echo "n8n-mcp" ;;
    *)             echo "$1" ;;
  esac
}
