# Merge BusyBrain into Herdr: Execution Roadmap (TODO)

> **This file tracks work, not design.** `merge-busybrain-herdr-plan.md` (the merge plan) is
> the source of truth for every decision here, and it amends `master-control-herdr-plan.md`
> (the master plan). Items cite the section that governs them and must not restate it. If an
> item and a plan disagree, the plan wins and the item is stale.

**Status.** No merge piece has passed its full acceptance checks. Piece A is unblocked and can
start now. Pieces B and D wait on master plan Phase 3. Piece C waits on Phase 4. Piece E waits on
C. Piece F lands with Phase 3.6 and is read by Phase 5. Piece G joins Phase 3 dispatch to Phase 5
recovery. Piece H depends on G's waiting state. Piece I depends on G's leases, H's quota
admission, and the master plan Phase 6 remote round-trip test. Piece J depends on the state and
run records from F through I. The BusyBrain runtime on this host (merge plan §6.3) remains
unresolved and blocks Phase 5's numbers.

Piece letters below map to merge plan sections: A is §2.3, B is §2.1, C is §2.2, D is §2.4,
E is §2.5, F is §2.6, G is §2.7, H is §2.8, I is §2.9, J is §2.10, K is §2.11, and L is §2.12. The order is
integration order (merge plan §4), not section order. K and L supply initiative and real-app
verification producers before the fleet/viewer release. Phase numbers are integration labels;
the dependency order in merge plan §4 governs execution.

---

## Piece A: Queue fields are parsed or deleted (§2.3) — NEXT

Lands in master plan Phase 3.2.

- [ ] **A.1 Parse `description:`, `scope:`, and `verify:` continuation lines** in
      `herdr_master/taskqueue.py`, beside the existing `allow-test-changes:` parse.
- [ ] **A.2 Quarantine on an unknown key.** A continuation line with a key not in the set marks
      the task `[!]`, matching master plan §2.5 for unknown marks.
- [ ] **A.3 Delete Expected Outcome from `TODO.template.md`** and rewrite the template's two
      examples in the new grammar. `test_taskqueue.py` asserts the template parses.
- [ ] **A.4 `verify:` overrides `test_cmd` only.** `lint_cmd` still runs. Test both the
      override and the lint-still-runs case.
- [ ] **A.5 `scope:` feeds the land step.** A staged path outside the declared scope escalates
      with class `unseen_path` (§2.4). Without a `scope:` line the master plan §6 rule applies
      unchanged.

## Piece B: The packet is a template with required slots (§2.1)

Lands in master plan Phase 3.5. Depends on A.1 for the `goal` slot.

- [ ] **B.1 Move the packet text** from the `PACKET=` heredoc in `attempt_prototype.sh` to
      `skills/amnesiac-workers/references/task-packet.md` as a template with the eight slots
      of the §2.1 table.
- [ ] **B.2 `herdr_master/packet.py` renders it.** A missing required slot raises. `remaining`,
      `last_failure`, and `facts` render their documented defaults.
- [ ] **B.3 The blocker slot is fixed text** with no default and no override. A test asserts
      that every rendered packet contains it.
- [ ] **B.4 A rendered packet never carries the matchable pair.** The test calls the check in
      `herdr_master/herdr.py` on the rendered text for a nonce that appears in the packet.
- [ ] **B.5 Live run on the throwaway repo** (§5): one attempt to `MC-DONE`, one to a valid
      `blockers.json`, driven by `packet.py` with no heredoc in the driver.
- [ ] **B.6 Delete the heredoc from `attempt_prototype.sh`** or delete the script, once
      Phase 3's dispatcher runs the lifecycle.

## Piece D: Escalations are packets (§2.4)

Lands in master plan Phase 7.1 and 7.4. Depends on Phase 3.7's `state.db`.

- [ ] **D.1 `herdr_master/escalation.py`** holds the record shape and the closed class set from
      §2.4. Field limits are enforced in the constructor, not by convention.
- [ ] **D.2 The class-to-action table is a dict** in the same module, with a test that every
      class has exactly one action.
- [ ] **D.3 `raw_available_at` points into `actions.jsonl`** by line, so the record never
      inlines a buffer.
- [ ] **D.4 Every escalation renders this record and nothing else.** Normal status uses Piece J's
      typed projections and includes the escalation record only when one is open.

## Piece C: A reviewer role (§2.2)

Depends on the independent verifier, immutable candidate capture, and H's supported admission.

- [ ] **C.1 Resolve the key source and egress policy.** Verify daemon access under the service
      account. Screen the entire outbound payload; block unresolved secrets and incomplete redaction.
- [ ] **C.2 Add versioned typed review schemas.** Validate required fields, types, enums, closed
      objects, and cross-field constraints. Reject `verify_cmd`, arbitrary executables, escaping
      paths, symlinks, oversized operands, and unknown keys. Tests reference approved check IDs.
- [ ] **C.3 Reject approved verdicts containing blockers.** Missing/malformed output never approves.
- [ ] **C.4 Bind review to immutable identity.** Freeze repository/base/candidate/policy identity,
      review only that unit delta, exclude transcripts, and invalidate verdicts on identity changes.
      Test the same identity at confirmation, restart, and landing.
- [ ] **C.5 Implement typed objective adapters.** Return confirmed, disproved, or inconclusive.
      Only disproved findings may become warnings. Test literal presence/absence and execution errors.
- [ ] **C.6 Close confirmed blockers through the existing attempt budget.** Preserve evidence in
      the next packet without introducing a second worker retry allowance.
- [ ] **C.7 Persist bounded review-operation recovery.** Cover transport/schema/check failures,
      uncertain accepted requests, next actions, and deadline exhaustion. Judgment and exhausted
      review operations escalate `review_blocked`; never fail open or blindly duplicate a call.
- [ ] **C.8 Configure an approved reviewer family.** Parse it in the supervisor-owned profile and
      test unavailable-family behavior without implicit fallback.
- [ ] **C.9 Run live acceptance.** Find and remove a debug print using the typed adapter; escalate
      a judgment finding. Test command rejection, check timeout, secret payload, and candidate swap.
- [ ] **C.10 Bound request size and coverage.** Enforce input/evidence limits and unit-base diffs.
      An oversized request blocks for decomposition or approved complete coverage, never truncation.

## Piece E: Stable failures end repeated attempts early (§2.5)

Depends on C and verifier adapters producing canonical failure identities.

- [ ] **E.1 Add shared canonical failure identity.** Follow §2.5 typed fields and retain the
      interactive buffer tracker until its separate responsibility is absorbed.
- [ ] **E.2 Compare stable failure sets.** Exclude model IDs, prose, and volatile excerpts.
      Test paraphrases, renumbering, reorderings, true subsets, and unavailable identity.
- [ ] **E.3 Escalate two equal nonempty sets under one policy.** Policy changes reset the
      comparison series, never the hard attempt budget. Ratify the threshold from canonical records.

## Piece F: Canonical run records and replayable export (§2.6)

Depends on the SQLite state store and terminal transition.

- [ ] **F.1 Implement the complete versioned §2.6 schema.** Include candidate/policy evidence,
      actors, usage references, waits, and first verifier start. Validate versions and closed fields.
- [ ] **F.2 Commit closure and its record atomically.** Use unit/close-generation uniqueness,
      preserve reopen history, and insert the export obligation in the same SQLite transaction.
- [ ] **F.3 Render status from SQLite.** Generate Markdown on demand. Export JSONL using the
      single-writer temporary-projection/atomic-replace protocol; it is never status authority.
- [ ] **F.4 Calculate threshold metrics from canonical records.** Include attempts, nudges, and
      elapsed time to first verifier. Document the query beside master plan §11.2's ratified values.
- [ ] **F.5 Test closure/export crash boundaries.** Cover transaction commit, replacement, export
      acknowledgment, duplicate replay, reopen generations, and archived schema readers.

## Piece G: The supervisor recovers stopped workers (§2.7)

Lands across master plan Phases 3.7 and 5.3. Depends on Phase 3 dispatch and attempt close, plus
the Phase 4 verifier.

- [ ] **G.1 Extend `state.db` with unit phases and durable scheduling fields.** Store the owner,
      dispatch ID, lease expiry, fencing epoch, last observation, last material progress,
      `next_action_at`, attempt deadline, waiting reason, and candidate commit. Add versioned
      migrations with legacy nonterminal fixtures, process reconciliation, and rollback tests.
- [ ] **G.2 Make every transition idempotent.** Lease, dispatch, close, verify, wake, and resume
      use unique operation IDs and transactional compare-and-swap. A stale fencing epoch cannot
      update a unit. Persist/query operation identities for external dispatch, review, transfer,
      and integration; uncertain unqueryable effects wait or escalate rather than repeat blindly.
- [ ] **G.3 Replace repeated idle nudges with one closeout prompt.** Restate the task goal and
      name any known failed checks. A second idle result without material progress closes the
      attempt, preserves the candidate, and runs verification.
- [ ] **G.4 Recover frozen and dead workers automatically.** Confirm process-tree inactivity,
      interrupt the pane, close the attempt, verify the candidate, and start a fresh worker while
      budget remains. Recoverable failures escalate on repeated identical failure or exhaustion;
      safety, authorization, and hard-deadline blocks retain their immediate enforcement.
- [ ] **G.5 Add `herdr_master/reconciler.py`.** Scan due `next_action_at` rows independently of
      pane events. On daemon start, adopt valid live attempts, expire stale leases, and resume all
      due nonterminal units.
- [ ] **G.6 Keep fan-out supervisor-visible.** Add the no-unmanaged-subagents rule to the task
      packet. K's validated decomposition creates units with separate leases and budgets. A worker child
      process remains part of its parent's attempt and cannot report completion independently.
- [ ] **G.7 Test crashes at every transition.** Duplicate daemon starts, lost dispatch replies,
      process death, pane loss, and duplicate wake events must converge without duplicate work.
- [ ] **G.8 Populate F's complete run-record schema.** Supply machine, dispatch, lease, progress,
      waits, reservations, and close reason without an independent incompatible record shape.
- [ ] **G.9 Implement actor registration before dispatch.** Persist parent/unit/attempt identity,
      leases, lifecycle, and budgets allocated from the initiative. Test child recovery and prohibit
      status-only completion or budget creation. J consumes this execution-layer state.
- [ ] **G.10 Provision and test the daemon service.** Implement the explicit launchd/systemd install,
      preflight, restart, environment, logging, and uninstall contract from §2.7.
- [ ] **G.11 Verify the unblocker response contract.** Reproduce the grid's suspected `status` versus
      `agent_status` mismatch against the actual response, fix if confirmed, and add a regression
      test before integrating persisted prompt/escalation state.

## Piece H: Provider capacity pauses without spending retries (§2.8)

Lands with master plan Phase 9.3. Depends on G's waiting and wake transitions.

- [ ] **H.1 Add quota and reservation tables to `state.db`.** Key each pool by provider,
      non-secret account fingerprint, and limit ID. Store every applicable window, observation,
      reset time, state, generation, and probe time.
- [ ] **H.2 Add provider quota adapters.** Normalize percentage, reset time, limit ID, source,
      confidence, freshness, capacity units, generation, and snapshot coverage. A failed or unknown
      probe pauses by default. A profile can opt into one
      serialized reactive call when no usage API exists.
- [ ] **H.3 Reserve enforced bounds transactionally.** Implement §2.8 projected usage per window,
      with compatible units and no double counting at settlement. Unknown billing stays reserved.
      Percentage-only windows without a valid conversion cannot claim strict projected admission.
- [ ] **H.4 Enforce the 95 percent soft limit.** Start no new call against a pool at or above the
      threshold. Continue only work that makes no model call. Move affected units to
      `waiting(provider_quota)` without decrementing attempt or retry budgets.
- [ ] **H.5 Wake and probe after reset.** Persist `wake_not_before`, acquire one probe lease, and
      resume only when every applicable window is below the threshold. Duplicate timers and daemon
      restarts must produce one wake transition. Probe freshness and successful projected admission
      are required; a passed reset timestamp is not evidence.
- [ ] **H.6 Keep fallback explicit.** Do not change provider, account, model family, or machine to
      avoid a pause unless the approved profile permits that route. Shared account limits apply
      across machines.
- [ ] **H.7 Separate all budget clocks.** Report active execution time, quota wait, machine wait,
      human wait, calendar deadline, settled spend, reserved spend, and attempt count.
- [ ] **H.8 Test concurrency and restart behavior.** Cover 94.9 and 95 percent, simultaneous
      reservations, multiple windows, shared accounts on two machines, unknown billing, reset
      without restored capacity, and restart during pause. Include delayed snapshots, external
      account use, duplicate observations, reset-spanning calls, and conservative uncovered usage.
- [ ] **H.9 Implement and publish the worker support matrix.** Prove pre-call/post-call hooks or
      gateway mediation for strict modes, including child calls. Enforce bounded-session caps.
      Reject unsupported unattended strict dispatch and label approved reactive modes honestly.
- [ ] **H.10 Own uncertain-usage reconciliation.** Persist next action, deadline, request/window
      identities, snapshot coverage, and authorized resolution evidence. Expiry alone cannot release
      possibly accepted usage; unresolved deadlines block visibly.

## Piece I: Route before dispatch and relocate between attempts (§2.9)

Lands in master plan Phase 6. Depends on G's leases, H's quota admission, and a verified remote
transport.

- [ ] **I.1 Extend machine profiles with capabilities and capacity.** Include repository access,
      operating system, architecture, browser, Docker, GPU, data and secret policy, worker and
      verifier slots, and cache observations.
- [ ] **I.2 Add initiative units and dependencies to `state.db`.** Store scope, dependencies,
      required capabilities, repository, base commit, verification-policy hash, and integration
      branch. Static per-machine queue items remain valid as pinned units.
- [ ] **I.3 Extend K's local ready-set scheduler for the fleet.** In `herdr_master/scheduler.py`,
      select ready units by dependency state, eligibility,
      repository locality, capacity, quota, cache state, and transfer cost. Serialize overlapping
      scopes and integration branches with leases.
- [ ] **I.4 Add initiative branching.** Create an internal branch per unit from the integration
      commit that contains its verified dependencies. Integrate verified units in dependency
      order. Run affected checks after each integration and the full required pipeline before the
      final pull request.
- [ ] **I.5 Add attempt-boundary relocation.** Close the source attempt, preserve a secret-scanned
      commit or content-addressed Git bundle, hash non-code artifacts, raise the fencing epoch,
      fetch on the destination, and run preflight and verification again.
- [ ] **I.6 Reject late source-machine results.** Keep them for diagnosis, but do not allow an old
      fencing epoch to change unit, integration, or completion state.
- [ ] **I.7 Schedule verification as its own work.** Builds, platform tests, GPU tests, and browser
      tests may run on different eligible machines against the exact candidate commit and policy
      hash.
- [ ] **I.8 Support multi-repository initiatives.** Track per-repository integration branches and
      cross-repository dependencies. Produce an ordered pull-request set with compatibility gates
      and K's requirement completion query, without claiming atomic cross-repository landing.
- [ ] **I.9 Run the two-machine acceptance test.** Route by capability, relocate one failed
      attempt, reject one stale result, survive one disconnect, and integrate independent and
      overlapping units without duplicate execution.
- [ ] **I.10 Define and test unavailable-source recovery.** Record acknowledged checkpoint hashes.
      Disconnect before export; resume the last durable checkpoint only under an explicit loss policy,
      otherwise wait with a deadline and escalation. Never claim unavailable work transferred.

## Piece J: Show current work, history, usage, and evidence (§2.10)

Lands after the CLI status path in master plan Phase 7.4. Depends on F's run records, G's actor
and progress state, H's usage records, and I's initiative and machine state.

- [ ] **J.1 Add five status types.** Add `FleetStatus`, `InitiativeStatus`, `UnitStatus`,
      `EscalationRecord`, and `RunRecord`. Share identifiers and evidence references without
      forcing healthy status into an escalation record.
- [ ] **J.2 Add `herdr_master/status.py`.** Build snapshots from `state.db`, Git, run records, and
      evidence artifacts. Support `status`, `status --initiative`, and `status --unit`, with the
      same typed output available through `--json`.
- [ ] **J.3 Add history and evidence commands.** Implement `watch`, `history --unit`,
      `diff --unit`, and `evidence --unit`. Stream state transitions, not pane dumps.
- [ ] **J.4 Generate TODO marks from supervisor state.** Render `[ ]`, `[>]`, `[x]`, and `[!]`
      from requirement and unit state. Reject agent-authored completion changes.
- [ ] **J.5 Record the complete actor hierarchy.** Link every worker, registered child, reviewer,
      and verifier job to an attempt. Show its machine, model, lease, deadline, last observation,
      last material progress, next action, budget, and evidence.
- [ ] **J.6 Keep activity and progress separate.** A heartbeat or status message updates only the
      last observation. Require a changed candidate commit, verifier result, satisfied
      requirement, or validated blocker to update material progress.
- [ ] **J.7 Attribute model usage.** Record reservations and settled input, output, and cached
      tokens by provider, account fingerprint, model, role, initiative, unit, attempt, and actor.
      Keep active time and each wait class separate.
- [ ] **J.8 Label cost by its evidence.** Calculate API estimates from a versioned price schedule
      and reconcile them when provider billing exists. Report cost as unavailable for a
      subscription that exposes no per-call billing.
- [ ] **J.9 Add a read-only local web viewer.** Consume the daemon's snapshot and event API. Show
      initiative dependencies, the actor tree, timelines, machines, waits, usage, Git changes,
      and verification evidence. Store no scheduler state or second copy of status data.
- [ ] **J.10 Secure viewer access.** Bind to loopback by default. Require authenticated private
      access for remote viewing. Exclude raw prompts, pane buffers, secrets, and chain-of-thought
      from default responses. Enforce authorized evidence IDs, path containment, and download
      redaction; provision and live-test remote private authentication before enabling access.
- [ ] **J.11 Run the consistency acceptance test.** Run registered actors across two machines and
      compare the CLI, JSON, TODO projection, event stream, and viewer. Confirm that a chatty
      stalled worker does not count as progressing and that available usage totals reconcile.
- [ ] **J.12 Implement transactional events and snapshot revisions.** Test monotonic IDs,
      idempotent replay, concurrent changes, and resnapshot after an event-retention gap.
- [ ] **J.13 Supply versioned pricing data and normalized usage.** Pin verified source, currency,
      effective date, model/category coverage, and refresh ownership. Test disjoint cache categories,
      rate-unit conversion, unavailable rates/usage, and evidence-preserving billing adjustments.

## Piece K: Plain-goal intake and deterministic completion (§2.11)

Depends on the local daemon, approved profiles, and H admission for planning calls. Required
before initiative scheduling and status; legacy standalone queues can run without migration.

- [ ] **K.1 Implement idempotent goal/repository/profile intake.** Persist request ID and revision.
      Apply explicit-input precedence and bounded clarification/replanning within initiative budgets.
- [ ] **K.2 Produce requirements and unit mappings transactionally.** Store stable IDs, acceptance
      criteria, approved checks, scopes, capabilities, dependencies, and authorized revisions.
      Reject cycles, missing references, uncovered requirements, and model-authored commands.
      Add the local dependency-ready scheduler; I.3 later extends placement to multiple machines.
- [ ] **K.3 Implement the completion query.** Require verified/integrated requirements or explicit
      authorized waivers plus final pipeline evidence. Human-blocked work prevents success.
      No ready units with unfinished work must produce an explained wait or blocker.
- [ ] **K.4 Add revision-checked queue import and generated TODO output.** Preserve legacy queues
      until explicit migration, prevent duplicate/stale imports, reject agent-made completion, and
      read packet remaining-work from the correct authority. Never reimport a generated projection.
- [ ] **K.5 Preserve evidence and budgets across replanning.** Require approval for scope/acceptance
      changes, invalidate affected evidence, retain history, and never replenish spent capacity.
- [ ] **K.6 Run the goal-to-completion acceptance test.** Stop a worker early, finish the full
      dependency graph without manual nudges, and prove one human-blocked requirement prevents
      success. Cover waivers, missing checks, cycles, duplicate input, and stale revisions.

## Piece L: Real application verification (§2.12)

Depends on C candidate identity and approved verification profiles. Start locally before I adds
remote placement; deployment and pixel comparison are not required.

- [ ] **L.1 Define the approved gate policy and result schema.** Bind ordered lint/unit/build/
      integration/REST/browser gates and results to candidate, policy, runner, and evidence identities.
      Missing required gates fail; inapplicable gates require an authorized reason.
- [ ] **L.2 Implement owned service lifecycle.** Lease ports, isolate data/fixture accounts, start
      the exact candidate, verify readiness and service identity, and reject unrelated stale servers.
- [ ] **L.3 Implement real REST assertions.** Verify endpoint/method/status/schema and backend
      mutation with scoped fixtures and cleanup.
- [ ] **L.4 Rewrite the small browser scenario runner.** Correlate UI actions with expected REST
      endpoint/method/payload/response and independent backend state. Reject mock/generated fallback.
- [ ] **L.5 Provision browser capability.** Pin/acquire runner and browser revisions and host
      dependencies, then live-probe the real app before marking a machine eligible.
- [ ] **L.6 Capture bounded redacted evidence and recover cleanup.** Persist service/fixture/port
      cleanup obligations across cancellation, process death, and daemon restart.
- [ ] **L.7 Run negative and final-candidate acceptance.** Fail wrong API target/payload, absent
      mutation/app, stale server, synthetic fallback, and missing required tests. Kill the runner
      mid-scenario and prove cleanup; reject results from an older candidate or policy.

## Not scheduled

- The BusyBrain watchdog and bridge on this host (merge plan §6.3). Unload
  `com.openbrain.slack-cursor-bridge-watchdog` and `com.openbrain.slack-cursor-bridge`. Slack is not the interface plane (merge plan §3), so
  there is nothing to keep alive. Blocks Phase 5's timing numbers.
- Live process and terminal handoff. §2.9 relocates only after an attempt closes.
- Everything in merge plan §3. Do not add items for it without new evidence recorded in the
  merge plan first.
