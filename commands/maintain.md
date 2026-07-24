---
description: Agentic maintenance pass — reads the setup log, verifies host (or fleet) health, reports drift; applies fixes only after confirmation
---

# /maintain [fleet]

You are running a maintenance pass over this AI-workforce host (ai-dotfiles).
The deterministic stage does the mechanical work; your job is to read its results,
verify what it cannot judge, and surface what needs a human.

Mode: "$ARGUMENTS" — if it contains `fleet`, extend the pass across all hosts via
ansible (step 5). Otherwise this machine only.

**Default posture: REPORT first.** Gather everything, present the findings table,
then ask before applying any fix that mutates state (package updates, service
restarts, file edits). Read-only checks never need confirmation.

## Workflow

1. **Deterministic stage.** If `~/.claude/logs/setup.log` has no `setup-maintenance`
   entries from the last hour, run `scripts/setup-maintenance.sh`. Read the log tail
   (last 40 lines) — treat `fail` lines as your worklist.
2. **Verify host health** (read-only):
   - `scripts/setup-init.sh` summary — tool floor still intact?
   - dotfiles checkout: `git -C <repo> status --porcelain` + `git log --oneline -1`
     vs `origin/main` — is this host running stale or dirty config?
   - on a node (if `~/Library/LaunchAgents/dev.herdr.node.plist` exists):
     `scripts/herdr-node.sh status` — server running, exactly one default session,
     bridge listening?
3. **Judgment layer.** For each `fail` in the log, decide: transient (note it),
   config drift (propose the fix), or real breakage (diagnose root cause before
   proposing anything — read the failing script, don't guess).
4. **Report.** Table: check → status → proposed action. Then ask which fixes to
   apply (AskUserQuestion). Apply only what is approved; re-verify after each.
5. **Fleet mode only:** from `ansible-ai/`:
   - `ansible ai_all -m ping` — reachability map first.
   - `ansible-playbook update.yml` — only after the user confirms (it mutates
     every reachable host).
   - Report per-host: reachable? changed? failed? Offline hosts (e.g. a worker
     that is powered down) are a NOTE, not a failure — name the catch-up command
     (`just fleet-just`, `update.yml`) for when they return.

## Common issues (if you hit EXACTLY these, apply the known fix)

- **Problem:** ansible conditional crashes with `'dict object' has no attribute 'rc'`
  or `'ansible_system' is undefined`.
  **Solution:** an unreachable host has no facts/registers — guard with
  `| default(...)` / `is defined`, never let a down box read as a playbook bug.
- **Problem:** herdr lab/e2e checks flaky when run back-to-back.
  **Solution:** known upstream test contention (see
  firstmate-integration/herdr-e2e-flakiness-report.md); run individually before
  calling anything broken.
- **Problem:** `herdr server stop` seems ignored (server right back up).
  **Solution:** that is launchd KeepAlive doing its job; use
  `scripts/herdr-node.sh down` (or `service uninstall`) rather than raw stops.
- **Problem:** subagent processes accumulating.
  **Solution:** `scripts/cleanup-subagents.sh` (already in the deterministic stage);
  verify count after.

## Rules

- Never `git pull`/commit on the user's behalf; propose it.
- Mutating fixes require explicit confirmation — no exceptions in fleet mode.
- Report failures verbatim; an offline host is not a failure.
