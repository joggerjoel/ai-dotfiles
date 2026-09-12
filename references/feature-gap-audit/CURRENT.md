# Feature Gap Audit — Current State

**Last run:** 2026-09-12 (run 2 + reconciliation)
**Run snapshot:** runs/2026-09-11-run2.md

## TL;DR

Two independent references now point at the same P1. qm and firstmate both ship a
harness-independent command policy; ours binds Claude only — 9 deny rules in
`profiles/*/settings.json`, and nothing whatsoever for codex, opencode, gemini, pi or
grok, all of which this repo installs. Run 2 found the implementation is already on this
machine: `scripts/provision-firstmate.sh` clones firstmate to `~/firstmate` and never
configures it, and firstmate's policy is exactly the shape to copy — one semantic
classifier plus a thin transport per harness.

Run 2 also corrected two failures of run 1. "Built (unmerged): none" was an unrun check,
not a finding, and it was hiding a real stranded PATH bug. And the fork parent
`iamnolanhu/claude-dotfiles` turns out to be exhausted — dormant, fully surpassed, safe to
drop from the pinned list.

Category note, unchanged: qm is a hosted multi-user platform, ai-dotfiles is a per-machine
config and fleet-provisioning layer. Not substitutes; compare only at the level of
portable patterns.

## Side-by-side

| Dimension           | qm                                                                                                   | ai-dotfiles                                                                                                      |
| ------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Category            | Hosted multi-user runtime (Slack + web), Postgres, Fastify                                           | Per-machine config + fleet provisioning for local agent CLIs                                                     |
| Harnesses           | 4 (pi, opencode, codex, claude) behind one `Harness` interface, switchable per turn                  | 11 CLIs installed side by side; no shared interface; fusion/council orchestrate via `claude -p` / `codex exec`   |
| Rulebook            | `CLAUDE.md -> AGENTS.md` symlink                                                                     | Assembled `CLAUDE.md` linked into codex, opencode, gemini (`lib/links.sh`)                                       |
| Memory              | Built-in notebook, 3 strategies, pluggable providers (MCP, memorable), per-scope, benchmarked        | claude-mem plugin + Claude auto-memory; single scope                                                             |
| Skills              | Registry with draft/review/published, ACL grants, git packs at pinned ref with sync, admin promotion | 43 repo skills symlinked into `~/.claude` and `~/.codex`; vendored pins (`.upstream`); pstack sync; no lifecycle |
| Background work     | Crons, watches, webhooks (5 verifiers), inbox loops, all in core                                     | Shell crons (fleet update, marketplace refresh), `/loop`, scheduled-tasks plugin                                 |
| Security posture    | strict/auto/dangerous, org floor scopes can only tighten                                             | Single `permissions` allow/deny list per profile                                                                 |
| Command policy      | `ORG_FLOOR_RULES`, harness-independent, quote/heredoc-aware                                          | `permissions.deny` in Claude settings only                                                                       |
| Injection screening | LLM classifier, provenance labels, quarantine, shadow mode, unscreened notice                        | Regex PostToolUse hook, shadow -> enforce, per-host baseline                                                     |
| Egress              | Envoy proxy, per-scope allow/deny hosts, fail-closed                                                 | None                                                                                                             |
| Audit               | Postgres audit log, egress audit, credential-usage sink, admin views                                 | None (claude-mem is partial history)                                                                             |
| Sandbox             | Per-scope durable sandbox, 8 backends                                                                | Agents run on the host; firstmate crewmate sandboxes only with the crew layer                                    |
| Sessions            | Postgres tape, session sharing                                                                       | herdr on the always-on node (process-level persistence)                                                          |
| Model routing       | Catalog + admin overlay + gateway transport + per-user creds                                         | 3 tiers (subscription / 9router ~690 models / ollama); frontier never via gateway                                |
| Observability       | Admin metrics/errors/audit views; no Prometheus                                                      | Prometheus + Grafana + Loki fleet stack; cache-guard statusline                                                  |
| Multi-user          | Core feature                                                                                         | Single operator                                                                                                  |
| Deployment          | `qm` CLI, fly/aws/porter/docker/helm, terraform                                                      | ansible playbooks, `setup.sh`, pull-based from `origin/main`                                                     |
| Review discipline   | Mandatory independent `/code-review`, dev-instance live QA, zero-comments rule                       | council / fusion / isolate / SHIPIT, pstack + superpowers, code-simplifier gate                                  |
| CI                  | Sharded tests, eslint+oxlint+knip, PgBouncer, coauthor-trailer rejection                             | 386 tests (`just test-all`) + shellcheck + cold install, manual dispatch only                                                      |
| Contributions       | Human-prose ADRs only                                                                                | Cold-install reports                                                                                             |

## Gap log

### Shipped on main

- **One rulebook for every harness** (qm: `CLAUDE.md -> AGENTS.md`). Ours: `lib/links.sh:212-215`.
- **Command denial floor** for Claude (qm: `ORG_FLOOR_RULES`). Ours: `profiles/*/settings.json` deny list. Same items: recursive rm, force push, drop/truncate table.
- **Shadow-then-enforce injection screening** (qm: `runShadowScreen`). Ours: `hooks/injection-guard.py` `INJECTION_GUARD_MODE`.
- **Skills pinned from git** (qm: skill packs at pinned ref). Ours: `skills/unlazy/.upstream`, `scripts/vendor-*.sh`, `scripts/sync-pstack.sh`.
- **Layered private config** (qm: `deploy/layers/<org>/` + private fork). Ours: `base/` + `profiles/` + gitignored `.local/`.
- **Homebrew shellenv re-assert** — promoted from "Built (unmerged)" on 2026-09-12.
  Merged as `0b4e469`. `zsh/modules/homebrew.zsh` re-asserts `brew shellenv` at module
  order 05, ahead of zinit and the `command -v` guards that depend on it, so a missing or
  clobbered `~/.zprofile` line can no longer strip `/opt/homebrew/bin` from PATH. Verified
  at merge: recovers `tmux`/`tmuxp` from a PATH cut to `/usr/bin:/bin`, and leaves PATH
  byte-identical when brew is already present, so no duplicate is prepended per shell.
  Carried its two siblings with it — the `fastMode` desktop setting and the
  `agents-update` claude-mem reclassification. **Found only because run 2 surveyed
  branches; run 1 declared "Built (unmerged): none" without looking.**
- **Codex skill allowlist widening** — promoted from "In progress" on 2026-09-11 (run 2).
  Shipped as `6aa8e94`; `setup.sh:1040` `CODEX_SKILLS` is now a multi-line array, no longer
  `(unlazy)`.
- **Things qm lacks that we have:** ansible fleet provisioning, Prometheus/Grafana/Loki, 11 harnesses, model tiers with gateway blast-radius policy, council/fusion/isolate, cache-guard.

### Built (unmerged)

Surveyed 2026-09-11 (run 2), the check the first run skipped.

- ~~**Homebrew shellenv re-assert**~~ — **promoted to Shipped 2026-09-12.** See below.
- **Fleet-connected autopilot design** — `origin/docs/fleet-connected-autopilot-design`,
  1 ahead / 56 behind, 10 days old. A 173-line design doc, unmerged. No code. Still the
  only genuinely stranded item.

Resolved, not stranded:

- `origin/archive/symlink-repair-original` (20 ahead / 165 behind) is correctly named.
  Its work reached `main` by another route — `lib/links.sh`, `relink_all` and
  `tests/preflight/run.sh` are all present on main. Historical artifact; ignore.

### In progress

- None. The previous entry has shipped — see below.

### Not started — from qm

| Priority | Gap                                                                    | qm source                                                                     | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| -------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1       | Harness-independent command policy                                     | `src/policy/command-policy.ts`                                                | Deny list is Claude-only today; codex/opencode/pi/gemini get nothing. Could be a shell wrapper or per-harness config emitted by `setup.sh`.                                                                                                                                                                                                                                                                                                                                                                                                    |
| P2       | Provenance labels + "unscreened" notice on tool results                | `src/security/security-posture.ts` `toolResultProvenance`, `unscreenedNotice` | Our guard only warns on a match; it never labels external content or says when it did not run.                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| P2       | Tool-call audit log                                                    | `src/audit/audit-log.ts`                                                      | Nothing records what agents ran across the fleet. Loki is deployed and could receive hook output.                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| P3       | Egress allow/deny per agent                                            | `src/resolution/egress-policy.ts`, `deploy/egress-proxy/`                     | No control today; a leaked frontier token can reach anywhere.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| P3       | Memory scoping / provider routing                                      | `src/memory/provider-router.ts`                                               | claude-mem is one global scope. Low value for a single operator.                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| P3       | Live-instance QA gate for behaviour changes                            | `.codex/skills/dev-instance`                                                  | We have `verify-ui`/`verify-tui` but no "real by default" instance rule.                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| P4       | Coauthor-trailer CI rejection                                          | `.github/workflows/cicd.yml`                                                  | Only if the AI-attribution preference is "never".                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| P4       | Guard false positives on its own docstring and on security rubric text | this run                                                                      | Partly resolved in run 2. The related _test_ bug is fixed: the self-reference fixture used a relative path, so it passed only from the main checkout and failed from every worktree. The underlying false positive stands — reading the guard's own files from a non-installed checkout still fires, because `SELF_PATHS` is built from `__file__` and knows only the checkout `setup.sh` linked. Do **not** fix by matching any path merely named like the guard; the module comment rules that out as a suppression oracle on a public repo. |
| Option   | Provision qm as a fleet service                                        | `deployment.md`, `cli/`                                                       | Same shape as 9router/firstmate playbooks. Only if multi-user Slack access is wanted.                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

### Not started — from kunchenguid/firstmate

Audited 2026-09-11 (run 2). Independently verified: 5,543 stars, 1,721 forks, 1,271 open
issues, Shell, MIT, pushed the same day. An "agent distro" — a portable directory of
instructions, skills and tooling that turns any harness into a crew orchestrator. Active
and substantial, not a toy.

**Our provisioning of it is bootstrap-only.** `scripts/provision-firstmate.sh` installs
the toolchain (herdr, the harnesses, `treehouse`, `no-mistakes`, the `*-axi` suite) and
`git clone`s firstmate to `~/firstmate` at line 122 — then verifies binaries and stops.
Line 137 says so outright: _"Next: 'gh auth login' (if needed), then launch a harness
inside $FM_DIR."_ Nothing configures the clone: no secondmate registry, no `.tasks.toml`
or `.no-mistakes.yaml`, no per-harness hook wiring, no `gh auth`. Everything past the
clone is manual.

| Priority | Gap                                       | firstmate source                                                                                                                                                                                       | Notes                                                                                                                                                                                                                                                                                                                  |
| -------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **P1**   | Harness-independent command policy        | `bin/fm-arm-command-policy.mjs`, `bin/fm-cd-command-policy.mjs` + transports in `.codex/hooks.json`, `.cursor/hooks.json`, `.grok/hooks/`, `.omp/extensions/`, `.opencode/plugins/`, `.pi/extensions/` | **This is the same P1 the qm comparison raised, and the implementation is already on disk here.** One semantic policy owner (a real tokenizer, not regex) plus a thin fail-open transport per harness. Copy the shape — one classifier, N transports — not a per-harness reimplementation. All paths verified present. |
| P2       | Turn-end / liveness supervision           | `bin/fm-turnend-guard.sh`, `bin/fm-guard.sh`, `bin/fm-wake-lib.sh`, plus per-harness `fm-primary-turnend-guard.*`                                                                                      | Stops an agent silently ending a turn while background work is unsupervised (watcher lock + fresh beacon, PID-strict identity). We have no continuity check for background agent work.                                                                                                                                 |
| P2       | Crew/role registry and charters           | `.agents/skills/secondmate-provisioning/`, `bin/fm-secondmate-*.sh`, `bin/fm-brief.sh`; `data/secondmates.md` is a convention you create, not a shipped file                                           | Structured, auditable persistent named agents with charter, scope and project list. We have no crew/role concept at all. Relevant only if the crew layer is actually adopted.                                                                                                                                          |
| P3       | Task/resource leasing and locking         | `bin/fm-lease.sh`, `bin/fm-lease-lib.sh`, `bin/fm-lock.sh`, `bin/fm-lock-lib.sh`                                                                                                                       | Stops two crew members treading on the same worktree or resource concurrently. No equivalent in our fleet playbooks — and this repo already runs concurrent sessions against shared worktrees.                                                                                                                         |
| P3       | Quota-aware model/provider dispatch       | `bin/fm-quota-choose.sh`, `bin/fm-quota-axi-lib.sh`, `.agents/skills/quota-array-dispatch/`                                                                                                            | Routes work to whichever harness/model still has headroom rather than failing on a rate limit. We have model _tiers_ but no dispatch layer.                                                                                                                                                                            |
| P4       | Hardened non-interactive remote execution | `bin/fm-remote-entrypoint.sh`, `bin/fm-remote-job-lib.sh`, `docs/remote-secondmates.md`                                                                                                                | Fixed entrypoint only, no shell strings accepted, filesystem-derived PATH, no login-shell RC files, dead-peer detection, forwarding disabled. Our fleet plays run ansible/ssh with no equivalent transport hardening.                                                                                                  |
| P4       | Trace context across handoffs             | `bin/fm-trace-context-lib.sh`, `docs/trace-context.md`                                                                                                                                                 | Structured tracing across crew handoffs. Pairs with the qm audit-log gap; Loki is already deployed and could receive it.                                                                                                                                                                                               |

**Do not conflate firstmate with qm's sandboxing ask.** Firstmate ships no container
isolation and no egress control. Verified independently: of its 595 tree paths, zero match
`sandbox`, `egress`, `firewall`, `docker` or `container`. Its safety model is command-shape
classification (tokenize and classify, fail-open on transport error, fail-closed on a real
match) plus liveness supervision. So it answers the P1 command-policy gap strongly and the
P3 egress gap not at all — those still point only at qm.

Integration gap in its own right: we install a crew orchestrator on macstudio and never
configure it. Beyond the clone, nothing seeds a secondmate registry, writes
`.no-mistakes.yaml` or `.tasks.toml`, wires or verifies the per-harness hook files inside
the checkout — which are what actually switch the guardrails on — runs `gh auth login`, or
sets up the SSH aliases `docs/remote-secondmates.md` needs. The remote-secondmate feature
is therefore installed but structurally unreachable. We provision a machine capable of
running firstmate, not a working firstmate. Either wire it up or stop provisioning it;
paying the install cost for an unused clone is the worst of both.

Not verified by this run: `.no-mistakes.yaml`, `.tasks.toml`, `AGENTS.md` §8, and the
bodies of `docs/cd-guard.md` and `docs/subagent-guard.md` — listed but not fetched. Static
read only, no clone and no execution, per the pinned config.

### Not started — from iamnolanhu/claude-dotfiles

**No gaps. Reference exhausted — drop from the pinned list.** Audited 2026-09-11 (run 2).

The fork parent is a 46-blob, 20-commit, single-maintainer snapshot, last commit
2026-08-11, 1 star, 0 open issues. Independently verified: of its 46 files, exactly one
has no local counterpart —
`docs/superpowers/specs/2026-06-26-getting-started-onboarding-design.md`, the design doc
for an onboarding flow this repo already ships as the `getting-started` skill. Not a
capability gap, and `docs/` is gitignored here regardless.

Content diffs on shared files run the other way: upstream lacks our `just preflight` /
`just audit` verification layer, our `INJECTION_GUARD_MODE: enforce`, and our more
complete colon-syntax permission migration. Entire subsystems here have no upstream
counterpart at all — `hooks/`, `lib/`, `ansible-ai/`, `justfile`, `tests/`, `zsh/`.

Note: GitHub's compare API returns 404 between the two, so no ahead/behind count exists —
upstream appears to have rewritten history (its log contains a profile-scrub commit).
Recorded rather than worked around; a synthesised number would be worse than none.

Keep as a one-line "checked 2026-09-11, dormant, no gaps" entry. Do not deep-diff again
unless upstream resumes commits.

## Recommended priority order

1. ~~Merge `fix/homebrew-shellenv-module`~~ — **done 2026-09-12, `0b4e469`.** Was the
   cheapest item on the list: a finished fix, stranded 7 days, needing only a
   merge-forward.
2. **Command policy for every harness** (P1, now corroborated by qm _and_ firstmate).
   Biggest asymmetry, least design: firstmate's one-classifier-plus-transports shape is
   already cloned onto macstudio. Read it before designing anything.
3. Provenance labelling in injection-guard, plus the false-positive allowlist (P2, P4).
4. Decide firstmate's status: wire up the clone we already install, or stop installing it.
5. Audit log via hooks into Loki (P2). Infrastructure already exists.
6. Decide whether qm is a provisioning target or just a reference (Option).

Dropped from the list: `iamnolanhu/claude-dotfiles`, exhausted (see above).

## Run history

| Date       | Snapshot                | Trigger                                                          |
| ---------- | ----------------------- | ---------------------------------------------------------------- |
| 2026-09-11 | runs/2026-09-11.md      | `compare https://github.com/yc-software/qm`                      |
| 2026-09-11 | runs/2026-09-11-run2.md | complete the audit: branch survey + the two unaudited references |
| 2026-09-12 | runs/2026-09-11-run2.md | reconciliation only: merged the stranded homebrew fix, promoted it to Shipped |
