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
