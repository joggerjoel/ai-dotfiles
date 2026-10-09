#!/bin/bash
# Asset registry shared by setup.sh and scripts/preflight.sh.
# Sourced, never executed. Defines data and one pure function; no side effects.

# Format: name|description|needs_key|key_var|disabled_by_default|extra_vars|desktop_only|key_url
# disabled_by_default is retired: Claude Code has no per-server off switch, so a
# server is either in ~/.claude.json (on) or not (off). The column stays so the
# fields after it keep their positions.
# key_url: where to issue the key; `setup.sh tokens` opens it when the key is missing.
INTEGRATIONS=(
  "context7|Documentation lookup|no||||no"
  "serena|Semantic code assistant|no||||no"
  "morphllm-fast-apply|Fast code application|yes|MORPH_API_KEY|||no|https://morphllm.com/dashboard"
  # Needs the `headroom` binary on PATH (agents-update.sh installs it via
  # `uv tool install headroom-ai[all]`). Registered here rather than by hand so
  # a host's MCP config comes from one place; before this, the only machine
  # running it was one where someone had edited ~/.claude.json directly.
  "headroom|Context-optimization proxy|no||||no"
  "chrome-devtools|Browser DevTools (desktop only)|no||yes||yes"
  "firecrawl|Web scraping (large-scale)|yes|FIRECRAWL_API_KEY|||no|https://www.firecrawl.dev/app/api-keys"
  "github|GitHub repo/issue/PR management|yes|GITHUB_PERSONAL_ACCESS_TOKEN|yes||no|https://github.com/settings/personal-access-tokens/new"
  "openrouter|OpenRouter AI models|yes|OPENROUTER_API_KEY|yes||no|https://openrouter.ai/settings/keys"
  "apify|Web scraping actors|yes|APIFY_TOKEN|yes||no|https://console.apify.com/settings/integrations"
  "digitalocean|DigitalOcean infrastructure|yes|DIGITALOCEAN_API_TOKEN|yes||no|https://cloud.digitalocean.com/account/api/tokens"
  "n8n|Workflow automation|yes|N8N_JWT|yes|N8N_URL|no"
  "crawl4ai|Self-hosted web scraping (SSE)|yes|CRAWL4AI_TOKEN|yes|CRAWL4AI_URL|no"
  "playwright|Browser automation & testing|no||yes||yes"
  "browser-tools|Advanced browser tools|no||yes||yes"
  "magic|UI component generation|yes|API_KEY_21ST|yes||yes|https://21st.dev/mcp"
  # The first row that needs no key and runs no local process, so nothing about
  # provisioning it gates on this host. What it serves is third-party markdown
  # the agent then follows as instructions, and that is the reason it is off by
  # default: each host opts in deliberately rather than inheriting it.
  "ui-skills|Design-engineering skill registry (hosted HTTP)|no||yes||no"
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
#   repair       run when health_cmd fails, then health_cmd is re-run; empty =
#                report only. Use the global CLI, never npx: npx stops to ask
#                before downloading. claude-mem's repair reinstalls the
#                marketplace tree's node_modules, which a plugin update drops.
PLUGIN_ASSETS=(
  "claude-mem|claude-mem|claude-mem doctor|$HOME/.claude-mem/observer-health.json|21600|claude-mem repair"
)

# Map an integration name to its index in INTEGRATIONS. Prints the index;
# returns 1 with a message on stderr when the name is not in the registry.
# Unattended callers pass names from a playbook variable, where a typo must
# fail loudly rather than quietly provision fewer servers than were asked for.
integration_index_for() {
  local want="$1" idx
  for idx in "${!INTEGRATIONS[@]}"; do
    if [ "${INTEGRATIONS[$idx]%%|*}" = "$want" ]; then
      echo "$idx"
      return 0
    fi
  done
  echo "unknown MCP integration '$want' — not in the INTEGRATIONS registry" >&2
  return 1
}

# Map an integration name to its key in ~/.claude.json.
# Where preflight parks a quarantined server's config, beside the claude.json it
# came out of. Derived from that path rather than $HOME so a test pointed at a
# temp claude.json can never touch the real one.
mcp_quarantine_path() {
  printf '%s\n' "${1%.json}-mcp-quarantine.json"
}

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

# Inverse of mcp_key_for: the registry name for an mcpServers key, or nothing
# when the server is not one this toolkit manages.
integration_name_for_key() {
  local entry name
  for entry in "${INTEGRATIONS[@]}"; do
    name="${entry%%|*}"
    [ "$(mcp_key_for "$name")" = "$1" ] && { printf '%s\n' "$name"; return 0; }
  done
  return 1
}
