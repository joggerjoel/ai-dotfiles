# ai-dotfiles — command runner for the AI workforce fleet.
#   just            → list every recipe (this menu)
#   just <recipe>   → run it
#
# Recipes are grouped: [herdr] the node session backend · [captain] firstmate ·
# [lifecycle] install/maintain · [fleet] ansible over all hosts · [local] this
# machine. Node-targeting recipes are ROLE-AWARE: set FLEET_ROLE=node in the
# node's own .env and they run locally there instead of ssh-ing to themselves;
# everywhere else they ssh to `node`. Fleet recipes need a control machine
# (one with your gitignored ansible-ai/inventory.local.yml) and fail fast with
# a pointer if this isn't one.
#
# NOTE for doc comments: `just --list` shows the LAST comment line above a
# recipe — keep the summary line immediately above the recipe name.

set dotenv-load := true                    # auto-load ./.env if present

node := env_var_or_default("FLEET_NODE", "macstudio")   # the always-on node
role := env_var_or_default("FLEET_ROLE", "hud")         # hud | node | worker (this machine)
dotfiles := justfile_directory()

# Default: show the menu.
default:
    @just --list --unsorted

# ── herdr (the node session backend) ────────────────────────────────
# [herdr] attach the node's herdr session (TUI; on the node itself attaches directly)
attach:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{role}}" = "node" ]; then exec herdr; else exec herdr-remote; fi

# [herdr] node herdr server + session + bridge health
node-status:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{role}}" = "node" ]; then exec "{{dotfiles}}/scripts/herdr-node.sh" status
    else exec ssh {{node}} '~/ai-dotfiles/scripts/herdr-node.sh status'; fi

# [herdr] (re)start herdr server + mesh bridge on the node
node-up:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{role}}" = "node" ]; then exec "{{dotfiles}}/scripts/herdr-node.sh" up
    else exec ssh {{node}} '~/ai-dotfiles/scripts/herdr-node.sh up'; fi

# [herdr] install the node's launchd agents (server + bridge, always-on)
node-services:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{role}}" = "node" ]; then exec "{{dotfiles}}/scripts/herdr-node.sh" service install all
    else exec ssh {{node}} '~/ai-dotfiles/scripts/herdr-node.sh service install all'; fi

# ── captain (firstmate) ─────────────────────────────────────────────
# Ensures a persistent captain tab (claude in ~/firstmate) inside the node's
# herdr session, then attaches. Survives laptop lids, dropped connections, and
# reboots — detach with Ctrl-b q, the crew keeps cooking.
# [captain] PERSISTENT captain: ensure the captain tab on the node, then attach
captain: node-up
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "{{role}}" = "node" ]; then
      "{{dotfiles}}/scripts/herdr-node.sh" captain-tab
      exec herdr
    else
      ssh {{node}} '~/ai-dotfiles/scripts/herdr-node.sh captain-tab'
      exec herdr --remote {{node}}
    fi

# Ephemeral: claude in your ssh tty — dies with your connection (crewmates it
# spawned survive in herdr). PATH prefix because `ssh -t 'cmd'` is a non-login
# shell where ~/.zshrc never sources.
# [captain] quick EPHEMERAL captain in your ssh tty — one-offs only
captain-quick: node-up
    ssh -t {{node}} 'export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"; cd ~/firstmate && claude'

# ── lifecycle (install/maintain: scripts + Setup hook + agentic prompts) ──
# [lifecycle] deterministic tool-floor census only (no agent)
init:
    {{dotfiles}}/scripts/setup-init.sh

# [lifecycle] one-shot agentic install/verify of this machine
install:
    cd {{dotfiles}} && claude --init "/install"

# [lifecycle] human-in-the-loop install (onboarding a machine or an engineer)
install-hil:
    cd {{dotfiles}} && claude --init "/install interactive"

# [lifecycle] agentic maintenance pass on this machine (report-first)
maintain:
    cd {{dotfiles}} && claude --maintenance "/maintain"

# [lifecycle] agentic maintenance across all hosts (report-first, confirm gates)
fleet-maintain: _control
    cd {{dotfiles}} && claude --maintenance "/maintain fleet"

# ── review (SHIPIT cold passes; run from anywhere via `just -g`) ────
# [review] round 1 FIND pass: deep fable + 4 sonnet lenses on the given file(s)
review-wide +FILES:
    isolate --wide "$(cat {{FILES}})"

# [review] convergence check: one deep pass, MATERIAL/NIT rubric — done at MATERIAL: 0
review +FILES:
    isolate --review "$(cat {{FILES}})"

# ── fleet (ansible over all hosts; control machine only) ────────────
# Guard: fleet recipes need this machine to hold YOUR inventory (gitignored).
_control:
    @test -f "{{dotfiles}}/ansible-ai/inventory.local.yml" || { \
      echo "✗ not a control machine: ansible-ai/inventory.local.yml is absent."; \
      echo "  Fleet recipes run from a machine holding your inventory —"; \
      echo "  generate one from ~/.ssh/config: ansible-ai/ssh-ansible-sync.sh"; \
      exit 1; }

# [fleet] update every host (ai_all: the whole fleet incl. this box)
fleet-update: _control
    cd {{dotfiles}}/ansible-ai && ansible-playbook update.yml

# [fleet] install/refresh `just` on every host
fleet-just: _control
    cd {{dotfiles}}/ansible-ai && ansible-playbook provision-just.yml

# [fleet] refresh the agent CLIs (claude/codex/pi/grok/…) everywhere
fleet-harnesses: _control
    cd {{dotfiles}}/ansible-ai && ansible-playbook update.yml --tags harnesses

# [fleet] push local config out to the fleet
fleet-push: _control
    cd {{dotfiles}}/ansible-ai && ansible-playbook push-config.yml

# [fleet] provision the always-on node as the firstmate node
provision-node: _control
    cd {{dotfiles}}/ansible-ai && ansible-playbook provision-firstmate.yml

# [fleet] ad-hoc: reachability check across the fleet
ping: _control
    cd {{dotfiles}}/ansible-ai && ansible ai_all -m ping

# ── local (this machine) ────────────────────────────────────────────
# [local] refresh this machine's agent CLIs + plugins
update:
    {{dotfiles}}/update.sh

# [local] re-run setup on this machine
setup:
    {{dotfiles}}/setup.sh

# [local] lint every shell script in scripts/
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v shellcheck >/dev/null || { echo "shellcheck not installed (brew install shellcheck)"; exit 1; }
    shellcheck -S warning {{dotfiles}}/scripts/*.sh {{dotfiles}}/*.sh

# [local] verify every configured asset actually works (read-only)
preflight *ARGS:
    {{dotfiles}}/scripts/preflight.sh {{ARGS}}

# [local] preflight plus tier-3 smoke tests
audit:
    {{dotfiles}}/scripts/preflight.sh --smoke

# [local] run the preflight test suite
test:
    {{dotfiles}}/tests/preflight/run.sh
