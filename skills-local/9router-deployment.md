## Our deployment (aorus4, internal-only)

Deployed via `ai-dotfiles/ansible-ai/deploy-9router.yml` (docker compose: `9router` + `headroom`), bound to **`127.0.0.1:20128`** on aorus4 — no public surface. Update/redeploy = re-run that playbook (`cd ansible-ai && ansible-playbook deploy-9router.yml`); it re-pulls `:latest` and preserves secrets.

- **On aorus4:** `NINEROUTER_URL=http://127.0.0.1:20128`
- **From macstudio / elsewhere:** tunnel first — `ssh -N -L 20128:127.0.0.1:20128 aorus4` — then `NINEROUTER_URL=http://127.0.0.1:20128`
- **Dashboard first-login:** user `admin`, password from `ssh aorus4 'sudo grep INITIAL_PASSWORD /opt/9router/.env'` (change it after login). Add provider accounts + issue keys there.
- `REQUIRE_API_KEY=false` by default (loopback-only), so `NINEROUTER_KEY` is optional until you enable it.
