---
name: 9router
description: Entry point for 9Router — local/remote AI gateway with OpenAI-compatible REST for chat, image, TTS, embeddings, web search, web fetch. Use when the user mentions 9Router, NINEROUTER_URL, or wants AI without writing provider boilerplate. This skill covers setup + indexes capability skills; fetch the relevant capability SKILL.md from the URLs below when needed.
---

<!-- BEGIN LOCAL DEPLOYMENT (ai-dotfiles/skills-local/9router-deployment.md) -->
## Our deployment (aorus4 primary + aorus8 spare, internal-only)

Two gateways, deployed via `ai-dotfiles/ansible-ai/deploy-9router.yml` (docker compose: `9router` + `headroom`), each bound to **`127.0.0.1:20128`** on its host — no public surface. The playbook targets inventory group `ninerouter_ai` (aorus4, aorus8) and is also imported by `update.yml`, so fleet updates re-pull `:latest` and preserve secrets automatically. Manual redeploy: `cd ansible-ai && ansible-playbook deploy-9router.yml`.

- **aorus4** is the primary (provider accounts configured). **aorus8** is a spare — each instance has its own data dir, dashboard, and provider accounts; there is no config sync between them.
- **On a gateway host:** `NINEROUTER_URL=http://127.0.0.1:20128`
- **From macstudio / elsewhere:** tunnel first — `ssh -N -L 20128:127.0.0.1:20128 aorus4` (or aorus8) — then `NINEROUTER_URL=http://127.0.0.1:20128`
- **Dashboard first-login:** user `admin`, password from `ssh <host> 'sudo grep INITIAL_PASSWORD /opt/9router/.env'` (change it after login). Add provider accounts + issue keys there, per instance.
- **A `NINEROUTER_KEY` is effectively required for `/v1/*`** even with `REQUIRE_API_KEY=false`: requests reach the container through Docker's bridge network, so they never look like loopback to the app and get `401 API key required for remote API access`. Issue a key in Dashboard → Keys and export it as `NINEROUTER_KEY`. (`/api/health` and `/api/version` stay open.)
- **`/v1/models` is the full catalog, NOT what's usable.** A model whose provider has no account on this instance returns `404 "No active credentials for provider: <name>"`. To find what actually routes, probe with a 1-token completion or check the dashboard.

### Decomposed / parallel workloads (how we use this)

Strategy: frontier models by default; the gateway is the fan-out mechanism, not the fleet.

- **Decompose on one orchestrator** (usually the MacBook via Claude Code). Parallelism = concurrent HTTP calls against `NINEROUTER_URL`; the bottleneck is provider rate limits, so ssh-distributing API calls across fleet hosts adds nothing.
- **"Other targets" = provider accounts.** Add several frontier accounts in the dashboard and chain them in a **combo** (e.g. `combo/frontier`): requests auto-fall back on 429/outage, spreading load across accounts. Orchestration code stays dumb — one URL, one key, one model id per tier.
- **Tier subtasks by difficulty.** Mechanical steps (extract, classify, dedupe, reformat) → a cheap tier; reasoning/synthesis → `combo/frontier`. Note `mmf` (free tier) injects a ~2k-token system prompt per call — fine for smoke tests, poor for high-volume subtasks.
- **Optional local tier:** macstudio runs ollama, LAN-bound on `:11434` and reachable from aorus4 (LAN IPs live in `ansible-ai/inventory.local.yml`, not here — repo is public). Pull a model, then register `http://<macstudio-lan-ip>:11434/v1` as an OpenAI-compatible provider in the dashboard.
- **Fleet hosts enter only when a subtask needs tools/repo state on that machine:** run headless agents there (`claude -p` / `codex exec` over ssh), each pointing its model calls at the gateway.
<!-- END LOCAL DEPLOYMENT -->

# 9Router

Local/remote AI gateway exposing OpenAI-compatible REST. One key, many providers, auto-fallback.

## Setup

```bash
export NINEROUTER_URL="http://localhost:20128"      # or VPS / tunnel URL
export NINEROUTER_KEY="sk-..."                      # from Dashboard → Keys (only if requireApiKey=true)
```

All requests: `${NINEROUTER_URL}/v1/...` with header `Authorization: Bearer ${NINEROUTER_KEY}` (omit if auth disabled).

Verify: `curl $NINEROUTER_URL/api/health` → `{"ok":true}`

## Discover models

```bash
curl $NINEROUTER_URL/v1/models                  # chat/LLM (default)
curl $NINEROUTER_URL/v1/models/image            # image-gen
curl $NINEROUTER_URL/v1/models/tts              # text-to-speech
curl $NINEROUTER_URL/v1/models/embedding        # embeddings
curl $NINEROUTER_URL/v1/models/web              # web search + fetch (entries have `kind` field)
curl $NINEROUTER_URL/v1/models/stt              # speech-to-text
curl $NINEROUTER_URL/v1/models/image-to-text    # vision
```

Use `data[].id` as `model` field in requests. Combos appear with `owned_by:"combo"`.

Response shape:
```json
{ "object": "list", "data": [
  { "id": "openai/gpt-5", "object": "model", "owned_by": "openai", "created": 1735000000 },
  { "id": "tavily/search", "object": "model", "kind": "webSearch", "owned_by": "tavily", "created": 1735000000 }
]}
```

## Capability skills

When the user needs a specific capability, fetch that skill's `SKILL.md` from its raw URL:

| Capability | Raw URL |
|---|---|
| Chat / code-gen | https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-chat/SKILL.md |
| Image generation | https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-image/SKILL.md |
| Text-to-speech | https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-tts/SKILL.md |
| Speech-to-text | https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-stt/SKILL.md |
| Embeddings | https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-embeddings/SKILL.md |
| Web search | https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-web-search/SKILL.md |
| Web fetch (URL → markdown) | https://raw.githubusercontent.com/decolua/9router/refs/heads/master/skills/9router-web-fetch/SKILL.md |

## Errors

- 401 → set/refresh `NINEROUTER_KEY` (Dashboard → Keys)
- 400 `Invalid model format` → check `model` exists in `/v1/models/<kind>`
- 503 `All accounts unavailable` → wait `retry-after` or add another provider account
