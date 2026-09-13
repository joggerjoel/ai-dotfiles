# Council findings: capability grid and merge

> Historical review imported on 2026-09-13. This describes the source version audited then,
> not current implementation status. See the [current resolution](../../merge-busybrain-herdr-council-resolution.md)
> and [build guide](../../guides/building-herdr.md). Quotes and finding IDs are preserved.
> Local navigation links were made repository-relative and stale line suffixes removed;
> those links open current files, not frozen audited copies. Fingerprints identify the original
> review input, not this relocated document. External BusyBrain references require its separate checkout.


Reviewed 2026-09-13. These are document-contract findings, not verified exploits or new runtime test results.

## Method and coverage

Eight isolated subagent runs used the current inherited model. This is multi-lens review, not independent multi-provider consensus. Architecture, red-team, security, cost-metering, reliability, code-quality, provisioning, and devil's-advocate all read the complete three-document source. No lens is missing or partial; there were no substitutions, stale runs, speculative findings, or advisory-only runs.

The council produced 30 raw findings. Anchor-based merging produced 22 entries: 1 critical, 15 high, and 6 medium. There are no low findings. Related defects at separate source anchors remain separate entries under shared root causes; therefore 22 is an anchor-entry count, not 22 independent implementation fixes.

The merger validated every quoted snippet against the source and checked the unchanged combined SHA-256 `074812614dba4d872b4e42fdc25b36cf9a2f60a93b155b9124a2e118c2656bcd`. It merged only synthesizer-selected same-defect groups whose snippets overlap at the same source location. It retained every contributing confidence and the maximum reported severity. Scores use severity weight × mean confidence on the 0–100 scale × distinct models. Weights are critical 8, high 4, medium 2, low 1. The distinct-model multiplier is 1 throughout; lens count does not inflate the score. Ranking is by severity, then score. A counterargument accompanies every entry, exceeding the top-quartile and three-run minimum.

The optional isolate-and-edit loop was not used because this request is a review, not authorization to revise the source documents. The broader master plan was not a fourth full council input. Cross-reference omissions below mean no producer or contract was found in the three reviewed documents, not proof that no related mechanism exists anywhere in the repository.

Raw per-lens JSON files are YAML-compatible and retained alongside the [merged data](council-raw/merged.json), which preserves all original findings, confidence values, anchors, and lens attribution. The original workspace-only validation script is not a build dependency..

## Ranked entries

| Rank | Severity | Score | Lenses | Finding |
| ---: | --- | ---: | ---: | --- |
| 1 | critical | 786.67 | 3 | [Reviewer output becomes executable shell authority](#finding-1) |
| 2 | high | 392 | 1 | [REST and browser quality gates have placement but no execution contract](#finding-2) |
| 3 | high | 392 | 1 | [Initiative status and scheduling consume requirements that no task creates](#finding-3) |
| 4 | high | 392 | 1 | [No roadmap task produces the requirements that initiative scheduling and status consume](#finding-4) |
| 5 | high | 390.67 | 3 | [Run records remain append-only JSONL authority despite the SQLite decision](#finding-5) |
| 6 | high | 388 | 1 | [The roadmap schedules browser jobs but never supplies the promised real E2E gate](#finding-6) |
| 7 | high | 384 | 2 | [Review still reads moving refs instead of the immutable candidate](#finding-7) |
| 8 | high | 384 | 1 | [Estimated reservations have no defined unit or conversion to quota percentage](#finding-8) |
| 9 | high | 377.33 | 3 | [Confirmation errors silently remove blocking findings](#finding-9) |
| 10 | high | 376 | 1 | [Pane workers lack a mechanism to reserve before each model call](#finding-10) |
| 11 | high | 364 | 1 | [Review verdict is not bound to the candidate that lands](#finding-11) |
| 12 | high | 348 | 1 | [Provider observations cannot be reconciled safely with local settlements](#finding-12) |
| 13 | high | 348 | 1 | [Browser verification has no provisioned test runtime](#finding-13) |
| 14 | high | 340 | 1 | [Pane workers have no specified per-call quota enforcement boundary](#finding-14) |
| 15 | high | 336 | 1 | [Machine-loss recovery requires artifacts from the unavailable machine](#finding-15) |
| 16 | high | 336 | 1 | [The new external review request has no pre-send secret gate](#finding-16) |
| 17 | medium | 192 | 2 | [Model-assigned identifiers and prose make repeated-failure detection unstable](#finding-17) |
| 18 | medium | 190 | 1 | [Actor drill-down consumes registered children without a registration lifecycle](#finding-18) |
| 19 | medium | 190 | 1 | [Versioned API price schedule has no acquisition or validation task](#finding-19) |
| 20 | medium | 174 | 1 | [The cost record does not define how cached tokens overlap input tokens](#finding-20) |
| 21 | medium | 174 | 1 | [Every review sends an unbounded accumulated branch diff in one request](#finding-21) |
| 22 | medium | 170 | 1 | [New recovery invariants have no migration for existing SQLite rows](#finding-22) |

## Root-cause groups

- review execution: entries 1.
- real e2e: entries 2, 6, 13.
- requirements intake: entries 3, 4.
- run record authority: entries 5.
- candidate identity: entries 7, 11.
- quota arithmetic: entries 8, 12.
- review errors: entries 9.
- quota call boundary: entries 10, 14.
- offline checkpoint: entries 15.
- review egress: entries 16.
- failure identity: entries 17.
- actor lifecycle: entries 18.
- cost evidence: entries 19, 20.
- review input bounds: entries 21.
- state upgrade: entries 22.

## Detailed findings

<a id="finding-1"></a>

### 1. Reviewer output becomes executable shell authority

CRITICAL · score 786.67 · 3 reviewer lenses · 1 model. Confidences: 97, 98, 100. Root cause: `review_execution`. ID: `rt-review-command-authority`.

Anchor: [merge-busybrain-herdr-todo.md / Piece C / C.5](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **C.5 Objective confirmation.** For `test`, `absence`, `path_exists`, and `path_changed`,
      the supervisor runs `verify_cmd` or checks `verify_paths` in the verify pane under the
      exit protocol. An unconfirmed blocking finding is demoted to `warning` and logged.
```

The grid explicitly forbids model-authored shell commands, but plan §2.2 requires a reviewer-supplied verify_cmd and C.5 executes it without a typed operand boundary or approved command mapping. A malicious diff that steers the reviewer can cause arbitrary commands to run with the verifier's permissions; the exit protocol authenticates completion, not command safety.

Fix: Replace verify_cmd with closed typed checks compiled by the supervisor into approved commands, and test rejection of shell syntax, path escapes, and unapproved operations.

Counterargument: The verify pane already runs project test code, and a schema constrains the response shape. Neither limits the reviewer to approved operations. This remains a direct contradiction of the grid; actual exploit reach depends on the verifier's OS permissions.

Contributing runs:

- red_team: `rt-review-command-authority`, critical, confidence 97, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).
- security: `sec-reviewer-shell-authority`, critical, confidence 98, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).
- devils_advocate: `da-review-command-decision-reversed`, high, confidence 100, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

<a id="finding-2"></a>

### 2. REST and browser quality gates have placement but no execution contract

HIGH · score 392 · 1 reviewer lenses · 1 model. Confidences: 98. Root cause: `real_e2e`. ID: `arch-e2e-placement-without-runner`.

Anchor: [merge-busybrain-herdr-todo.md / I.7](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **I.7 Schedule verification as its own work.** Builds, platform tests, GPU tests, and browser
      tests may run on different eligible machines against the exact candidate commit and policy
      hash.
```

The grid adopts a real REST contract runner and a browser scenario runner with service startup, network/backend assertions, artifacts, and cleanup. The plan and TODO only place browser jobs and promise final browser tests; neither produces a runner, app lifecycle, or REST verification contract, so completing I.7 cannot supply the quality gates the grid says to carry over.

Fix: Add named REST/browser runner and service-lifecycle tasks with real-app failure, candidate binding, backend-state assertions, artifact capture, and cleanup acceptance checks.

Counterargument: Existing projects may supply working suites and browsers. The promised out-of-box workflow still needs a contract for discovering, provisioning, executing, and failing those gates.

<a id="finding-3"></a>

### 3. Initiative status and scheduling consume requirements that no task creates

HIGH · score 392 · 1 reviewer lenses · 1 model. Confidences: 98. Root cause: `requirements_intake`. ID: `arch-requirement-ledger-has-no-producer`.

Anchor: [merge-busybrain-herdr-todo.md / J.4](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **J.4 Generate TODO marks from supervisor state.** Render `[ ]`, `[>]`, `[x]`, and `[!]`
      from requirement and unit state. Reject agent-authored completion changes.
```

The grid requires a plain-goal compiler, normalized requirement ledger, and dependency graph, and plan §2.10 consumes the initiative → requirement → unit hierarchy. A only parses task metadata and I.2 adds units/dependencies; no plan section or TODO task creates requirements, maps units to them, or defines verified/integrated/waived/human-blocked requirement transitions, leaving J.4 and initiative completion without their state producer.

Fix: Add an intake and requirement-state contract with explicit producer tasks, requirement-to-unit mappings, terminal rules, and dependencies from scheduling and status.

Counterargument: A prepared queue is sufficient for standalone tasks. It does not deliver the plain-goal initiative workflow adopted by the grid, which explicitly says the producer is absent.

<a id="finding-4"></a>

### 4. No roadmap task produces the requirements that initiative scheduling and status consume

HIGH · score 392 · 1 reviewer lenses · 1 model. Confidences: 98. Root cause: `requirements_intake`. ID: `da-initiative-producer-unscheduled`.

Anchor: [busybrain-herdr-capability-grid.md / Carryover order / 2. Add the missing initiative producer](busybrain-herdr-capability-grid.md).

```text
Define one plain-goal intake contract. Compile it into a typed requirement ledger and dependency
graph.
```

The grid explicitly says initiative creation and its typed requirement ledger are absent. Roadmap I.2 adds storage for units and dependencies, G.6 assumes planner decomposition already produces units, and J.4 renders requirement state, but no task creates the intake/compiler, requirement identities, acceptance mapping, or initiative completion query; completing A–J therefore cannot deliver the promised goal-to-completion workflow.

Fix: Add a named intake and requirement-ledger piece with an end-to-end goal-to-units-to-verified-requirements acceptance test before I and J.

Counterargument: A prepared queue is sufficient for standalone tasks. It does not deliver the plain-goal initiative workflow adopted by the grid, which explicitly says the producer is absent.

<a id="finding-5"></a>

### 5. Run records remain append-only JSONL authority despite the SQLite decision

HIGH · score 390.67 · 3 reviewer lenses · 1 model. Confidences: 97, 97, 99. Root cause: `run_record_authority`. ID: `arch-runrecord-authority-conflicts`.

Anchor: [merge-busybrain-herdr-todo.md / F.2–F.3](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **F.2 The attempt close appends the attempt sub-record** and the unit close appends one
      line to `~/.herdr-master/units.jsonl`. The daemon writes it from `state.db`. Nothing in a
      work tree is read for it.
- [ ] **F.3 `herdr-master status --unit <id>` renders markdown** from that line.
```

The grid explicitly chooses one canonical run record in SQLite and idempotent JSONL export. Plan §2.6 and F.2–F.3 instead make the appended JSONL line the status source, with no persisted close-record key or export cursor; G.2's transactional SQLite transitions cannot atomically commit that file append, so crash recovery can duplicate or omit the only rendered record.

Fix: Persist a uniquely keyed terminal run record in the unit-close transaction, read status from it, and define resumable idempotent JSONL export as a projection.

Counterargument: G.2 requires idempotent transitions. SQLite compare-and-swap alone cannot atomically include a filesystem append; the export obligation needs durable state.

Contributing runs:

- architecture: `arch-runrecord-authority-conflicts`, high, confidence 97, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).
- reliability: `rel-terminal-record-dual-write`, high, confidence 97, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).
- devils_advocate: `da-run-record-authority-conflict`, medium, confidence 99, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

<a id="finding-6"></a>

### 6. The roadmap schedules browser jobs but never supplies the promised real E2E gate

HIGH · score 388 · 1 reviewer lenses · 1 model. Confidences: 97. Root cause: `real_e2e`. ID: `da-browser-rest-gates-unscheduled`.

Anchor: [busybrain-herdr-capability-grid.md / Carryover order / 5. Add quality gates](busybrain-herdr-capability-grid.md).

```text
Bind lint, unit, build, review, REST, and browser checks to one immutable candidate commit. Adapt
BusyBrain's structured reviewer and small Playwright scenario format.
```

The grid records that Herdr lacks a REST runner, browser runner, service lifecycle, and API correlation. I.7 only places browser tests on eligible machines and I.4 requests a final pipeline; no named task implements real application startup/readiness, REST and browser scenarios, backend-state assertions, cleanup, or failure when the application is absent, so these final-gate promises remain unsupported after the listed work.

Fix: Add a named service-lifecycle and REST/browser verifier piece with an unavailable-app negative test and candidate-bound backend-state evidence, or explicitly defer those gates throughout the documents.

Counterargument: Existing projects may supply working suites and browsers. The promised out-of-box workflow still needs a contract for discovering, provisioning, executing, and failing those gates.

<a id="finding-7"></a>

### 7. Review still reads moving refs instead of the immutable candidate

HIGH · score 384 · 2 reviewer lenses · 1 model. Confidences: 99, 93. Root cause: `candidate_identity`. ID: `arch-review-input-is-not-candidate-bound`.

Anchor: [merge-busybrain-herdr-plan.md / §2.2 Lands as](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

```text
The reviewer sees the packet's goal, `git diff origin/<base_branch>..HEAD`, and the
verifier's output.
```

The grid requires review and every verification result to identify one immutable candidate; §2.9 additionally creates unit branches from integration commits containing verified dependencies. §2.2 and C.4 instead build the review from mutable origin/base and HEAD refs without a base SHA, candidate SHA, policy hash, or result binding, so a review can cover a different commit or include already-integrated dependency changes and still be used for landing.

Fix: Pass explicit unit base SHA, candidate SHA, and policy hash through the reviewer request, finding confirmation, stored verdict, and integration admission check.

Counterargument: I.7 already pins verification jobs to a candidate and policy. The reviewer and landing check must explicitly consume that same identity; the current C contract does not.

Contributing runs:

- architecture: `arch-review-input-is-not-candidate-bound`, high, confidence 99, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).
- security: `sec-review-not-bound-to-candidate`, high, confidence 93, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

<a id="finding-8"></a>

### 8. Estimated reservations have no defined unit or conversion to quota percentage

HIGH · score 384 · 1 reviewer lenses · 1 model. Confidences: 96. Root cause: `quota_arithmetic`. ID: `cm-reservation-unit-cannot-be-compared-to-window`.

Anchor: [merge-busybrain-herdr-plan.md §2.8 Provider capacity pauses the run without spending retries](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

```text
Reservations carry `reservation_id`, `unit_id`, `attempt`, `phase`, estimated use, expiry, and
state. A completed call settles actual usage and releases the remainder.
```

The adapter returns normalized percentages and reset observations, but neither §2.8 nor H.1–H.4 defines the reservation unit, per-window capacity denominator, or conversion from a proposed call to each window's consumption. Checking an observed 94.9 percent is insufficient to determine whether multiple estimated calls fit, and no rule bounds actual use by the reserved estimate, so the no-oversubscription acceptance criterion has no enforceable arithmetic.

Fix: Specify per-window capacity units, conservative bounded call estimates, and a transactional projected-usage formula including outstanding reservations; fail closed when the conversion is unavailable.

Counterargument: The 95 percent threshold is a soft admission policy, not a promise that accepted calls cannot exceed it. Nonetheless, concurrent reservation and no-oversubscription tests require compatible units and an explicit accounting rule.

<a id="finding-9"></a>

### 9. Confirmation errors silently remove blocking findings

HIGH · score 377.33 · 3 reviewer lenses · 1 model. Confidences: 96, 95, 92. Root cause: `review_errors`. ID: `rt-unconfirmed-blocker-bypass`.

Anchor: [merge-busybrain-herdr-plan.md / §2.2 / Where it sits in the lifecycle](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

```text
A blocking finding the
supervisor cannot confirm is logged and demoted to `warning`, which is BusyBrain's
`review_gate.py:44-64` rule and the one part of its review loop that reduced churn.
```

The rule makes no distinction between successfully disproving a finding and failing to run its confirmation because of a timeout, missing tool, malformed check, or inaccessible file. A candidate that causes the check to error can therefore turn a real blocker into a warning and proceed to land; C.5 repeats this behavior despite the grid flagging review failure-transition gaps.

Fix: Define confirmed, disproved, and indeterminate confirmation outcomes, and retain a blocking gate with bounded retry or escalation for indeterminate outcomes.

Counterargument: Demoting false positives reduces churn. That is safe only after a completed check disproves the finding; transport and execution errors provide no such evidence.

Contributing runs:

- red_team: `rt-unconfirmed-blocker-bypass`, high, confidence 96, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).
- security: `sec-confirmation-errors-pass-gate`, high, confidence 95, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).
- reliability: `rel-review-failure-has-no-transition`, high, confidence 92, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

<a id="finding-10"></a>

### 10. Pane workers lack a mechanism to reserve before each model call

HIGH · score 376 · 1 reviewer lenses · 1 model. Confidences: 94. Root cause: `quota_call_boundary`. ID: `cm-cli-calls-have-no-admission-boundary`.

Anchor: [merge-busybrain-herdr-plan.md §2.8 Provider capacity pauses the run without spending retries](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

```text
**Invariant.** Before every model call, the daemon reserves capacity in one SQLite transaction.
```

The execution surface remains a worker CLI in a pane (§2.2 and §3), while H.2 defines observation adapters and H.3 only states the reservation invariant. No interception, pre-call callback, credential gateway, or bounded whole-session reservation connects calls made inside those CLIs to daemon admission, so an admitted worker can issue further calls after its pool reaches the threshold; J.7 likewise has no producer of their per-call usage.

Fix: Define and schedule a mandatory admission and usage adapter for each supported CLI, or reserve a bounded session allowance and restrict unsupported execution modes before dispatch.

Counterargument: Some CLI integrations may expose suitable hooks, or an attempt could reserve a bounded session allowance. Neither mechanism is specified for the currently advertised worker kinds.

<a id="finding-11"></a>

### 11. Review verdict is not bound to the candidate that lands

HIGH · score 364 · 1 reviewer lenses · 1 model. Confidences: 91. Root cause: `candidate_identity`. ID: `rt-review-candidate-swap`.

Anchor: [merge-busybrain-herdr-todo.md / Piece C / C.4](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **C.4 The API call.** One Messages request with the schema as the tool input schema. The
      reviewer receives the goal, the diff against `origin/<base_branch>`, and the verifier
      output. A test asserts the worker transcript is not in the request.
```

The grid requires review and verification to share one immutable candidate, but §2.2 uses origin/<base_branch>..HEAD and C.4 records neither immutable endpoints nor a verdict-to-candidate binding. Although §2.9 pins transfer and final test commits, it never makes an existing review invalid after candidate changes, so an edited candidate can reuse approval of an earlier diff.

Fix: Capture immutable base and candidate commits plus verification-policy hash before review, bind the verdict to that tuple, and reject landing or integration when any component changes.

Counterargument: I.7 already pins verification jobs to a candidate and policy. The reviewer and landing check must explicitly consume that same identity; the current C contract does not.

<a id="finding-12"></a>

### 12. Provider observations cannot be reconciled safely with local settlements

HIGH · score 348 · 1 reviewer lenses · 1 model. Confidences: 87. Root cause: `quota_arithmetic`. ID: `cm-provider-snapshot-reconciliation-is-undefined`.

Anchor: [merge-busybrain-herdr-todo.md H.1](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **H.1 Add quota and reservation tables to `state.db`.** Key each pool by provider,
      non-secret account fingerprint, and limit ID. Store every applicable window, observation,
      reset time, state, generation, and probe time.
```

H.1 stores observations and a generation, and H.3 settles local calls, but the documents never define which settlements a provider snapshot already includes or how an outstanding call is assigned across a window reset. Assuming delayed observations, dropping settled reservations before the snapshot reflects them undercounts usage; adding all settlements to a snapshot that already contains them double-counts and creates false pauses.

Fix: Define snapshot watermarks, window identities, and a conservative reconciliation rule that counts each settled or uncertain call once until provider evidence covers it, with delayed-probe and cross-reset tests.

Counterargument: The 95 percent threshold is a soft admission policy, not a promise that accepted calls cannot exceed it. Nonetheless, concurrent reservation and no-oversubscription tests require compatible units and an explicit accounting rule.

<a id="finding-13"></a>

### 13. Browser verification has no provisioned test runtime

HIGH · score 348 · 1 reviewer lenses · 1 model. Confidences: 87. Root cause: `real_e2e`. ID: `prov-browser-runtime-acquisition`.

Anchor: [busybrain-herdr-capability-grid.md / Carryover order / 5. Add quality gates](busybrain-herdr-capability-grid.md).

```text
Adapt
BusyBrain's structured reviewer and small Playwright scenario format.
```

[ecosystem] Running the proposed Playwright scenarios requires a compatible Playwright package, browser executable revision, and host runtime dependencies. The roadmap records a browser capability in I.1 and schedules browser tests in I.7, but none of its tasks acquires, pins, or live-probes that runtime; the grid also explicitly reports no app lifecycle contract. A machine can therefore match the declared capability while being unable to execute the required final browser gate.

Fix: Add a prerequisite task that pins and installs the supported browser runner and browser revision, verifies host dependencies, and proves a real application startup, scenario run, and cleanup before advertising browser capability.

Counterargument: Existing projects may supply working suites and browsers. The promised out-of-box workflow still needs a contract for discovering, provisioning, executing, and failing those gates.

<a id="finding-14"></a>

### 14. Pane workers have no specified per-call quota enforcement boundary

HIGH · score 340 · 1 reviewer lenses · 1 model. Confidences: 85. Root cause: `quota_call_boundary`. ID: `rt-cli-bypasses-call-reservation`.

Anchor: [merge-busybrain-herdr-todo.md / Piece H / H.3](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **H.3 Reserve estimated use before every model call.** Admission and reservation happen
      in one SQLite transaction. Completion settles actual use. An unknown billed timeout retains
      its reservation until reconciliation.
```

The plan runs workers in agent CLI panes with any of 23 kinds, while only the reviewer is a daemon-owned API request. Assuming a worker CLI initiates its own model requests, no plan section or TODO item supplies interception or credential mediation that forces those calls through H.3; a worker or its child can continue spending after the pool pauses without acquiring reservations. Supervisor-visible actor records and a packet prohibition on unmanaged children do not establish that admission boundary.

Fix: Specify and test an enforceable provider-call adapter or gateway for supported worker kinds, and restrict unattended quota enforcement claims to workers whose calls pass through it.

Counterargument: Some CLI integrations may expose suitable hooks, or an attempt could reserve a bounded session allowance. Neither mechanism is specified for the currently advertised worker kinds.

<a id="finding-15"></a>

### 15. Machine-loss recovery requires artifacts from the unavailable machine

HIGH · score 336 · 1 reviewer lenses · 1 model. Confidences: 84. Root cause: `offline_checkpoint`. ID: `rel-offline-source-recovery-gap`.

Anchor: [merge-busybrain-herdr-plan.md / §2.9 / attempt relocation](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

```text
A retry may move after the source attempt closes. The source machine preserves a secret-scanned
candidate commit or a content-addressed Git bundle plus hashed non-code artifacts.
```

The relocation producer is the source machine after attempt close, but §2.9 also permits replacement after machine loss and lease expiry. If that machine disappears before preservation, the destination has no defined accessible checkpoint; no task defines fallback to the last durable base or waiting for source recovery, so the promised disconnect recovery is incomplete.

Fix: Specify the checkpoint durability boundary and the machine-loss branch that resumes from the last available verified commit or enters a durable wait when required artifacts are unavailable.

Counterargument: Waiting for the source to return is a valid choice. That choice and the last available checkpoint must be explicit so recovery cannot falsely claim transfer of unavailable work.

<a id="finding-16"></a>

### 16. The new external review request has no pre-send secret gate

HIGH · score 336 · 1 reviewer lenses · 1 model. Confidences: 84. Root cause: `review_egress`. ID: `sec-review-outbound-secret-gate`.

Anchor: [merge-busybrain-herdr-todo.md / Piece C / C.4](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
The
      reviewer receives the goal, the diff against `origin/<base_branch>`, and the verifier
      output. A test asserts the worker transcript is not in the request.
```

Assuming a candidate or verifier output contains a secret, C.4 sends it to the external Messages API with no named pre-send scan or redaction gate. The grid identifies secret-screening gaps in independent review, but the supplied plan only explicitly secret-scans relocation artifacts and the TODO tests transcript exclusion rather than the actual outbound payload; those controls do not protect this request.

Fix: Add supervisor-owned screening and redaction of the complete outbound review payload before the API call, with a blocked transition on unresolved secret hits and tests for secrets in diffs and verifier output.

Counterargument: Existing secret scans and log redaction may protect other paths. The new outbound request needs a pre-send gate on its complete payload; excluding the transcript alone does not cover secrets in diffs or test output.

<a id="finding-17"></a>

### 17. Model-assigned identifiers and prose make repeated-failure detection unstable

MEDIUM · score 192 · 2 reviewer lenses · 1 model. Confidences: 96, 96. Root cause: `failure_identity`. ID: `cq-unstable-finding-fingerprints`.

Anchor: [merge-busybrain-herdr-plan.md §2.5](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

```text
applied to the `verification.excerpt` in `state.json` plus the sorted `finding_id` and `issue`
pairs from §2.2.
```

Section 2.2 obtains fresh findings from an independent model request on each attempt but defines no stable assignment of finding IDs or issue wording. The same defect can therefore receive a different ID or paraphrase and evade the two-identical-attempt stop; the strict-subset progress rule is likewise unreliable if it compares these model-created pairs. Sorting and whitespace normalization cannot establish semantic identity.

Fix: Have the supervisor fingerprint canonical objective operands and observed failure results, excluding model-assigned IDs and free-form issue prose, and compare those stable keys for equality and subset progress.

Counterargument: Normalization handles whitespace and some noise. It does not make independently generated IDs or paraphrases stable across reviews.

Contributing runs:

- code_quality: `cq-unstable-finding-fingerprints`, medium, confidence 96, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).
- reliability: `rel-unstable-failure-fingerprint`, medium, confidence 96, [source](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

<a id="finding-18"></a>

### 18. Actor drill-down consumes registered children without a registration lifecycle

MEDIUM · score 190 · 1 reviewer lenses · 1 model. Confidences: 95. Root cause: `actor_lifecycle`. ID: `arch-registered-actor-lifecycle-missing`.

Anchor: [merge-busybrain-herdr-todo.md / J.5](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **J.5 Record the complete actor hierarchy.** Link every worker, registered child, reviewer,
      and verifier job to an attempt. Show its machine, model, lease, deadline, last observation,
      last material progress, next action, budget, and evidence.
```

Plan §2.10 assigns registered children their own leases and budgets, but G.1 persists unit-level scheduling fields and G.6 only creates separate units or absorbs unmanaged processes into a parent attempt. No task defines actor registration, dispatch, close, or the parent/attempt relationships that J.5 and actor-attributed usage require; implementing them as status-only rows would not enforce the promised ownership and budgets.

Fix: Define actor identity, registration and close transitions, parent/attempt ownership, and lease/budget allocation in the execution layer before J.5 and J.7 consume them.

Counterargument: Every child could be represented as a unit. The plan must state that mapping or define actor-level registration; display rows alone do not enforce leases or budgets.

<a id="finding-19"></a>

### 19. Versioned API price schedule has no acquisition or validation task

MEDIUM · score 190 · 1 reviewer lenses · 1 model. Confidences: 95. Root cause: `cost_evidence`. ID: `prov-price-schedule-producer`.

Anchor: [merge-busybrain-herdr-todo.md / Piece J / J.8](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
Calculate API estimates from a versioned price schedule
      and reconcile them when provider billing exists.
```

J.8 consumes a versioned price schedule and plan §2.10 requires it, but no task names its source, acquires an initial schedule, pins its effective version, or validates coverage for configured models and token categories. H.2 produces quota observations rather than prices, and C.8 only selects the reviewer model, leaving the estimate feature without its required external data producer.

Fix: Add a price-data task that obtains and verifies rates for the supported model and billing categories, records source and effective version, and makes estimates unavailable when a matching verified rate is absent.

Counterargument: Estimates can be approximate and prices can be manually supplied. Their categories, source, version, and unavailable-data behavior still need definition to avoid misleading totals.

<a id="finding-20"></a>

### 20. The cost record does not define how cached tokens overlap input tokens

MEDIUM · score 174 · 1 reviewer lenses · 1 model. Confidences: 87. Root cause: `cost_evidence`. ID: `cm-cached-token-cost-semantics-undefined`.

Anchor: [merge-busybrain-herdr-plan.md §2.10 Status is a projection of supervisor state](../../../../herdr/orchestrator/merge-busybrain-herdr-plan.md).

```text
output tokens, cached tokens, reservation, start and end times, and billing status. API cost uses
a versioned price schedule and remains `estimated` until provider billing reconciles it.
```

The adjacent usage schema names input, output, and cached tokens without specifying whether input includes cached tokens or distinguishing differently billed cache categories. J.7 and J.8 repeat those fields without normalization or a pricing formula, so adapters can produce records that appear compatible but double-count cache hits or apply the wrong rate; later billing reconciliation cannot repair estimates when per-call billing is absent.

Fix: Define canonical disjoint billing token categories and adapter mappings, including cache-read and cache-write semantics where applicable, with a fixed price-version reference and tested cost formula.

Counterargument: Estimates can be approximate and prices can be manually supplied. Their categories, source, version, and unavailable-data behavior still need definition to avoid misleading totals.

<a id="finding-21"></a>

### 21. Every review sends an unbounded accumulated branch diff in one request

MEDIUM · score 174 · 1 reviewer lenses · 1 model. Confidences: 87. Root cause: `review_input_bounds`. ID: `cq-unbounded-accumulated-review-diff`.

Anchor: [merge-busybrain-herdr-todo.md C.4](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
- [ ] **C.4 The API call.** One Messages request with the schema as the tool input schema. The
      reviewer receives the goal, the diff against `origin/<base_branch>`, and the verifier
      output.
```

Section 2.9 starts units from an integration commit containing their dependencies, so diffing each unit against origin's base repeatedly includes accumulated dependency changes. Across a growing initiative this can produce quadratic total review input, and a sufficiently large diff or verifier output will exceed the single request's input capacity. Neither the plan nor C.4 defines size bounds, a unit-base diff, or a complete-coverage strategy for oversized candidates.

Fix: Review each immutable candidate against its recorded unit base, bound verifier excerpts, and define a bounded partitioning or explicit oversized-review transition that preserves full required coverage.

Counterargument: Small unit diffs may fit a single request. Large initiatives are explicitly in scope, and accumulated dependency diffs need a bounded complete-coverage policy.

<a id="finding-22"></a>

### 22. New recovery invariants have no migration for existing SQLite rows

MEDIUM · score 170 · 1 reviewer lenses · 1 model. Confidences: 85. Root cause: `state_upgrade`. ID: `rel-existing-state-migration-omitted`.

Anchor: [merge-busybrain-herdr-todo.md / Piece G / G.1](../../../../herdr/orchestrator/merge-busybrain-herdr-todo.md).

```text
**G.1 Extend `state.db` with unit phases and durable scheduling fields.** Store the owner,
      dispatch ID, lease expiry, fencing epoch, last observation, last material progress,
      `next_action_at`, attempt deadline, waiting reason, and candidate commit.
```

The grid confirms SQLite already stores units and attempts, but G.1 adds mandatory recovery state without a schema-version migration, backfill, or explicit fresh-database boundary. Existing nonterminal rows can consequently have neither a recoverable owner nor a due next_action_at, violating §2.7's invariant and escaping the startup due-row scan.

Fix: Add a transactional versioned migration that reconciles existing active rows against real processes and assigns every nonterminal row an owner or due action, with an upgrade fixture test.

Counterargument: The first release may use a fresh database. An explicit fresh-state boundary would resolve this medium concern; otherwise existing nonterminal rows need migration.

## Advisory and human-verification lists

No partial-source advisory findings or speculative findings were submitted. The provisioning runtime finding uses an explicitly marked ecosystem assumption and capped confidence. All severity labels concern the plan as written. In particular, the reviewer command finding does not establish an OS privilege escalation; its reachable impact depends on verifier permissions and the threat model.
