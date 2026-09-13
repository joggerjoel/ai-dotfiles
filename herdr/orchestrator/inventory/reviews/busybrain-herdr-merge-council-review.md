# BusyBrain capability grid against the Herdr merge

> Historical review imported on 2026-09-13. This describes the source version audited then,
> not current implementation status. See the [current resolution](../../merge-busybrain-herdr-council-resolution.md)
> and [build guide](../../guides/building-herdr.md). Quotes and finding IDs are preserved.
> Local navigation links were made repository-relative and stale line suffixes removed;
> those links open current files, not frozen audited copies. Fingerprints identify the original
> review input, not this relocated document. External BusyBrain references require its separate checkout.


Review date: 2026-09-13. Scope is the capability grid, merge plan, and merge TODO, not a new runtime audit of either repository. The test counts in the grid are prior evidence, not tests rerun by this council.

Eight isolated review lenses completed on one model. The 30 raw findings consolidate into 22 anchored entries across 15 root-cause groups: 1 critical, 15 high, and 6 medium. Related entries at different source locations are grouped rather than counted as independent fixes. There are no coverage gaps. This is not multi-provider consensus.

See the [ranked findings, exact quotes, confidence scores, and counterarguments](busybrain-herdr-merge-council-findings.md) and [machine-readable audit evidence](council-raw/merged.json).

## Decision

Revise the merge plan before implementing its reviewer, quota, and initiative layers. The grid's overall recommendation is sound: retain BusyBrain's useful behavior and failure tests, and rewrite against Herdr's supervisor-owned state. However, the grid is not yet reflected consistently in the authoritative plan and TODO.

The stopped-worker design is a substantial improvement. G explicitly closes abandoned attempts, verifies the saved candidate, retries within budget, and scans durable next actions after restart. I supplies capability-based placement and attempt-boundary relocation. J supplies status and actor drill-down rather than relying on TODO check marks. Those decisions should stay.

The next plan revision should address these issues in order:

1. Replace reviewer-generated shell commands with typed checks. Distinguish a disproved finding from an unavailable or failed check. Bind every verdict and verification result to the same immutable base, candidate, and policy.
2. Add plain-goal intake, requirements, decomposition, and a completion query. A human-blocked requirement must keep the initiative blocked, not successfully complete. A waiver needs explicit authorization and a recorded reason. Reject cycles and missing dependencies rather than leaving unschedulable work invisible.
3. Define which worker integrations can enforce quota admission. A daemon-side reservation statement does not intercept model requests inside an arbitrary CLI. Specify reservation units, delayed provider observations, uncertain billing, and window-reset reconciliation before claiming enforcement at 95 percent.
4. Add a real application verification contract. Start the candidate's services, wait for readiness, drive the UI, assert the expected REST request and backend state change, capture evidence, and clean up. An unavailable app must fail the gate. I.7 currently schedules a browser job without defining that job.
5. Store the canonical close record and its export obligation in SQLite. Make JSONL an idempotent export. Define migrations, stable failure fingerprints, and the recovery choice when an offline source machine has not exported its latest candidate.
6. Name the remaining producers and prerequisites: actor registration, browser/runtime setup, daemon restart installation, and remote-viewer access. Keep the viewer read-only and derived from the same state as the CLI.

These are proposed revisions, not changes already applied to the source plan. No implementation, deployment, service shutdown, or source-document edits were performed by this review.

## Acceptance gates to add

| Gate | Required negative case |
| --- | --- |
| Goal to complete initiative | Start from a plain goal, create requirements and units, stop a worker early, finish the remaining units, and keep the initiative blocked when one required item is human-blocked. |
| Safe independent review | Reject arbitrary reviewer commands; make missing tools and timeouts inconclusive; change the candidate after approval and require fresh review. |
| Quota pause and resume | Exercise calls inside each supported worker integration, concurrent reservations, delayed snapshots, uncertain billing, multiple windows, and reset without restored capacity. Resume only on fresh admissible state. |
| Frontend action accuracy | Drive an action against the real candidate app, assert method/endpoint/payload and backend mutation, and fail on wrong API target, missing app, or synthetic fallback. |
| Durable close and recovery | Crash on both sides of terminal commit/export, then prove one canonical close record and no duplicate export. Upgrade an existing nonterminal database fixture. |
| Machine loss | Disconnect before checkpoint export. Either resume from a named durable checkpoint with disclosed lost work or enter a durable wait; never claim the missing candidate transferred. |
| Status accuracy | Compare snapshot, event replay, CLI, TODO, and viewer at the same state revision; prove that heartbeats cannot satisfy completion or material-progress gates. |

## How to treat Markdown going forward

Keep the merge plan as the design authority and the TODO as its implementation checklist until a deliberate intake migration is specified. Keep this council report and the capability grid as review evidence, not executable instructions. Resolve accepted findings into the plan first, then add linked TODO tasks. Record rejected or deferred recommendations explicitly.

Once the requirement ledger exists, generated TODO/status Markdown can become a projection of SQLite. Do not let an old handwritten checkbox or a model's summary override verified state. Deterministic run reports can be rendered on demand; historical design and audit documents can remain archived references without being injected into every worker packet.

## Completion wording needs correction

The grid's completion row says, verbatim: "Completion requires every requirement to be verified and integrated, waived, or human-blocked." This is a synthesis observation, separate from the scored reviewer findings. It conflates successful completion with accounted-for unfinished work. The merge plan's §2.7 correctly keeps `blocked` distinct from `complete`.

Define successful completion as every required item verified and integrated, or explicitly waived by an authorized operator, plus passing final integration gates. A human-blocked item remains visible and prevents successful completion. A run may stop with unresolved work, but its outcome must say blocked or incomplete. The counterargument is that "completion" might mean administrative closure; if that is intended, give administrative closure a different state and never render it as verified success.

## Capability-to-task traceability

"Covered" below means named design and work items exist, not that the capability is implemented or accepted. Scores are the grid's migration-feasibility ratings, not council quality scores.

| Capability | Carryover | Merge work | Assessment |
| --- | ---: | --- | --- |
| Kickoff and intake | 3 | A parses queue fields | Missing plain-goal intake compiler and initiative creation contract. |
| Planning and specification | 3 | G.6 consumes planner output; I.2 stores dependencies | Missing planner, requirement ledger creation, clarification, and replan tasks. |
| TODO and decomposition | 3 | A, I.2–I.3, J.4 | Partial. Input queue and generated projection need a defined import/update boundary. |
| Task packet | 5 | B | Covered. Required slots and live acceptance checks are named. |
| Agent execution and fan-out | 3 | G.1–G.7, J.5 | Partial. Unit ownership is specified; child registration and enforcement need a concrete boundary. |
| Completion determination | 4 | G phases, I.4, J.4 | Missing initiative completion predicate; grid incorrectly includes human-blocked requirements in completion. |
| Full-TODO continuation | 4 | G.3–G.7, I.3 | Covered at unit level; initiative completion and unschedulable dependency handling need closure. |
| Liveness and recovery | 3 | G | Covered in design. Crash recovery must include external side effects, not only database transitions. |
| Interactive prompt handling | 5 | Master lifecycle; E moves loop tracker | Grid's response-field mismatch has no explicit merge task or regression gate. |
| Persistence and restart | 4 | G.1–G.2, G.5, G.7 | Covered in design; record export and external-call recovery require details. |
| Run record and postmortem | 4 | F, G.8 | Conflict. Grid requires canonical SQLite plus idempotent export; F closes by appending JSONL. |
| Verification evidence | 4 | C, F, I.2, I.7 | Partial. Remote evidence has candidate/policy identity; reviewer and local close records need the same identity. |
| Independent review | 4 | C | Conflict. Grid rejects model-authored shell commands; C.5 runs them. |
| Lint, unit tests, and build | 4 | A.4, inherited verifier, I.4, I.7 | Partial. Exact-candidate pipeline and approved command policy need a single contract. |
| REST API and health E2E | 3 | No dedicated work item | Missing service lifecycle, contract assertions, state verification, and cleanup. |
| Browser and UI E2E | 3 | I.7 places browser jobs | Missing real-app runner and UI-to-REST-to-backend assertions. Placement is not verification. |
| Visual comparison | 2 | None | Deliberate replace-or-defer recommendation; not a release blocker unless selected. |
| Branch and worktree isolation | 4 | I.3–I.6 | Covered in design, with integration and overlap tests in I.9. |
| Commit, push, and integration policy | 2 | A.5, I.4–I.6 | Partial. Retain explicit authorization, scope, candidate identity, and secret checks. |
| Deployment | 2 | None | Deliberately deferred. Do not silently add deployment to completion. |
| Multi-machine execution | 2 | I | Covered in design, conditional on the unresolved transport preflight. |
| Provider quota | 3 | H | Partial. Policy is clear; per-call admission for CLI workers and reservation units are not. |
| Tokens and cost | 3 | H, J.7–J.8 | Partial. Attribution is specified; provider observation and settlement contracts need implementation detail. |
| Status and progress | 4 | J.1–J.8, J.11 | Covered in design; ordered snapshot/event consistency needs an explicit protocol. |
| Web viewer and subagent drill-down | 3 | J.9–J.11 | Covered in design; requires runtime provisioning and evidence-access restrictions. |
| Notifications and escalation | 4 | D, inherited notification delivery | Partial. Bounded escalation is covered; adapters and transition alerts remain inherited work. |
| Memory and learning | 2 | F and existing fact validation | Deliberately narrow. Evidence and operator-approved policy, not model reasoning as authority. |
| Security boundary | 2 | C, H, I.1/I.5, J.10 | Partial and contradictory at the reviewer command boundary. |

## Review sources

- [Capability grid](busybrain-herdr-capability-grid.md)
- [Merge plan](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md)
- [Merge TODO](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md)

Combined source SHA-256: `074812614dba4d872b4e42fdc25b36cf9a2f60a93b155b9124a2e118c2656bcd`. Each source is prefixed with `FILE <absolute path>` and a newline, in the order above.
