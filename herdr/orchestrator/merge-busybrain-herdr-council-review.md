# Council review of the BusyBrain–Herdr merge

Reviewed 2026-09-13. The merge needs design revisions before implementation of the reviewer and shared lifecycle changes. No critical finding was established.

The council produced 33 raw findings, consolidated into 25 anchored findings: 11 high, 13 medium, and 1 low. Related findings remain grouped below; multiple symptoms of a root cause are not additional independent votes.

## Scope and method

Reviewed the complete merge plan, execution roadmap, and supplied memory file. Referenced master-plan sections, the master roadmap, task-packet schema reference, and the named normalization implementation were checked to resolve explicit links. This is a document review, not a fresh audit of BusyBrain history, live services, or production code.

Source version: `bdb90022067b`. Fingerprint: `bdb90022067b · --- SOURCE: /Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md --- # Merge … the missing `qwen3-coder:30b` model. Related: [[herdr-node-must-be-launchd-owned]].`.

Parallel-subagent tier, with capacity-limited batches. Architecture and code quality reused one reviewer thread; security and provisioning reused another; reliability and devil’s advocate reused another. Cost metering used a separate thread. The root reviewer performed red team. All used the same inherited model. There is one model, five reviewer threads, and eight lens passes; reused threads were not cold readers on their second pass. No cross-provider diversity is claimed.

All eight lenses returned full-source coverage and matching fingerprints. Provisioning returned no findings. No partial, missing, speculative, or advisory runs survived. The optional isolate-and-edit loop was not run because this task reviews unchanged documents.

The contract’s normative anchor-based deduplication takes precedence over the skill summary’s ID-based shortcut. Only the same defect with overlapping verbatim anchors was merged. Severity is the maximum reported; individual confidences are preserved in the evidence bundle. Score = severity weight × mean confidence × distinct models, with weights 8/4/2/1 and distinct models = 1. Counts of lenses and reviewer threads are disclosed separately. Scores rank this review; they are not probabilities or evidence of cross-model agreement.

The supplied memory agrees with the interface decision. This review does not reopen Slack or Cursor bridge adoption. Its historical measurements were not independently remeasured.

## Ranked findings

| Rank | Severity | Score | Lens passes / threads | Finding |
| --- | --- | ---: | ---: | --- |
| 1 | high | 398.7 | 3 / 3 | [Reviewer sees committed HEAD before the supervisor commits the work](#finding-1) |
| 2 | high | 394.0 | 2 / 2 | [Closed escalation classes omit ordinary master-plan failures](#finding-2) |
| 3 | high | 394.0 | 2 / 2 | [Status is restricted to incompatible record shapes](#finding-3) |
| 4 | high | 386.0 | 2 / 2 | [Confirmed findings have no defined durable source for the next packet](#finding-4) |
| 5 | high | 380.0 | 1 / 1 | [Reviewer transport and response failures have no lifecycle transition](#finding-5) |
| 6 | high | 376.0 | 1 / 1 | [Exactly one close record is not restart-safe across SQLite and JSONL](#finding-6) |
| 7 | high | 370.0 | 2 / 2 | [Confirmation errors can demote a blocking finding](#finding-7) |
| 8 | high | 350.0 | 2 / 2 | [The full review request has no size admission rule](#finding-8) |
| 9 | high | 336.0 | 1 / 1 | [Reviewer API sends content before the secret gate inspects it](#finding-9) |
| 10 | high | 328.0 | 1 / 1 | [API failures have no budget transition](#finding-10) |
| 11 | high | 328.0 | 1 / 1 | [Reviewer-generated commands can change the candidate after its tests pass](#finding-11) |
| 12 | medium | 200.0 | 1 / 1 | [Run record cannot produce seconds to first verifier run](#finding-12) |
| 13 | medium | 198.0 | 1 / 1 | [Scope changes land enforcement without the required master amendment](#finding-13) |
| 14 | medium | 198.0 | 1 / 1 | [Required runtime retirement has no scheduled owner or gate](#finding-14) |
| 15 | medium | 198.0 | 1 / 1 | [Run record cannot supply the promised time-to-first-verifier metric](#finding-15) |
| 16 | medium | 196.0 | 1 / 1 | [Field-name equality cannot keep the duplicated schemas consistent](#finding-16) |
| 17 | medium | 196.0 | 1 / 1 | [Amendment precedence leaves new enforcement rules subordinate to old rules](#finding-17) |
| 18 | medium | 194.0 | 1 / 1 | [Objective finding confirmation has no defined success polarity](#finding-18) |
| 19 | medium | 190.0 | 1 / 1 | [Scope is enforced before its list and glob grammar is specified](#finding-19) |
| 20 | medium | 186.0 | 1 / 1 | [Run record final values omit skipped and aborted unit closure](#finding-20) |
| 21 | medium | 182.0 | 1 / 1 | [Run records cannot attribute reviewer API usage](#finding-21) |
| 22 | medium | 180.0 | 1 / 1 | [Prompt timestamp stripping can erase meaningful verifier evidence](#finding-22) |
| 23 | medium | 179.0 | 2 / 2 | [Stall fingerprint depends on reviewer-local labels and free prose](#finding-23) |
| 24 | medium | 170.0 | 1 / 1 | [The different-family default cannot cover all supported worker kinds](#finding-24) |
| 25 | low | 100.0 | 1 / 1 | [The documented module base does not match the repository](#finding-25) |

## Findings grouped by root cause

### Candidate coverage and integrity

<a id="finding-1"></a>
#### 1. Reviewer sees committed HEAD before the supervisor commits the work

`arch-review-diff-misses-work` · high · score 398.7 · mean confidence 99.7 · 3 lens pass(es), 3 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:117](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:117), §2.2.

```text
The reviewer sees the packet's goal, `git diff origin/<base_branch>..HEAD`, and the
verifier's output.
```

The review runs before the land step, while master §6 stages and commits in the land step; ordinary worker edits may therefore be unstaged, staged, or untracked and absent from HEAD. A first successful attempt can send an empty diff to the reviewer and publish the unseen debug print in the specified live test.

Fix: Create a staged snapshot using the land staging policy before review and review that exact snapshot, including new files, before committing it.

Counterargument checked: A worker might commit before declaring completion. The master explicitly permits unstaged and untracked changes, so this cannot be a review precondition.

Contributing findings: `arch-review-diff-misses-work` (100), `sec-review-misses-uncommitted-work` (99), `da-review-empty-diff` (100).

<a id="finding-11"></a>
#### 11. Reviewer-generated commands can change the candidate after its tests pass

`rt-generated-check-can-mutate-tree` · high · score 328.0 · mean confidence 82.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:106](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:106), §2.2.

```text
The supervisor checks `test`,
  `path_exists`, `path_changed`, and `absence` findings with a command it runs itself
```

The reviewer supplies verify_cmd and the supervisor runs it after the main verifier passes. A mistaken test or command can modify source or index; no immutable snapshot or post-check identity validation ties the review and prior green result to the content eventually committed. This is an accidental correctness risk within the same-user TODO lane, not a claimed privilege boundary.

Fix: Check a fixed candidate snapshot, constrain objective checks where possible, and invalidate the pass and rerun gates whenever the candidate changes.

Counterargument checked: Most grep and path checks are read-only, and the TODO worker is trusted. The admitted test and arbitrary command kinds can still mutate files accidentally after the main verifier ran.

Contributing findings: `rt-generated-check-can-mutate-tree` (82).

### Escalation and operator interface

<a id="finding-2"></a>
#### 2. Closed escalation classes omit ordinary master-plan failures

`arch-closed-escalations-incomplete` · high · score 394.0 · mean confidence 98.5 · 2 lens pass(es), 2 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:207](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:207), §2.4.

```text
The class set is closed and small: `verifier_failed`, `review_blocked`, `blocker_reported`,
`config_hash_mismatch`, `unseen_path`, `secret_hit`, `stall`, `exhausted`, `unknown_prompt`.
```

The master §5 default rule explicitly includes missing MC-EXIT, push or PR failures, offline machines, verification unconfigurable, and other kinds absent from this closed set. No mapping preserves their distinct ack handling and timeout exemptions; D.4 requires every escalation to render this record, and F.1 also rejects terminal values outside this set.

Fix: Define a total mapping of existing escalation kinds to the new record while retaining ack and timeout policy, or preserve the existing open kind taxonomy.

Counterargument checked: Class could be a presentation category separate from the master kind. That is a valid fix, but the new record omits kind and specifies no total mapping.

Contributing findings: `arch-closed-escalations-incomplete` (99), `rel-closed-classes` (98).

<a id="finding-3"></a>
#### 3. Status is restricted to incompatible record shapes

`arch-status-contract-conflict` · high · score 394.0 · mean confidence 98.5 · 2 lens pass(es), 2 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-todo.md:61](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-todo.md:61), D.4.

```text
**D.4 `herdr-master status` and every escalation render this record**, and nothing else.
```

The escalation shape cannot represent a healthy running or completed unit because class is limited to failures, while F.3 and merge §2.6 require status --unit to render the differently shaped run record. Master §2.5 and §6 also require status to report quarantined counts and pane queue depths, which the new shape omits.

Fix: Define separate status and escalation response variants, including a --unit run-record variant, and explicitly amend existing status requirements.

Counterargument checked: D.4 might mean only the escalation portion of status. Its words and nothing else prohibit that reading, and its fixed shape lacks normal fleet state.

Contributing findings: `arch-status-contract-conflict` (100), `da-status-only-failures` (97).

### Review persistence and recovery

<a id="finding-4"></a>
#### 4. Confirmed findings have no defined durable source for the next packet

`arch-review-state-link` · high · score 386.0 · mean confidence 96.5 · 2 lens pass(es), 2 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:145](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:145), §2.2.

```text
the finding goes into the next packet's `last_failure` and the retry
budget decrements.
```

Section 2.1 defines last_failure exclusively as verification from state.json and verbatim verifier output, which is green when review blocks. Master §10.2 and its referenced validate_state.py define a closed verification record containing only command, exit_code, and excerpt; neither the plan nor C.2/C.6 adds a durable review-results field or amends packet input, so reviewer findings cannot round-trip through the prescribed close and restart path without changing those contracts.

Fix: Define persisted confirmed-review evidence, amend the state validator and packet last_failure source, and schedule a close/restart/retry test.

Counterargument checked: A developer could put reviewer prose into verification.excerpt. That would obscure the successful verifier result and violate the specified verbatim-verifier source unless the state contract is amended.

Contributing findings: `arch-review-state-link` (97), `rel-review-retry-state` (96).

<a id="finding-5"></a>
#### 5. Reviewer transport and response failures have no lifecycle transition

`rel-review-failure-transition` · high · score 380.0 · mean confidence 95.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:114](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:114), §2.2.

```text
The reviewer is an Anthropic Messages API call made by
the daemon, not an agent in a pane.
```

The new mandatory pre-land step defines approved and finding outcomes but no deadline, bounded retry, or escalation for timeout, authentication/rate-limit errors, missing tool calls, or rejected manifests. The master pane exit and stall protocols do not govern this daemon API call, so an ordinary provider failure can strand a unit or crash its poll task with no specified recovery.

Fix: Define a persisted review-pending state, API deadline and bounded retry policy, and explicit failure escalation that prevents landing.

Counterargument checked: A client may have request timeouts. A timeout alone does not define unit state, restart behavior, or whether landing stays blocked.

Contributing findings: `rel-review-failure-transition` (95).

<a id="finding-10"></a>
#### 10. API failures have no budget transition

`cm-review-failure-accounting` · high · score 328.0 · mean confidence 82.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:144](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:144), Merge plan §2.2, Where it sits in the lifecycle.

```text
A blocking objective finding that the supervisor confirms ends the attempt exactly as
a verifier failure does: the finding goes into the next packet's `last_failure` and the retry
budget decrements. One budget, one close path (master plan §10.2).
```

The only reviewer-specific budget transition requires a confirmed finding, while C.4 specifies one Messages request. Neither section specifies what happens when that request times out, fails, or returns an unusable tool result: implementation must choose whether to resend, close the attempt, or escalate, and whether an ambiguous possibly billed request consumes an allowance. The promised single-budget lifecycle therefore does not cover reviewer failures.

Fix: Define a persisted review-request outcome and bounded retry/close policy that accounts for ambiguous and failed requests without bypassing the existing attempt budget.

Counterargument checked: C.4 says one request, which limits ordinary calls. It does not decide what a daemon restart or ambiguous timeout does to that allowance. This is a policy gap, not evidence of unlimited actual billing.

Contributing findings: `cm-review-failure-accounting` (82).

### Run-record lifecycle and telemetry

<a id="finding-6"></a>
#### 6. Exactly one close record is not restart-safe across SQLite and JSONL

`rel-runrecord-dual-write` · high · score 376.0 · mean confidence 94.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:245](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:245), §2.6.

```text
The daemon writes one close record per unit, from `state.db` and
`actions.jsonl`, with no model in the loop.
```

Unit close is persisted in SQLite while the record is appended separately to units.jsonl; F.2 specifies no durable publication marker or reconciliation. A crash between the state transition and append loses the record, while a crash after append but before recording publication duplicates it on replay, violating the one-record invariant and distorting baseline metrics.

Fix: Store the canonical close record transactionally with unit closure keyed by unit_id and export or reconcile JSONL idempotently.

Counterargument checked: A single daemon serializes writes. It does not make a SQLite transaction and JSONL append atomic across a crash.

Contributing findings: `rel-runrecord-dual-write` (94).

<a id="finding-12"></a>
#### 12. Run record cannot produce seconds to first verifier run

`arch-timing-source-missing` · medium · score 200.0 · mean confidence 100.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:257](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:257), §2.6.

```text
| `attempts[]`     | Per attempt: `n`, `kind`, `started`, `ended`, `verifier_exit`, `verifier_excerpt`, `findings_confirmed`, `injections`, `nudges`, `close_reason` |
```

The rationale below this closed field set says the record is the table for seconds to first verifier run, but it contains only attempt start/end timestamps and no verifier-start timestamp. F.4 schedules only attempts-per-unit and nudges metrics, leaving the named timing metric without a producer.

Fix: Record verifier_started_at per attempt and add its latency computation to F.4.

Contributing findings: `arch-timing-source-missing` (100).

<a id="finding-15"></a>
#### 15. Run record cannot supply the promised time-to-first-verifier metric

`rel-first-verifier-timestamp` · medium · score 198.0 · mean confidence 99.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:263](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:263), §2.6.

```text
The numbers to ratify (attempts per unit,
nudges before escalation, seconds to first verifier run) are per unit, and this record is the
table they are read from.
```

The fixed fields include unit and attempt start/end times but no verifier start time; started is the attempt start, not the first verification. Consequently seconds to first verifier run cannot be derived from the stated table, and F.4 only produces the other two metrics.

Fix: Capture verifier_started_at from the supervisor and add the corresponding duration calculation to F.4.

Contributing findings: `rel-first-verifier-timestamp` (99).

<a id="finding-20"></a>
#### 20. Run record final values omit skipped and aborted unit closure

`rel-terminal-record-outcomes` · medium · score 186.0 · mean confidence 93.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:256](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:256), §2.6.

```text
| `final`          | `done`, or one class from the §2.4 set                                 |
```

Master §5 allows --skip and §10.3 allows abort, both closing or archiving incomplete work; F.1 rejects any final outside done and the nine failure classes. These operator closure outcomes have no encoding, and replacing them with the prior escalation class obscures whether a unit is still suspended or was actually closed.

Fix: Separate terminal disposition from failure class and explicitly encode skipped, aborted, and completed closure outcomes.

Contributing findings: `rel-terminal-record-outcomes` (93).

<a id="finding-21"></a>
#### 21. Run records cannot attribute reviewer API usage

`cm-review-usage-not-recorded` · medium · score 182.0 · mean confidence 91.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:257](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:257), Merge plan §2.6, run record fields.

```text
| `attempts[]`     | Per attempt: `n`, `kind`, `started`, `ended`, `verifier_exit`, `verifier_excerpt`, `findings_confirmed`, `injections`, `nudges`, `close_reason` |
```

The fixed record contains worker kind and findings but no reviewer model, request identifiers, token usage, or review failure/request counts; actions.jsonl is explicitly one line per injected action. The new daemon API spend cannot be attributed to units or reconciled after retries from either documented record, even though the API call is independent of the worker pane.

Fix: Persist reviewer request outcomes and returned usage with unit/attempt IDs and model identity, including an explicit unknown-usage state for ambiguous failures.

Contributing findings: `cm-review-usage-not-recorded` (91).

### Objective confirmation contract

<a id="finding-7"></a>
#### 7. Confirmation errors can demote a blocking finding

`rt-review-check-errors-pass` · high · score 370.0 · mean confidence 92.5 · 2 lens pass(es), 2 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:146](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:146), §2.2.

```text
A blocking finding the
supervisor cannot confirm is logged and demoted to `warning`
```

Cannot confirm does not distinguish a disproved defect from a timeout, missing tool, transport error, or invalid command. Treating those outcomes as warning lets a normal broken verification environment turn a blocking review into permission to land; master §2.3 instead escalates missing or nonzero command results.

Fix: Specify confirmed, disproved, and indeterminate outcomes per verification kind; only disproved findings become warnings, and indeterminate checks suspend.

Counterargument checked: Master §2.3 already escalates transport failures. That helps, but the merge must reconcile expected nonzero exits and broad cannot-confirm demotion rather than leave implementers two competing rules.

Contributing findings: `rt-review-check-errors-pass` (94), `sec-review-demotes-check-errors` (91).

<a id="finding-16"></a>
#### 16. Field-name equality cannot keep the duplicated schemas consistent

`cq-schema-sync-too-weak` · medium · score 196.0 · mean confidence 98.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:139](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:139), §2.2.

```text
a test asserts
that the dataclass fields and the JSON schema properties are the same set
```

The required synchronization test ignores types, enum values, required/optional fields, and verification-kind-dependent requirements even though §2.2 relies on each of those constraints. Both representations can retain exactly the same field names while disagreeing on valid reviewer outputs, leaving the API contract and daemon parser to drift independently.

Fix: Use one canonical constraint definition to build both representations, or exercise shared positive and negative contract cases through the schema and parser.

Contributing findings: `cq-schema-sync-too-weak` (98).

<a id="finding-18"></a>
#### 18. Objective finding confirmation has no defined success polarity

`da-absence-polarity` · medium · score 194.0 · mean confidence 97.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:131](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:131), §2.2.

```text
"verify_cmd": "grep -n 'print(' slugify.py",
  "expect_exit": 1
```

The example expects exit 1 when the forbidden print is absent, while §5 requires confirming the blocking finding when the print is present and grep exits 0. No rule says whether expect_exit describes the healthy condition or the condition confirming the defect, so a natural actual-equals-expected implementation reverses the live acceptance test; the path kinds likewise provide no expected presence/change value.

Fix: Define expect_exit explicitly as either healthy-state expectation or defect confirmation, specify the comparison, and define equivalent polarity for both path kinds.

Contributing findings: `da-absence-polarity` (97).

### Reviewer request capacity

<a id="finding-8"></a>
#### 8. The full review request has no size admission rule

`cm-review-input-unbounded` · high · score 350.0 · mean confidence 87.5 · 2 lens pass(es), 2 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:117](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:117), Merge plan §2.2 / TODO C.4.

```text
cannot. The reviewer sees the packet's goal, `git diff origin/<base_branch>..HEAD`, and the
verifier's output. It never sees the worker's transcript.
```

Anchor: [merge-busybrain-herdr-plan.md:117](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:117), §2.2.

```text
The reviewer sees the packet's goal, `git diff origin/<base_branch>..HEAD`, and the
verifier's output.
```

The daemon sends the complete diff and verifier output with no byte/token bound, maximum response size, or oversized-input disposition. A normal task with generated changes or verbose verifier output can make this single request much larger than expected or exceed the selected model context; the one-request rule bounds count, not payload or spend.

Fix: Specify request and response limits and an oversized-input escalation path before issuing the request, preserving complete-review semantics rather than silently truncating the diff.

Counterargument checked: The master mentions a 400-line diff threshold for prompt approval. It is not a documented cap on this API payload or its verifier output; one request can still exceed capacity.

Contributing findings: `cm-review-input-unbounded` (86), `cq-unbounded-review-input` (89).

### Outbound review data

<a id="finding-9"></a>
#### 9. Reviewer API sends content before the secret gate inspects it

`sec-review-egress-precedes-secret-scan` · high · score 336.0 · mean confidence 84.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:143](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:143), §2.2 Where it sits in the lifecycle.

```text
After the master plan §6 verifier passes and before the
land step.
```

The new Anthropic request sends the raw diff and verifier output before master §6 land-step secret scanning. If a worker accidentally commits a credential in a source file or verification emits a credential, the external request exposes it before a later secret_hit escalation can help; the actions.jsonl redaction specified in master §2.3 applies to logging, not this request. This is accidental disclosure in the stated same-user TODO lane, not a claimed hostile-agent boundary.

Fix: Screen the exact outbound diff and verifier output before the Messages request, redact log-only secrets, and block review with secret_hit when safe review input cannot be produced.

Counterargument checked: Attempt-close scanning can protect prior supervisor commits. It does not cover agent commits in a successful attempt or secrets in verifier output sent before landing.

Contributing findings: `sec-review-egress-precedes-secret-scan` (84).

### Amendments and queue contract

<a id="finding-13"></a>
#### 13. Scope changes land enforcement without the required master amendment

`arch-scope-amendment-missing` · medium · score 198.0 · mean confidence 99.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:177](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:177), §2.3.

```text
**Amends master plan §2.5.** The recognizer gains the three keys above. The queue line grammar
is otherwise unchanged.
```

Section 2.3 describes replacing the master §6 unseen-path rule with task-declared scope, but only explicitly amends §2.5. Under §0 the master wins unless the changed section is expressly amended, so a newly declared task file still triggers master §6 unseen-path escalation despite being within scope; A.5 does not resolve whether both checks apply.

Fix: Explicitly amend master §6 to say whether scope replaces or supplements the historical-path gate, including the absent-scope behavior.

Contributing findings: `arch-scope-amendment-missing` (99).

<a id="finding-17"></a>
#### 17. Amendment precedence leaves new enforcement rules subordinate to old rules

`da-unapplied-amendments` · medium · score 196.0 · mean confidence 98.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:7](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:7), §0.

```text
the master plan wins unless a section here says `amends §N` and states
the new rule.
```

Only §2.3 explicitly amends master §2.5; the new review completion gate changes master §6 and §10.2 without amending either, and the same section changes the scope gate while amending only queue grammar. D.4 claims master §7.4 is amended, but §7.4 is a roadmap item, not a subsection of the master plan; literal application of the stated precedence leaves conflicting completion, scope, and status behavior unresolved.

Fix: Add explicit amendments to the actual master sections for each changed invariant and distinguish plan section references from roadmap item references.

Contributing findings: `da-unapplied-amendments` (98).

<a id="finding-19"></a>
#### 19. Scope is enforced before its list and glob grammar is specified

`cq-scope-grammar-undefined` · medium · score 190.0 · mean confidence 95.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:170](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:170), §2.3.

```text
| `scope:`               | A list of repo-relative paths or globs
```

The plan gives no list delimiter, quoting rule for filenames with spaces or commas, or definition of whether globs cross directories and whether directory entries include descendants. Since A.5 uses the parse result as a land gate, different straightforward implementations authorize or reject different staged files for the same queue line.

Fix: Specify one list syntax and path-matching convention, and add parser-to-land tests for spaces, directory patterns, and recursive globs.

Contributing findings: `cq-scope-grammar-undefined` (95).

### Delivery prerequisites

<a id="finding-14"></a>
#### 14. Required runtime retirement has no scheduled owner or gate

`da-unscheduled-baseline-prerequisite` · medium · score 198.0 · mean confidence 99.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-todo.md:120](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-todo.md:120), Not scheduled.

```text
- The BusyBrain watchdog and bridge on this host (merge plan §6.3). Unload
  `com.openbrain.slack-cursor-bridge-watchdog` and `com.openbrain.slack-cursor-bridge`. Slack is not the interface plane (merge plan §3), so
  there is nothing to keep alive. Blocks Phase 5's timing numbers.
```

The plan says the load must be removed before timing is ratified, and F.4 requires producing those thresholds, but retirement is explicitly outside the schedule with no producer or verification task. The retirement decision is consistent with the memory; the execution gap leaves the mandatory baseline prerequisite indefinitely unresolved.

Fix: Add a named pre-Phase-5 task to unload and verify both jobs are stopped, or an explicit dependency on a separately owned retirement task.

Contributing findings: `da-unscheduled-baseline-prerequisite` (99).

### Stall fingerprint semantics

<a id="finding-22"></a>
#### 22. Prompt timestamp stripping can erase meaningful verifier evidence

`cq-normalize-evidence-collision` · medium · score 180.0 · mean confidence 90.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:226](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:226), §2.5.

```text
The normalize-and-hash from `AntiLoopTracker` moves into `herdr_master/` and is
applied to the `verification.excerpt` in `state.json` plus the sorted `finding_id` and `issue`
pairs from §2.2.
```

The referenced AntiLoopTracker._normalize_and_hash removes every digit pattern matching a time and collapses all whitespace. Applied to verifier evidence, distinct actual values such as 12:30 and 12:45, or whitespace-sensitive expected/actual text, become identical and can trigger stall while the failure is changing; the reuse changes the meaning of the normalization from terminal noise to test evidence.

Fix: Normalize only identified volatile metadata and retain semantic verifier values and structured finding fields when fingerprinting attempts.

Contributing findings: `cq-normalize-evidence-collision` (90).

<a id="finding-23"></a>
#### 23. Stall fingerprint depends on reviewer-local labels and free prose

`arch-finding-id-instability` · medium · score 179.0 · mean confidence 89.5 · 2 lens pass(es), 2 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:227](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:227), §2.5.

```text
applied to the `verification.excerpt` in `state.json` plus the sorted `finding_id` and `issue`
pairs from §2.2.
```

The finding schema gives the example ID R1 but no stable cross-attempt identity or canonical issue text. Assuming a fresh API review assigns IDs or words findings differently, the same unresolved defect hashes differently and subset comparisons fail even with unchanged verifier output, defeating the specified early-stall behavior.

Fix: Assign supervisor-owned finding identities from stable verification targets and normalized checks, and compare those identities across attempts.

Contributing findings: `arch-finding-id-instability` (88), `rel-stall-identity` (91).

### Reviewer selection

<a id="finding-24"></a>
#### 24. The different-family default cannot cover all supported worker kinds

`da-reviewer-family-default` · medium · score 170.0 · mean confidence 85.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:118](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:118), §2.2.

```text
The model is configured per profile in
the supervisor-owned `MACHINE.md` and defaults to a different model family from the worker's
`--kind`.
```

The only reviewer backend specified is Anthropic Messages, while the referenced master config explicitly includes a claude worker and §3 advertises any of 23 CLI kinds. Under the usual interpretation that Claude variants are one family, this backend cannot satisfy the default for claude workers; for multi-model CLIs the kind alone also does not identify the underlying family, and C.8 adds no model-family mapping.

Fix: Define family from the actual worker model and either provide a second reviewer backend or document an explicit same-family exception with its selection rule.

Counterargument checked: Family could mean distinct Claude model variants, and profiles might use a fixed worker. Neither interpretation is defined; the strongest absolute backend-incompatibility claim is conditional and is not treated as established.

Contributing findings: `da-reviewer-family-default` (85).

### Document paths

<a id="finding-25"></a>
#### 25. The documented module base does not match the repository

`cq-module-path-base` · low · score 100.0 · mean confidence 100.0 · 1 lens pass(es), 1 reviewer thread(s), one model.

Anchor: [merge-busybrain-herdr-plan.md:20](/Users/joggerjoel/Developer/ai-dotfiles/herdr/orchestrator/merge-busybrain-herdr-plan.md:20), §0.

```text
Paths that
start with `herdr_master/` or `skills/` are relative to this repository.
```

The existing taskqueue.py and config.py cited as edit targets are under herdr/orchestrator/herdr_master/, and herdr_unblocker.py is under herdr/orchestrator/. The stated repository-relative herdr_master/ directory does not exist, so the plan points implementers toward a second package location instead of the modules it intends to extend.

Fix: State that herdr_master/ and prototype paths resolve relative to herdr/orchestrator/, while skills/ remains repository-relative.

Contributing findings: `cq-module-path-base` (100).

## Revision order and acceptance checks

1. Define the candidate snapshot and review ordering. Stage with the existing excludes, screen outbound data, test and review the same candidate, then verify its identity before committing. Demonstrate coverage of unstaged edits, new files, prior attempt commits, and a confirmation command that modifies a file.
2. Define objective-check polarity and outcomes. Test defect present, defect absent, command error, timeout, missing file, and rejected manifest. A failure to execute a check must not become a warning.
3. Extend durable attempt state for review. Preserve successful verifier evidence separately from confirmed review findings. Test close, restart, and redispatch; simulate timeout, rate limiting, and an ambiguous API response without bypassing the gate or silently duplicating requests.
4. Preserve escalation kind and ack semantics, and separate fleet status from escalation and run records. Test a healthy machine, an offline machine, failed push, judgment escalation, skipped work, and aborted work.
5. Make unit closure transactional in SQLite and JSONL an idempotent export. Test crashes on both sides of publication. Add verifier-start timestamps and reviewer usage before collecting the Phase 5 baseline.
6. Specify scope syntax, amend the actual master sections, define stable defect identities without destructive evidence normalization, and schedule watchdog retirement as a verified baseline prerequisite.

## Interpretation and limits

The timing findings use two disjoint anchors, the promised metric and the fixed field table. They are retained as related evidence under one root cause, not collapsed or scored as two-model corroboration. API failure recovery and failure accounting likewise describe different obligations of the same transition.

The family-default finding is conditional on what family means. The established defect is the absence of a worker-model identity and selection rule; the review does not claim a verified external API limitation.

The normalization finding was checked against the named implementation: it strips every time-shaped numeric substring and collapses whitespace. Reuse for verifier evidence can therefore erase actual values. The module-path finding was checked against existing local paths.

No source documents, configuration, running jobs, or implementation files were changed. No tests or live API requests were run; this review’s checks were source completeness, fingerprint equality, verbatim-anchor validation, referenced-contract tracing, and consensus validation.

Machine-readable evidence, including every raw lens response and contributing confidence: [consensus.json](/tmp/herdr-council-20260913/consensus.json). The temporary evidence bundle also contains the exact source snapshot and merge script.
