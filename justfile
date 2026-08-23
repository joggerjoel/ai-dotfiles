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

# [local] injection-guard: unit tests + backtest against real transcripts
guard-verify:
    @bash {{dotfiles}}/hooks/injection-guard.test.sh

# [local] injection-guard: full hit list from the transcript corpus
guard-report:
    @{{dotfiles}}/hooks/injection-guard.backtest.py

# [local] cache-guard: unit tests (hooks/cache-guard.test.sh)
cache-test:
    @bash {{dotfiles}}/hooks/cache-guard.test.sh

# One command: prompt for the token if it is missing, prove it authenticates
# BEFORE writing anything, store it 0600, then deploy to the fleet. Prompting
# and writing happen in the same process — a `read` in one shell and a `printf`
# in another produced an empty CLAUDE_CODE_OAUTH_TOKEN= line that passed every
# "is it set?" check and authenticated nothing.
# Needs no inventory: hosts resolve through ~/.ssh/config unless
# ansible-ai/inventory.local.yml exists, which is preferred when it does.
# [herdr] put the Claude fleet token in place: `just claude-token [host...]`
claude-token *HOSTS:
    @bash {{dotfiles}}/scripts/claude-token.sh {{HOSTS}}

# [herdr] same, but write nothing — proves the token works and shows the diff
claude-token-check *HOSTS:
    @bash {{dotfiles}}/scripts/claude-token.sh --check {{HOSTS}}

# [local] claude-token: unit tests (scripts/claude-token.test.sh)
claude-token-test:
    @bash {{dotfiles}}/scripts/claude-token.test.sh

# [local] per-session cache/token report via ccusage (on demand — never in the statusline)
cache-report *ARGS:
    bunx ccusage@latest claude session --breakdown {{ARGS}}

# [local] lint every shell script in scripts/, hooks/ and the repo root
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v shellcheck >/dev/null || { echo "shellcheck not installed (brew install shellcheck)"; exit 1; }
    shellcheck -S warning {{dotfiles}}/scripts/*.sh {{dotfiles}}/*.sh {{dotfiles}}/hooks/*.sh

# [local] verify every configured asset actually works (read-only)
preflight *ARGS:
    {{dotfiles}}/scripts/preflight.sh {{ARGS}}

# [local] preflight plus tier-3 smoke tests
audit:
    {{dotfiles}}/scripts/preflight.sh --smoke

# [local] run the preflight test suite
test:
    {{dotfiles}}/tests/preflight/run.sh

# ── fix (targeted repairs; each is idempotent and safe to re-run) ────
# Every recipe here exists because a failure mode recurred. They report
# "already clean" rather than erroring when there is nothing to do, so
# they are safe to chain into a maintenance pass.

# [fix] untrack the per-host injection-guard baseline (must never be committed)
fix-baseline:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{dotfiles}}
    BASELINE=hooks/injection-guard.baseline.json
    if ! grep -qxF "$BASELINE" .gitignore; then
      printf '\n# per-host injection-guard baseline (never shared — see 6e37940)\n%s\n' "$BASELINE" >> .gitignore
      echo "  + .gitignore now ignores $BASELINE"
    else
      echo "  ✓ .gitignore already ignores $BASELINE"
    fi
    if git ls-files --error-unmatch "$BASELINE" >/dev/null 2>&1; then
      git rm --cached -q "$BASELINE"
      echo "  + untracked $BASELINE (still on disk)"
      echo "  → commit + push, then 'just fleet-update' to clear it fleet-wide"
    else
      echo "  ✓ $BASELINE is not tracked"
    fi

# [fix] force-reinstall just on the Linux fleet (installer refuses to overwrite)
# aorus_ai only — on the Mac control node just is brew-managed, and dropping a
# newer binary into ~/.local/bin would shadow brew's copy and split the versions.
fix-just: _control
    cd {{dotfiles}}/ansible-ai && ansible aorus_ai -m shell -a \
      "curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --force --to \$HOME/.local/bin && \$HOME/.local/bin/just --version" \
      2>/dev/null | grep -E 'CHANGED|SUCCESS|UNREACHABLE|FAILED|^just '

# [fix] report skills with a frontmatter name mismatch or a dead reference
fix-skills:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{dotfiles}}/skills
    problems=0
    for d in */; do
      s="${d%/}"; f="$s/SKILL.md"
      [ -f "$f" ] || continue
      name=$(awk -F': *' '/^name:/{gsub(/"/,"",$2); print $2; exit}' "$f")
      if [ "$name" != "$s" ]; then
        echo "  ✘ $s: frontmatter name '$name' != directory"
        problems=$((problems+1))
      fi
      # every references/<file> link must resolve on disk. preflight reports
      # only the first miss per skill, so this lists all of them at once.
      for ref in $(grep -oE '\(references/[^)]+\)' "$f" 2>/dev/null | tr -d '()' | sort -u); do
        if [ ! -e "$s/$ref" ]; then
          echo "  ✘ $s: dead reference $ref"
          problems=$((problems+1))
        fi
      done
    done
    if [ "$problems" -eq 0 ]; then
      echo "  ✓ every skill: frontmatter name matches directory, all references resolve"
    else
      echo "  $problems problem(s) — each needs a real edit; this recipe reports, it does not guess"
    fi

# [herdr] herdr node recipes moved to ~/Developer/herdr (2026-08-22)
herdr:
    @echo "herdr recipes live in ~/Developer/herdr — run: cd ~/Developer/herdr && just"
