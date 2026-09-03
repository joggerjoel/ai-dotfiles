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
# Every ansible line pipes through `cat`: ansible aborts outright when
# stdout is a non-blocking pipe, which is what an agent session or any
# wrapper reading output live hands it. pipefail keeps the real exit code.
# Guard: fleet recipes need this machine to hold YOUR inventory (gitignored).
_control:
    @test -f "{{dotfiles}}/ansible-ai/inventory.local.yml" || { \
      echo "✗ not a control machine: ansible-ai/inventory.local.yml is absent."; \
      echo "  Fleet recipes run from a machine holding your inventory —"; \
      echo "  generate one from ~/.ssh/config: ansible-ai/ssh-ansible-sync.sh"; \
      exit 1; }

# [fleet] update every host (ai_all: the whole fleet incl. this box)
fleet-update: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible-playbook update.yml 2>&1 | cat

# Narrower than fleet-update on purpose. It runs only the git pull and profile
# re-apply, skipping the CLI upgrades, the gateway deploys, and the token
# distribution — that last play asserts a token exists and fails the whole run
# on a fleet that has none, which reads as a broken sync when nothing is broken.
# [fleet] git-sync every host to origin/main, nothing else
fleet-sync: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible-playbook update.yml --tags sync 2>&1 | cat

# [fleet] install/refresh `just` on every host
fleet-just: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible-playbook provision-just.yml 2>&1 | cat

# [fleet] refresh the agent CLIs (claude/codex/pi/grok/…) everywhere
fleet-harnesses: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible-playbook update.yml --tags harnesses 2>&1 | cat

# [fleet] push local config out to the fleet
fleet-push: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible-playbook push-config.yml 2>&1 | cat

# provision-ai.yml is the fleet's dependency installer and is safe to re-run:
# every task gates on the tool already being present, so a converged host skips
# 19-20 of them. Ansible owns dependency convergence because it branches on
# os_family explicitly and reports per host; setup.sh's ensure_* functions
# remain for a machine set up by hand, with no ansible.
# Skips claude-token, whose assert fails the run when no token exists.
# NOTE: targets aorus_ai, so the control node itself is not converged.
# [fleet] install/repair missing tooling on every fleet host
fleet-converge: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible-playbook provision-ai.yml --skip-tags claude-token 2>&1 | cat

# [fleet] provision the always-on node as the firstmate node
provision-node: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible-playbook provision-firstmate.yml 2>&1 | cat

# [fleet] ad-hoc: reachability check across the fleet
ping: _control
    set -o pipefail; cd {{dotfiles}}/ansible-ai && ansible ai_all -m ping 2>&1 | cat

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

# [local] run every test suite — the same command CI runs
test-all:
    @bash {{dotfiles}}/scripts/run-all-tests.sh

# ── global-todo (cross-project worklist from claude-mem + docs) ──────
# The CLI is on PATH as `global-todo` via ~/.local/bin, so these recipes call
# it by name rather than building a path from {{dotfiles}}. That variable is
# justfile_directory(), which under `just -g` resolves to the directory of the
# ~/.justfile SYMLINK rather than its target, producing ~/bin/global-todo.

# [local] what is still owed, across every project
todo:
    @global-todo status

# [local] open the worklist in a browser (summary, then drill down)
todo-open:
    @global-todo open

# [local] rescan docs only — deterministic, no LLM calls, instant
todo-docs:
    @global-todo refresh --docs-only

# [local] rescan both sources; new observations only (~90s per 120-row chunk)
todo-refresh:
    @global-todo refresh --yes

# [local] first run only: sweep all history. ~38 min, ~110 LLM chunks.
todo-cold-start:
    @global-todo refresh --cold-start

# [local] global-todo: unit tests (scripts/global-todo.test.sh)
todo-test:
    @bash {{dotfiles}}/scripts/global-todo.test.sh

# ── fix (targeted repairs; each is idempotent and safe to re-run) ────
# Every recipe here exists because a failure mode recurred. They report
# "already clean" rather than erroring when there is nothing to do, so
# they are safe to chain into a maintenance pass.

# [fix] restart claude-mem only when its worker is present but unresponsive
fix-claude-mem:
    @{{dotfiles}}/scripts/recover-claude-mem.sh

# [fix] install Ghostty terminfo on an SSH host (run on the Ghostty client)
fix-ghostty-ssh HOST="macstudio":
    @{{dotfiles}}/scripts/fix-ghostty-ssh.sh {{HOST}}

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

# Re-vendors every third-party skill source in one verb, so "update the skills"
# is not three script names you have to remember. Updates the repo only — it
# does not deploy; review the diff, commit, then `./setup.sh update` (or let the
# fleet's update.yml do it). Skills authored in this repo are untouched: nothing
# upstream owns them.
# [local] pull all vendored skills from upstream (network; needs git + gh)
vendor-skills:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{dotfiles}}
    # pstack is not in this list: it is no longer vendored into skills/. It is
    # installed at runtime (Claude Code plugin + ~/.agents/skills links) by
    # scripts/sync-pstack.sh, which update.sh and setup.sh already call.
    for s in vendor-9router-skills.sh vendor-unlazy-skill.sh; do
      echo "── $s"
      bash "scripts/$s"
    done
    echo "── validating"
    just fix-skills
    echo "── what changed"
    # Stamps are the drift record: a moved .upstream-* line names the commit
    # range even when no SKILL.md content changed.
    git status --short skills/ skills-local/ || true
    echo "review the diff, then commit — this recipe does not commit or deploy"

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
      # Fenced blocks are stripped first, matching preflight: a documented
      # example of a skill's own output is not a link that has to resolve.
      for ref in $(awk '/^[[:space:]]*```/{fence=!fence;next} !fence' "$f" 2>/dev/null | grep -oE '\(references/[^)]+\)' | tr -d '()' | sort -u); do
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

# ── herdr (moved out) ────────────────────────────────────────────────
# [herdr] herdr node recipes moved to ~/Developer/herdr (2026-08-22)
herdr:
    @echo "herdr recipes live in ~/Developer/herdr — run: cd ~/Developer/herdr && just"
