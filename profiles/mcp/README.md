# MCP Profiles

Tiered MCP server configurations for Claude Code, loaded via `--mcp-config` + `--strict-mcp-config`.

## Tiers

| Profile                       | MCPs                       | Memory cost (per session) | When to use                                                     |
| ----------------------------- | -------------------------- | ------------------------- | --------------------------------------------------------------- |
| `minimal.json`                | context7                   | ~150 MB                   | Reading code, docs lookup, quick tasks                          |
| `standard.json`               | context7 + chrome-devtools | ~500 MB                   | **Default daily driver** — covers ~99% of recent usage          |
| (none, uses `~/.claude.json`) | All 15 root-level MCPs     | ~2.4 GB                   | When you need the kitchen sink (escape hatch via `claude-full`) |

## How it works

Shell functions in `~/.zshrc` route `claude` / `claude-min` / `claude-full` to the right profile. Functions (not plain aliases) so CLI subcommands like `agents`, `attach`, `logs`, `stop`, `respawn` bypass the MCP flags — see [Gotcha](#gotcha-cli-subcommands-and---strict-mcp-config) below.

```bash
claude() {
  case "$1" in
    agents|attach|logs|stop|kill|respawn|rm|update|mcp|config|--version|--help|-h)
      command claude "$@"
      ;;
    *)
      command claude --mcp-config ~/.claude/mcp-profiles/standard.json --strict-mcp-config "$@"
      ;;
  esac
}
claude-min() {
  case "$1" in
    agents|attach|logs|stop|kill|respawn|rm|update|mcp|config|--version|--help|-h)
      command claude "$@"
      ;;
    *)
      command claude --mcp-config ~/.claude/mcp-profiles/minimal.json --strict-mcp-config "$@"
      ;;
  esac
}
alias claude-full='command claude'
```

Project-level `.mcp.json` files still merge in under strict mode — so per-project MCPs (supabase, flowglad, etc.) continue working without changes.

### Gotcha: CLI subcommands and `--strict-mcp-config`

Passing `--strict-mcp-config` (and/or `--mcp-config`) to non-interactive CLI subcommands breaks them. The most visible symptom is `claude agents`: instead of opening the interactive Agent View (research preview, v2.1.139+), it falls back to printing the static list of configured subagents and exits.

That's why the wrappers use a `case` statement to strip the MCP flags for `agents`, `attach`, `logs`, `stop`, `kill`, `respawn`, `rm`, `update`, `mcp`, `config`, `--version`, and `--help`. Interactive sessions (no subcommand, or `claude .`, `claude --resume`, etc.) still get the strict MCP profile applied.

## Symlink

`~/.claude/mcp-profiles/` symlinks to this directory so Claude Code can find the profiles at a stable path.

## Adding a new tier

1. Create `profiles/mcp/<name>.json` with the standard shape: `{"mcpServers": {...}}`
2. Add a shell alias in `base/CLAUDE.md` template or `~/.zshrc`
3. **Never put plaintext secrets in profiles committed to this repo.** Use `${VAR_NAME}` references and store actual values in `~/.claude/.env` (gitignored).

## Known constraints

- **HTTP-header `${VAR}` substitution is broken** in Claude Code (issues [#51581](https://github.com/anthropics/claude-code/issues/51581), [#6204](https://github.com/anthropics/claude-code/issues/6204)). MCPs that authenticate via HTTP headers (e.g., `n8n-mcp`, `crawl4ai`) cannot use env-var references — their plaintext tokens stay in `~/.claude.json` (local-only, never committed) for now.
- stdio `env` block substitution works fine.

## Fallback hints

When an MCP is not loaded, Claude is instructed in `~/.claude/CLAUDE.md` to reach for these CLI equivalents:

| Missing MCP  | Use instead                            |
| ------------ | -------------------------------------- |
| github       | `gh` CLI                               |
| firecrawl    | crawl4ai REST API                      |
| digitalocean | `doctl` CLI                            |
| apify        | `curl` + Apify API                     |
| openrouter   | `curl` to OpenRouter API               |
| playwright   | chrome-devtools or `agent-browser` CLI |
| serena       | built-in Read/Edit/Grep                |
| magic        | `frontend-design` skill                |
