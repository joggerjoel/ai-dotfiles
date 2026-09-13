# Merge BusyBrain into Herdr: Execution Roadmap (TODO)

> **This file tracks work, not design.** `merge-busybrain-herdr-plan.md` (the merge plan) is
> the source of truth for every decision here, and it amends `master-control-herdr-plan.md`
> (the master plan). Items cite the section that governs them and must not restate it. If an
> item and a plan disagree, the plan wins and the item is stale.

**Status.** Nothing is built. Piece A is unblocked and can start now. Pieces B and D wait on
master plan Phase 3. Piece C waits on Phase 4. Piece E waits on C. Piece F lands with Phase 3.6 and is read by Phase 5. The BusyBrain runtime on
this host (merge plan §6.3) is unresolved and blocks Phase 5's numbers, not this file.

Piece letters below map to merge plan sections: A is §2.3, B is §2.1, C is §2.2, D is §2.4,
E is §2.5, F is §2.6. The order is delivery order (merge plan §4), not section order.

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

## Piece D: Escalations and status are packets (§2.4)

Lands in master plan Phase 7.1 and 7.4. Depends on Phase 3.7's `state.db`.

- [ ] **D.1 `herdr_master/escalation.py`** holds the record shape and the closed class set from
      §2.4. Field limits are enforced in the constructor, not by convention.
- [ ] **D.2 The class-to-action table is a dict** in the same module, with a test that every
      class has exactly one action.
- [ ] **D.3 `raw_available_at` points into `actions.jsonl`** by line, so the record never
      inlines a buffer.
- [ ] **D.4 `herdr-master status` and every escalation render this record**, and nothing else.
      Master plan §7.4 is amended to say so.

## Piece C: A reviewer role (§2.2)

New master plan Phase 4.5, after 4.3. Depends on Phase 4's verify pane and exit protocol.

- [ ] **C.1 Resolve the key source** (§6.1). A supervisor config value in the orchestrator's
      own config. Confirm the daemon can read it under launchd before writing any reviewer code.
- [ ] **C.2 `herdr_master/review.py`** holds the finding dataclass, the manifest dataclass, and
      the hand-written JSON schema. A sync test asserts the dataclass fields and the schema
      properties are the same set.
- [ ] **C.3 `approved` with a nonzero blocking count is rejected** by the parser. Test it.
- [ ] **C.4 The API call.** One Messages request with the schema as the tool input schema. The
      reviewer receives the goal, the diff against `origin/<base_branch>`, and the verifier
      output. A test asserts the worker transcript is not in the request.
- [ ] **C.5 Objective confirmation.** For `test`, `absence`, `path_exists`, and `path_changed`,
      the supervisor runs `verify_cmd` or checks `verify_paths` in the verify pane under the
      exit protocol. An unconfirmed blocking finding is demoted to `warning` and logged.
- [ ] **C.6 A confirmed blocking finding ends the attempt** through the master plan §10.2 close.
      It becomes the next packet's `last_failure` and the retry budget decrements. No second
      budget.
- [ ] **C.7 A `judgment` blocking finding escalates** with class `review_blocked`. It never
      loops.
- [ ] **C.8 Pick the reviewer model** (§6.2). It defaults to a different family from the
      worker's `--kind`, set per profile in the supervisor-owned `MACHINE.md`. `config.py`
      parses the new key, and `test_config.py` asserts the template still parses.
- [ ] **C.9 Live run** (§5): a leftover debug print with green tests produces an `absence`
      finding, the supervisor confirms it with `grep`, and the next attempt removes it. Then a
      design defect produces a `judgment` finding that escalates.

## Piece E: Two identical attempts end the unit early (§2.5)

Lands in master plan Phase 5.3. Depends on C, so that findings exist to fingerprint.

- [ ] **E.1 Move normalize-and-hash** from `AntiLoopTracker` in `herdr_unblocker.py` into
      `herdr_master/`, and delete it from the unblocker when Phase 3 absorbs that file.
- [ ] **E.2 Fingerprint the attempt** from `verification.excerpt` in `state.json` plus the
      sorted confirmed findings. A strict subset of the previous findings is progress.
- [ ] **E.3 Two equal fingerprints escalate** with class `stall`. The threshold of two is in the
      list master plan §11.2 ratifies from the action log.

## Piece F: Every unit closes with a run record (§2.6)

Lands in master plan Phase 3.6 and 7.4. Depends on Phase 3.7's `state.db`.

- [ ] **F.1 `herdr_master/runrecord.py`** holds the record shape from the §2.6 table. The
      constructor rejects unknown keys and a `final` outside the §2.4 set plus `done`.
- [ ] **F.2 The attempt close appends the attempt sub-record** and the unit close appends one
      line to `~/.herdr-master/units.jsonl`. The daemon writes it from `state.db`. Nothing in a
      work tree is read for it.
- [ ] **F.3 `herdr-master status --unit <id>` renders markdown** from that line. No markdown
      file is written anywhere.
- [ ] **F.4 Phase 5.3 reads its thresholds from `units.jsonl`.** Write the command that
      produces attempts per unit and nudges before escalation, and record it in master plan
      §11.2 beside the numbers it ratifies.

## Not scheduled

- The BusyBrain watchdog and bridge on this host (merge plan §6.3). Unload
  `com.openbrain.slack-cursor-bridge-watchdog` and `com.openbrain.slack-cursor-bridge`. Slack is not the interface plane (merge plan §3), so
  there is nothing to keep alive. Blocks Phase 5's timing numbers.
- Cross-machine handoff (merge plan §6.4). Master plan Phase 6, starting with its item 6.2.
- Everything in merge plan §3. Do not add items for it without new evidence recorded in the
  merge plan first.
