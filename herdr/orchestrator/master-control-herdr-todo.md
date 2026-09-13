# Master Control Herdr Execution Roadmap (TODO)

> **This file tracks work, not design.** `master-control-herdr-plan.md` is the source of truth for
> every decision; items here cite the section that governs them and must not restate it. The
> previous version of this file drifted into describing designs the plan had already rejected
> (re-prompting the same worker after a failure, LLM-dispatched triage), and anyone building from
> it would have reintroduced both. If an item and the plan disagree, the plan wins and the item is
> stale.

**Status.** Phases 1 and 2 are built. The CLI surface is verified against herdr 0.9.0 (§11.1) and
the full lifecycle has been driven by hand on both a passing and an unsatisfiable task (§2.3,
§10.2). Phase 3 is the next build and is unblocked. Phase 8 is blocked and may never ship.

---

## Phase 1: Local baseline and machine context — DONE

- [x] **1.1 Verify local Herdr installation and server health**
  - [x] `herdr status` reports a running server (0.9.0, protocol 22).
  - [x] `herdr agent` and `herdr integration` surfaces confirmed.
- [x] **1.2 Machine Context Pack (`MACHINE.md`) template** — schema in §4.
  - [x] Paths, ports, runtimes, package managers, timezone, conventions.
  - [x] Autonomy guidelines codified.
- [x] **1.3 Queue schema (`TODO.template.md`)** — recognizer and marks in §2.5.

## Phase 2: Auto-unblocker and prompt interceptor — DONE

Shipped as `herdr_unblocker.py` with `test_unblocker.py`. Absorbed by the supervisor in Phase 3
rather than remaining a standalone watcher.

- [x] **2.1 State detector** — `agent wait --until blocked`, buffer capture via
      `--source recent-unwrapped`, fallback to `--source visible` for TUIs.
- [x] **2.2 Pattern matching for trivial prompts** — `[y/N]`, pager halts, diff approvals.
- [x] **2.3 Anti-loop circuit breaker** — buffer hashing, freeze after 3 identical prompts.
- [x] **2.4 Deterministic triage with a safety gate** — `ESCALATE_DANGEROUS` on `rm -rf`,
      `DROP TABLE`, and the §5 row-2 pattern set.
  - Corrected from the original item, which called for an LLM dispatch pipeline. §8 demoted the
    triage dispatcher to a deterministic router so attacker-influenced text never reaches a model
    before containment applies. The shipped classifier is pure regex, which is correct, not a gap.

## Phase 3: TODO lane, first vertical slice — NEXT

One lane, one machine, end to end. Port `attempt.sh` (the prototype that drove the full lifecycle
successfully) rather than building from the spec; it is the only executable artifact that has run.

- [ ] **3.1 `herdr-master` CLI skeleton** — `run`, `status`, `ack`, `abort`, `trust` (§2.6, §3).
      One binary. There is no separate `herdr-ctl`.
- [ ] **3.2 Queue reader and marks** — `[ ]`/`[>]`/`[x]`/`[!]` with `task_id` in the line, at
      `~/.herdr-master/machines/<profile>/TODO.md` on the orchestrator (§2.5).
- [ ] **3.3 Work-unit lifecycle** — worktree from `origin/<base_branch>`, pane created with
      `pane split --cwd <tree>` (cwd is a pane property, not an agent property, §2.3), name-to-id
      map held supervisor-side because `pane rename` is display-only (§2.3, §7).
- [ ] **3.4 Dispatch** — `agent start --kind --pane`, branch on `launch_pending` since the startup
      trust prompt is once per path (§10.2), then `agent prompt --wait` to avoid the dispatch race.
- [ ] **3.5 Packet builder** — §10.2. Assembled from scratch each attempt. **Must include the
      blocker instruction**; without it a worker reports `done` against a red verifier and says
      nothing (`skills/amnesiac-workers/references/task-packet.md` has the wording that worked).
- [ ] **3.6 Attempt close** — secret scan, commit under §6's staging rule, harvest and validate
      `.herdr/facts.json` and `.herdr/blockers.json`, write master state outside the tree, destroy
      the worker (§10.2).
- [ ] **3.7 Persisted state** — `state.db`, `actions.jsonl`, name-to-id map, revalidated against
      `pane list` on daemon start (§2.6, §7).

## Phase 4: Verification gate — NEXT, with Phase 3

- [ ] **4.1 Dedicated verify pane** per lane, leased FIFO like worker panes (§6).
- [ ] **4.2 Verification** — command resolved from supervisor-owned config, run in the unit's tree
      under the exit protocol, awaited with `pane wait-output --regex 'MC-EXIT <nonce> [0-9]+'`
      (§6). `pane run` is fire-and-forget, so the sentinel is the only way to get an exit code.
- [ ] **4.3 Gates** — test-surface diff gate, dependency gate, secret scan, then the land step
      (§6). On failure the attempt **ends**; the trace goes into the next packet, never back into
      the worker that produced it (§10.2).
- [ ] **4.4 Unseen-path escalation** — staged paths not previously seen in that repo escalate,
      because agent tooling writes into work trees and no denylist anticipates the next one (§6).

## Phase 5: First run in escalate-heavy mode, then ratify the numbers

Gate on this before enabling any §5 auto-answer row. Required by §11.2.

- [ ] **5.1 Run the lane with §5 rows 5–9 disabled** so every blocked prompt escalates.
- [ ] **5.2 Capture the prompt corpus** from the action log across every agent kind in use. One
      entry exists so far (Claude Code's folder-trust menu, §11.1); codex, gemini, and cursor are
      uncaptured. Confirm whether one `C-c` interrupts each CLI (§10.3).
- [ ] **5.3 Set thresholds from the log** — retry budget, nudge cap, injection cap, ack timeout,
      `test_timeout_ms`, stall-detector windows. All are currently invented (§11.2), and the first
      live runs suggest `test_timeout_ms` at 600000 is far too generous for small units.
- [ ] **5.4 Enable §5 rows incrementally**, re-reading the log after each.

## Phase 6: Multi-machine fleet

- [ ] **6.1 Machine registration** — `herdr machine add`; passwordless SSH over Tailscale (§7).
- [ ] **6.2 Remote addressing** — **there is no `--machine` flag** (§2.3). Decide between
      `herdr --remote <target>` and `ssh <target> "herdr …"` with a round-trip test first.
- [ ] **6.3 Machine-appropriate routing** — per-machine queues on the orchestrator (§2.3, §7).

## Phase 7: Escalation and notification channels

- [ ] **7.1 `herdr-master ack`** as the input channel, with the kind-keyed ack matrix (§5).
- [ ] **7.2 Desktop notification and chime** on human-required escalation (§5 delivery).
- [ ] **7.3 Remote alert** on sprint completion or halt.
- [ ] **7.4 `herdr-master status`** — lane state, queue depths, quarantined count, archive
      locations, open escalations.

## Phase 8: Incident lane (on-call SRE engine) — BLOCKED

> **Do not start.** §10.4 requires every pane executing agent-authored code to run as a separate
> `herdr-agent` OS user, and herdr 0.9.0 has no user-targeting concept anywhere in its API schema
> or on `agent start`, `pane split`, or `machine add`. The documented alternative is that this lane
> does not ship. Running internet-sourced work in the operator's trust domain is not a fallback.

- [ ] **8.0 Unblock first** — test whether `pane run <id> 'exec sudo -u herdr-agent -i'` reparents
      the pane's processes, and whether `agent start` readiness detection survives a su'd shell.
      If it does not, this phase is cancelled rather than deferred.
- [ ] **8.1 Prerequisites before enabling** (§11.3) — public-ingress relay, branch protection on
      every routed `base_branch`, `herdr-agent` provisioning.
- [ ] **8.2 Ingress authentication and alert intake** (§8.1).
- [ ] **8.3 Fingerprint, incident id, dedupe, throttling** (§8, "Incident Identity").
- [ ] **8.4 Service routing matrix (`ROUTER.json`)** (§8.4). Template already exists on disk.
- [ ] **8.5 Dispatch, verification, land, reply** (§8, "Dynamic Dispatching" and "Resolution Feedback Loop"; the reply email is §8.6).

## Phase 9: Auth bridge and rate-limit handling

Independent of Phase 8 and useful to the TODO lane on its own.

- [ ] **9.1 Activation URL and device-code interceptor** (§9.2).
- [ ] **9.2 Chrome approval bridge** — every endpoint in the §9.2 allowlist is unverified;
      confirm each or drop it (§11.1).
- [ ] **9.3 OTP intake** (§9.2.3) — a different mailbox with different credentials from §8.
- [ ] **9.4 Rate-limit sleep and verified resume** (§9.3, wired into §5 as row 3).
