# ai-dotfiles — command runner for the AI workforce fleet.
#   just            → list every recipe (this menu)
#   just <recipe>   → run it
#
# Recipes are grouped: [herdr] the node session backend · [fleet] ansible over
# all hosts · [captain] firstmate · [local] this machine. Node-targeting recipes
# ssh to `node`; local recipes run here — so you never have to remember whether a
# command belongs on the laptop (HUD) or macstudio (node).

set dotenv-load := true                    # auto-load ./.env if present

node := env_var_or_default("FLEET_NODE", "macstudio")   # the always-on node
dotfiles := justfile_directory()

# Default: show the menu.
default:
    @just --list --unsorted

# ── herdr (the node session backend) ────────────────────────────────
# [herdr] attach the node's herdr session from here over the mesh (no ssh TUI)
attach:
    herdr-remote

# [herdr] node herdr server + session + bridge health
node-status:
    ssh {{node}} '~/ai-dotfiles/scripts/herdr-node.sh status'

# [herdr] (re)start herdr server + mesh bridge on the node
node-up:
    ssh {{node}} '~/ai-dotfiles/scripts/herdr-node.sh up'

# [herdr] install the node's launchd agents (server + bridge, always-on)
node-services:
    ssh {{node}} '~/ai-dotfiles/scripts/herdr-node.sh service install all'

# ── captain (firstmate) ─────────────────────────────────────────────
# [captain] become the captain: open firstmate on the node (interactive)
captain: node-up
    ssh -t {{node}} 'cd ~/firstmate && claude'

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
fleet-maintain:
    cd {{dotfiles}} && claude --maintenance "/maintain fleet"

# ── fleet (ansible over all hosts) ──────────────────────────────────
# [fleet] update every host (ai_all: aorus fleet + macstudio + this box)
fleet-update:
    cd {{dotfiles}}/ansible-ai && ansible-playbook update.yml

# [fleet] install/refresh `just` on every host
fleet-just:
    cd {{dotfiles}}/ansible-ai && ansible-playbook provision-just.yml

# [fleet] refresh the agent CLIs (claude/codex/pi/grok/…) everywhere
fleet-harnesses:
    cd {{dotfiles}}/ansible-ai && ansible-playbook update.yml --tags harnesses

# [fleet] push local config out to the fleet
fleet-push:
    cd {{dotfiles}}/ansible-ai && ansible-playbook push-config.yml

# [fleet] provision macstudio as the firstmate node
provision-node:
    cd {{dotfiles}}/ansible-ai && ansible-playbook provision-firstmate.yml

# [fleet] ad-hoc: reachability check across the fleet
ping:
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
