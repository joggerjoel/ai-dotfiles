# BusyBrain and Herdr capability review

> Historical review imported on 2026-09-13. This describes the source version audited then,
> not current implementation status. See the [current resolution](../../merge-busybrain-herdr-council-resolution.md)
> and [build guide](../../guides/building-herdr.md). Quotes and finding IDs are preserved.
> Local navigation links were made repository-relative and stale line suffixes removed;
> those links open current files, not frozen audited copies. Fingerprints identify the original
> review input, not this relocated document. External BusyBrain references require its separate checkout.
> The old completion row includes human-blocked work as complete. That recommendation is
> superseded by merge plan §2.11: human-blocked requirements prevent successful completion.


Reviewed 2026-09-13 from the current working copies of:

- `/Users/joggerjoel/Developer/busybrain`
- `/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator`

## Conclusion

BusyBrain has valuable planning, decomposition, review, recovery, telemetry, and deployment
behavior. Most of that behavior is coupled to Slack, LangGraph, Cursor jobs, mutable dictionaries,
environment flags, and many per-run artifacts. Herdr should carry over the invariants and selected
test cases. It should not import BusyBrain's orchestration graph or persistence layout.

Herdr has a smaller base: queue parsing, packet construction, nonce-bound pane commands, SQLite
state, an action log, and a standalone unblocker. Those parts exist and have focused tests. Herdr
does not yet have an integrated daemon, scheduler, reconciler, reviewer, quota manager, status
service, browser verifier, or multi-machine lifecycle.

## Evidence and rating scale

BusyBrain evidence labels:

- **Proven:** a real external boundary or durable run exercised the feature.
- **Reachable:** code connects the feature to an entry point, but this review did not run the real
  external dependency.
- **Opt-in:** code exists but the default configuration disables it.
- **Synthetic:** a fake runner, generated page, mock service, or synthesized success replaces the
  real boundary.
- **Planned:** no reachable code path was found.

Herdr labels are **implemented**, **partial**, **planned**, and **absent**.

The carryover score measures migration feasibility, not feature quality:

| Score | Meaning |
| ---: | --- |
| 5 | Direct fit with a small adaptation |
| 4 | Strong invariant and test reuse, but rewrite the implementation |
| 3 | Valuable and coupled; design a Herdr-native replacement |
| 2 | Limited transfer; replace or defer |
| 1 | Unsafe or incompatible; reject |

## Verification baseline

- BusyBrain contains 723 Python modules and 434 test-like files. The review ran 129 selected
  orchestration tests plus 6 dashboard cost and trace tests. They passed.
- BusyBrain's main test runner mocks the standards pass, disables coding gates, and leaves the UI,
  visual, and browser E2E gates off. The passing suite does not prove live Slack, model, browser,
  SSH, or Ansible behavior. See
  `test-all.sh` (external BusyBrain source: `busybrain/test-all.sh:14`).
- Herdr passed 112 `herdr_master` tests and 8 unblocker tests. These tests cover local functions and
  fakes, not a complete supervisor or live multi-machine run.

## Capability grid

| Capability | BusyBrain ability | Herdr state | Carryover | Decision |
| --- | --- | --- | ---: | --- |
| Kickoff and intake | **Reachable.** Slack, authenticated job requests, flags, or prefixes enter `start_pipeline()`. Intake applies guards, ACLs, conflict checks, domain context, and optional memory before starting the graph. The caller must know several implicit routes. `runner.py` (external BusyBrain source: `busybrain/orchestration/runner.py:196`) | **Partial.** The queue and task IDs exist. Plain-goal intake and initiative creation do not. [`taskqueue.py`](../../../../herdr/orchestrator/herdr_master/taskqueue.py) | 3 | **Rewrite.** Add one intake compiler for a goal, repository, and profile. It produces requirements, acceptance checks, and dependency-ready units. Reject Slack envelopes and LangGraph routing. |
| Planning and specification | **Reachable.** Supports explicit decomposition, TaskMaster import, spec bundles, planner output, clarification, consensus, and capped replanning. `graph.py` (external BusyBrain source: `busybrain/orchestration/graph.py:1033`) | **Absent.** Packets exist, but no planner or typed requirement ledger creates an initiative. [`packet.py`](../../../../herdr/orchestrator/herdr_master/packet.py) | 3 | **Rewrite.** Keep explicit input precedence, clarification, and rejection-driven replanning. Store normalized requirements and dependencies in SQLite. |
| TODO and decomposition | **Reachable.** Produces subtasks, dependencies, and parallel waves. Explicit operator decomposition can bypass the model. | **Partial.** Marks and ordering work. Description, scope, verification, initiative dependencies, and decomposition are pending. [`merge TODO`](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md) | 3 | **Adapt.** Keep the dependency graph and ready-set scheduling. Make TODO Markdown a projection after intake, not the dependency database. |
| Task packet | **Reachable.** BusyBrain has required template slots and canonical contract injection, but its SDLC packet is large. | **Implemented base.** Herdr rejects missing goals and prior-agent reasoning, validates facts and blockers, and carries verifier evidence. [`packet.py`](../../../../herdr/orchestrator/herdr_master/packet.py) | 5 | **Keep Herdr.** Add BusyBrain's required-slot template rule. Reject the large SDLC packet and fenced final-message manifest. |
| Agent execution and fan-out | **Reachable.** Runs wave workers and reviewers through Cursor jobs, graph threads, and several state stores. | **Partial.** Pane and agent control exists. No daemon joins it to the queue and store. Registered children are planned. [`herdr.py`](../../../../herdr/orchestrator/herdr_master/herdr.py) | 3 | **Rewrite.** The supervisor creates every meaningful child as a unit or actor with a lease and budget. Do not port graph-thread ownership. |
| Completion determination | **Reachable but overgrown.** A large `complete_node` region checks reviews, stages, deployment, repair, summaries, notifications, and Git effects. `graph.py` (external BusyBrain source: `busybrain/orchestration/graph.py:5580`) | **Partial.** Queue transitions and verifier results exist. No initiative completion query exists. | 4 | **Rewrite the invariant.** Completion requires every requirement to be verified and integrated, waived, or human-blocked. Reject `complete_node`. |
| Full-TODO continuation | **Reachable.** Several reconcilers attempt to restart execution, review, and completion after workers stop. The number of recovery paths makes behavior hard to reason about. | **Planned.** Herdr will close a stopped attempt, verify the preserved candidate, retry, and schedule the next unit. [`merge plan §2.7`](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md) | 4 | **Rewrite.** The scheduler owns remaining work. Worker exit ends an attempt, not the initiative. |
| Liveness and recovery | **Reachable and informed by real failures.** The watchdog distinguishes alive, active, waiting, stale, and checkpoint progress. It uses leases and bounded recovery. `pipeline_watchdog.py` (external BusyBrain source: `busybrain/orchestration/pipeline_watchdog.py:40`), `resume_lease.py` (external BusyBrain source: `busybrain/orchestration/resume_lease.py:225`) | **Planned.** Leases, fencing, deadlines, material progress, `next_action_at`, and restart reconciliation are not implemented. | 3 | **Rewrite the invariants.** Keep alive versus progressing, durable deadlines, fencing, orphan adoption, and attempt-boundary recovery. Reject bridge-specific recovery. |
| Interactive prompt handling | **Reachable but spread across many modules.** BusyBrain handles clarification, dead letters, stalls, scope changes, and recovery. | **Implemented standalone.** Herdr classifies safe prompts and detects repeated buffers, but it is not joined to `Store`. [`herdr_unblocker.py`](../../../../herdr/orchestrator/herdr_unblocker.py) | 5 | **Keep Herdr.** Fix the likely `status` versus `agent_status` response-field mismatch and integrate the blocker with persisted escalation state. |
| Persistence and restart | **Reachable.** Atomic JSON writes, request directories, manifests, events, liveness files, and leases exist. Multiple current-state artifacts require reconciliation. `pipeline_store.py` (external BusyBrain source: `busybrain/orchestration/pipeline_store.py:27`) | **Implemented base.** SQLite stores units, attempts, panes, and escalations. The action log stores history. No reconciler drives restart. [`store.py`](../../../../herdr/orchestrator/herdr_master/store.py) | 4 | **Keep Herdr.** Carry over atomic transitions, idempotency, terminal monotonicity, lease recovery, and crash tests. Reject the mutable JSON artifact set. |
| Run record and postmortem | **Reachable.** BusyBrain's large postmortem corpus exposed recurring problems, but it creates many artifacts and accepts model-authored summaries. | **Planned.** Herdr proposes one deterministic terminal record rendered as Markdown when requested. [`merge plan §2.6`](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md) | 4 | **Rewrite.** Store one canonical run record in SQLite and export JSONL idempotently. Preserve aggregate analysis, not per-run plan and TODO files. |
| Verification evidence | **Reachable but heuristic-heavy.** BusyBrain validates per-stage manifests and prose evidence. Some heuristics reject valid evidence. | **Partial.** Herdr captures nonce-bound exit codes and bounded excerpts, but no production verifier owns the full flow. [`herdr.py`](../../../../herdr/orchestrator/herdr_master/herdr.py) | 4 | **Replace.** Use exact candidate commit, command, exit code, duration, policy hash, and artifact references. Port negative test cases, not prose heuristics. |
| Independent review | **Reachable.** Separate reviewer IDs, structured verdicts, several backends, and objective confirmation exist. `reviewer.py` (external BusyBrain source: `busybrain/orchestration/reviewer.py:512`), `review_pipeline.py` (external BusyBrain source: `busybrain/orchestration/review_pipeline.py:778`) | **Planned.** A separate API reviewer and closed finding schema are specified. The current plan still has candidate identity, command trust, secret-screening, and failure-transition gaps. | 4 | **Rewrite.** Keep role separation, structured verdicts, objective checks, and impossible mixed states. Build checks from typed operands. Never execute a model-authored shell command. |
| Lint, unit tests, and build | **Reachable with uneven proof.** Runners and gates exist. The aggregate suite disables coding gates, and some helpers use broad shell execution. | **Partial.** Config parses test and lint commands. No integrated verifier orders lint, unit, build, affected, and full checks. [`config.py`](../../../../herdr/orchestrator/herdr_master/config.py) | 4 | **Adapt tests, replace runner.** Use approved commands, exact working directories, timeouts, captured exit codes, and immutable candidate commits. |
| REST API and health E2E | **Reachable or synthetic depending on the route.** Health and integration probes exist. Some fallbacks infer success without proving the target service. | **Planned at a high level.** Verification can run on eligible machines, but no REST contract runner or service lifecycle exists. | 3 | **Adapt.** Require a real base URL, expected status and schema, state-change evidence, and cleanup. Do not infer REST correctness from portal state. |
| Browser and UI E2E | **Opt-in and partly synthetic.** Playwright captures page and console errors. A small scenario format supports navigation, clicks, fills, visibility, enabled state, text, and waits. Real-app failure can fall back to generated HTML. `playwright_harness.py` (external BusyBrain source: `busybrain/orchestration/playwright_harness.py:14`), `e2e_scenario_runner.py` (external BusyBrain source: `busybrain/orchestration/e2e_scenario_runner.py:9`) | **Planned only as browser-capable verification work.** No browser runner, app lifecycle, screenshot policy, or API correlation exists. | 3 | **Adapt the small runner.** Add network assertions that prove the UI called the expected REST endpoint and changed backend state. A real E2E gate must fail when the app is unavailable. |
| Visual comparison | **Opt-in and brittle.** It captures screenshots and compares raw PNG bytes. The first run writes a baseline and fails for review. | **Absent.** | 2 | **Replace or defer.** Use stable screenshots and a defined pixel or perceptual threshold only where visual regression has value. Keep it separate from action correctness. |
| Branch and worktree isolation | **Opt-in and partial.** Per-subtask worktree creation exists, but no automatic merge-back contract was found. `pipeline_worktree.py` (external BusyBrain source: `busybrain/orchestration/pipeline_worktree.py:9`) | **Planned.** Unit branches, dependency-aware integration, scope leases, and exact candidate commits are specified. | 4 | **Replace.** Use checked Git commands and explicit integration branches. Port isolation tests, not the repo-specific shell wrapper. |
| Commit, push, and integration policy | **Reachable.** Completion can stage everything, commit, and push. Auto-commit defaults on and may conflict with the user's task authorization. `pipeline_git_commit.py` (external BusyBrain source: `busybrain/orchestration/pipeline_git_commit.py:69`) | **Planned.** Scope checks, secret scans, ordered integration, and pull requests exist only in design. | 2 | **Reject BusyBrain defaults.** Require explicit supervisor policy. Stage declared scope only. Bind review and verification to the same immutable candidate. |
| Deployment | **Reachable and external.** Approval, deploy executors, Ansible preflight, canary, smoke, and fleet execution exist. Some local-only paths synthesize success without deployment. | **Outside the first Herdr release.** Herdr plans verification placement, not a deployment control plane. | 2 | **Defer.** Carry immutable artifact and approval ideas only if deployment becomes a Herdr responsibility. |
| Multi-machine execution | **Partial.** Host discovery and prompt-mediated SSH exist. Ordinary work has no durable placement scheduler. Ansible covers deployment. | **Planned.** Capability matching, quotas, transfer cost, fencing, attempt relocation, and verification placement are specified. Remote transport remains unresolved. | 2 | **Replace.** Build the Herdr scheduler. A model must not select the SSH target. Move work only between attempts using exact commits and higher fencing epochs. |
| Provider quota | **Reachable telemetry, weak admission.** Codex probing and project budgets exist. JSON read-modify-write counters and best-effort usage writes cannot enforce concurrent admission. `usage_ledger.py` (external BusyBrain source: `busybrain/orchestration/usage_ledger.py:75`) | **Planned.** SQLite reservation, 95% pause, durable wake, and account-wide pools are specified. | 3 | **Rewrite.** Reuse provider, account, model, and limit vocabulary. Replace counters with transactional reservation and settlement. |
| Tokens and cost | **Reachable estimates.** Ledger rows record input, output, cache, model, role, call site, and estimated cost. Missing ledger data can undercount. `usage_ledger.py` (external BusyBrain source: `busybrain/orchestration/usage_ledger.py:18`) | **Planned.** Actor attribution, reservation, settlement, price versions, and honest unavailable subscription cost are specified. | 3 | **Adapt vocabulary, rewrite storage.** Keep tokens, quota, estimated cost, and billed cost as separate values with evidence labels. |
| Status and progress | **Reachable.** API status combines state, manifests, reviews, usage, budgets, stalls, dead letters, and UI checks from several stores. `runner.py` (external BusyBrain source: `busybrain/orchestration/runner.py:700`) | **Planned.** Typed fleet, initiative, unit, escalation, run, watch, history, diff, evidence, and derived TODO views are specified. | 4 | **Rewrite.** Read from SQLite, Git, and evidence. Keep alive, active, and progressing separate. Do not infer state from pane prose. |
| Web viewer and subagent drill-down | **Reachable but unsafe by default for remote exposure.** Dashboard routes show traces, logs, and estimated cost. Authentication can be disabled, and some read routes expose operational data. | **Planned.** A loopback read-only viewer over the same snapshot and event API as the CLI is specified. | 3 | **Replace.** Build a stateless Herdr viewer. Show actor hierarchy, attempts, machines, models, progress age, usage, commits, verification, and retries. Do not reuse BusyBrain's auth defaults. |
| Notifications and escalation | **Reachable.** Slack and audio cover progress, waiting, failure, and completion. Telegram works when configured. Discord is a stub. | **Partial.** Escalation storage and local blocker notification exist. Bounded packets, acknowledgment, remote notification, and status linkage are planned. | 4 | **Adapt.** Keep bounded failure packets, action mapping, meaningful transition alerts, and the audio helper. Replace Slack coupling with notifier adapters. |
| Memory and learning | **Reachable but broad.** Knowledge graphs, retrieval, learning, retrospectives, pattern libraries, and postmortem mining exist. Generated interpretations can become durable context. | **Mostly absent by design.** Herdr carries validated facts and deterministic run records, not prior-agent reasoning. | 2 | **Rewrite narrowly.** Keep evidence-backed facts, aggregate queries, and operator-approved policy updates. Reject free-form lessons as execution authority. |
| Security boundary | **Mixed.** Broad binds, optional dashboard auth, exposed read endpoints, prompt-selected SSH, auto-push, and model-shaped evidence create unsafe reachable paths. | **Better design, incomplete code.** Nonce checks, redaction, local state, and restricted permissions exist. Separate incident-user execution and remote viewer controls remain planned or unverified. | 2 | **Reject and replace.** Do not port unauthenticated APIs, default-off auth, prompt-mediated SSH, broad Git mutation, or model-authored commands. |

## Carryover order

### 1. Establish one local lifecycle

Implement the daemon path that joins queue intake, SQLite, packet creation, pane dispatch, attempt
close, independent verification, retry, and terminal completion. Fix the unblocker response-field
mismatch during this work.

### 2. Add the missing initiative producer

Define one plain-goal intake contract. Compile it into a typed requirement ledger and dependency
graph. This step replaces BusyBrain's complicated kickoff and supplies the objects the scheduler
and status viewer already expect.

### 3. Carry over bounded invariants

Add required packet slots, deterministic run records, bounded escalation packets, one retry
budget, identical-failure detection, and supervisor-observed command and commit evidence.

### 4. Make unattended continuation real

Add leases, fencing, deadlines, material-progress timestamps, `next_action_at`, restart
reconciliation, idempotent attempt transitions, and crash tests. The supervisor must continue when
a worker stops before finishing the TODO.

### 5. Add quality gates

Bind lint, unit, build, review, REST, and browser checks to one immutable candidate commit. Adapt
BusyBrain's structured reviewer and small Playwright scenario format. Do not reuse its permissive
shell execution or generated-page fallback.

### 6. Add quotas and machines

Implement transactional provider reservations before distributed scheduling. Then add
capability-based placement, attempt-boundary relocation, dependency-aware integration, and
verification jobs on eligible machines.

### 7. Add visibility

Build typed CLI and JSON status first. Add the actor tree, history, evidence, tokens, waits, quota,
and cost labels. Put a read-only web viewer over that same API.

## Do not carry over

- LangGraph as lifecycle authority
- BusyBrain's large completion node
- Slack and Cursor bridge coupling
- Mutable per-run JSON files as current state
- Model-authored final-message manifests
- Prose-length and path-regex evidence checks
- Multi-pass review-normalization loops
- Generated HTML presented as real application E2E
- JSON quota counters
- Model-selected SSH targets
- Default-on `git add -A`, commit, and push
- Synthetic local-only deployment reported as deployed
- Operational APIs with authentication disabled by default
- Model-authored lessons promoted to execution authority

## Open blockers

1. Herdr has no component that converts a broad goal into an initiative and dependency graph.
2. Herdr's daemon and full queue-to-land lifecycle do not exist.
3. Remote transport is unresolved.
4. The planned reviewer is not bound to one immutable candidate and still permits unsafe command
   semantics.
5. Browser E2E has no service startup, network assertion, artifact, or cleanup contract.
6. The 95% quota plan lacks an implemented provider reservation and settlement unit.
7. Current Markdown files contain authority and lifecycle contradictions identified by the latest
   council review.
8. BusyBrain's large test count does not prove its live external integrations.
