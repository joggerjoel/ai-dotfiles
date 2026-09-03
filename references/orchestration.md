# The runtime view

The README describes what the system *is*. This describes what happens when you
type something — the layers a command passes through, which machine each layer
runs on, and where state actually lives.

Every hostname below (`macstudio`, `aorus…`) is an example from one fleet. Yours
comes from `.env` and your gitignored `ansible-ai/inventory.local.yml`.

## The six layers

```
  operator          you, at a terminal
       │
  launchpad         just — one menu, role-aware
       │
  provisioning      setup.sh · ansible-ai/ · agents-update.sh
       │
  session           herdr — survives your laptop closing
       │
  crew              firstmate — one agent supervising many
       │
  models            frontier · bulk (9router) · local (ollama)
```

Each layer only knows the one beneath it. That is the point: you can run the
top three and stop — a single laptop with no node, no crew, and no gateway is a
valid install. The lower layers are scale, not entry requirements.

| Layer | Owns | Does **not** own |
|---|---|---|
| **launchpad** (`just`) | dispatch, role awareness | any work of its own |
| **provisioning** | what is installed, on which host, at which version | anything at runtime |
| **session** (herdr) | process lifetime, panes, attach/detach | what the agents do |
| **crew** (firstmate) | spawning and supervising agents | how a model is reached |
| **models** | inference | everything above |

## Machine roles

A role is a line in that machine's `.env`, not a different install. Every host
runs the same `ai-dotfiles`.

| Role | `FLEET_ROLE` | What it is | State |
|---|---|---|---|
| **Node** | `node` | The always-on box. Runs the herdr session and, if you use one, the crew. | All session state lives here |
| **HUD** | `hud` (default) | Your laptop. A viewport that attaches to the node. | **None** — close it, lose nothing |
| **Worker** | `worker` | Extra capacity the crew can dispatch to. | Per-task only |
| **Gateway** | — | Runs 9router and the headroom proxy. Membership is inventory group `ninerouter_ai`, not a role. | Model routing config |

The HUD holding no state is the load-bearing property. It is why closing a
laptop mid-run costs nothing, and why `just attach` from a different machine
resumes the same session.

## How one command flows

`just attach`, typed on the laptop:

1. **`just`** reads `FLEET_ROLE` from `.env`. It is `hud`, so this is not the node.
2. The recipe branches: on a node it would `exec herdr` directly; here it runs
   `herdr-remote` (in ~/Developer/herdr), which SSHes to `FLEET_NODE`.
3. **herdr** on the node has been running since it was provisioned. The session,
   its panes, and every agent in them are already alive.
4. You are attached. Anything the crew started while the laptop was shut is
   still running, mid-scroll.

Detach and the node keeps going. That branch — the same recipe behaving
differently by role — is why there is one menu instead of two.

## The deploy path

Nothing reaches a host by hand:

```
edit → commit → push → ansible playbook → hosts pull from origin/main
```

Hosts pull; they are never pushed to. A change that is not on `origin/main`
cannot be on a host, so "what is deployed" is answerable by reading the branch.
`push-config.yml` exists to rsync uncommitted config for testing, and is the
deliberate exception — `verify-config.yml` proves what actually landed.

Playbooks are targeted by inventory group, not by hostname:

| Playbook | Group | Purpose |
|---|---|---|
| `provision-ai.yml` | `aorus_ai` | first-time install of base + harnesses |
| `provision-firstmate.yml` | `firstmate_ai` | the crew manager, node only |
| `provision-firstmate-worker.yml` | `firstmate_worker_ai` | attachable worker sessions |
| `deploy-9router.yml` | `ninerouter_ai` | the model gateway |
| `update.yml` | `aorus_ai` | pull latest and reassemble everywhere |
| `verify-config.yml` | `aorus_ai` | prove a deploy landed |

Adding a machine is a line in the inventory plus the groups it belongs to.

## Where the model tiers are decided

Routing is policy, not plumbing:

- **Frontier** goes through subscription harnesses and deliberately never
  through the gateway. A shared gateway key must not be able to spend a
  frontier account, so the blast radius of a leaked `NINEROUTER_KEY` stays
  limited to cheap capacity.
- **Bulk** goes to 9router, which is bound to localhost on the gateway host and
  reached from elsewhere over SSH.
- **Local** is ollama, LAN-bound, for anything that should not leave the house.

The full operating doctrine is in `skills-local/9router-deployment.md`.

## Related

- [`README.md`](../README.md) — what the system is
- [`FUSE.md`](../FUSE.md) — why isolated review finds what authors miss
- [`SHIPIT.md`](../SHIPIT.md) — the review-and-ship sequence
- [`justfile`](../justfile) — every recipe
