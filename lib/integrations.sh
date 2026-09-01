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

# Marketplace PLUGINS that ship working parts of their own — a CLI, a daemon, a
# database — and can therefore be broken in ways the other probes structurally
# cannot see.
#
# The gap this closes, found 2026-09-01: claude-mem's MCP server answered
# `claude mcp list` with "✔ Connected" for the nine hours its observer was
# failing every write with FOREIGN KEY constraint failed. Connectivity was
# never the question. A plugin has three separable states and the existing
# probes only cover the first two:
#
#   presence  is the CLI installed          -> MANDATED_CLIS / probe_clis
#   liveness  does it answer a handshake    -> probe_mcp
#   FUNCTION  is it doing its actual job    -> this registry, probe_plugins
#
# Plugin assets are invisible to the other registries by construction: the CLI
# is not in MANDATED_CLIS, the MCP server is not a ~/.claude.json key, and the
# skills are not under $DOTFILES_DIR/skills. Nothing was misconfigured — there
# was simply nothing pointed at them.
#
# Format: name|cli|health_cmd|ledger|stale_after
#   cli          binary that must resolve; empty = skip the presence check
#   health_cmd   exits non-zero when a REQUIRED check fails; empty = skip
#   ledger       JSON file carrying the function signal. Contract is two keys:
#                `lastSuccessAt` (epoch ms of the last real success) and
#                `consecutiveFailures`. Empty = no function signal available.
#   stale_after  seconds since lastSuccessAt before the asset is called stale.
#                A plugin that has not succeeded in this long is failing
#                silently even when every other light is green.
PLUGIN_ASSETS=(
  "claude-mem|claude-mem|claude-mem doctor|$HOME/.claude-mem/observer-health.json|21600"
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
