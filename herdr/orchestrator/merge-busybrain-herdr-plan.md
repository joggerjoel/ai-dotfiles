# Merge Plan: BusyBrain into Herdr Master Control

## 0. What this document is

An **architecture plan** for bringing BusyBrain's ideas into herdr master control. It amends
`master-control-herdr-plan.md` (the master plan) and never replaces it. Where this document and
the master plan disagree, the master plan wins unless a section here says `amends §N` and states
the new rule. Work items live in `merge-busybrain-herdr-todo.md` and cite sections here.

Two rules govern the merge:

1. **No BusyBrain code is imported.** Every piece adopted is rewritten against herdr's
   invariants, in `herdr_master/`, with its own tests. §1 gives the evidence for this rule.
2. **Structure stays on the supervisor's side of the boundary.** BusyBrain put its schemas on
   the agent's output and paid for it in repair machinery. Herdr keeps its schemas on the
   supervisor's inputs (config, queue, nonces, verifier exit codes) and on the small files it
   harvests from a work tree. The pieces below add structure at those two places only.

The BusyBrain checkout is `~/Developer/busybrain`. Every file path below that starts with
`orchestration/`, `docs/`, or `slack-cursor-bridge/` is relative to that checkout. Paths that
start with `herdr_master/` or `skills/` are relative to this repository.

## 1. Why merge, and why not port

BusyBrain and herdr master control solve the same problem, driving a fleet of coding agents
through a verify-and-retry loop, and they made opposite bets on where structure lives.

|                          | BusyBrain                                                                  | Herdr master control                                                    |
| ------------------------ | -------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| Structure lives on       | The agent's output. The executor must end with a fenced JSON manifest that passes a closed pydantic schema (`orchestration/prompts/executor.md`, `orchestration/schemas/execution.py`). | The supervisor's inputs. `MACHINE.md`, the queue, nonces, and `MC-EXIT` lines are typed. Agent output is a trigger, never evidence (master plan §6). |
| Evidence is              | A prose string per SDLC step, at least 20 characters, passed through a regex for path-like or command-like text (`orchestration/manifest_diff.py:28-87`). | A closed record naming the command, its exit code, and a literal excerpt, validated at harvest (`skills/amnesiac-workers/scripts/validate_state.py`). |
| Retry model              | Up to 5 review passes into the same Cursor thread, with hard caps at 21 and 24 passes added after a real run reached 22 (`orchestration/review_loop_policy.py:20-25`). | The worker is destroyed after every attempt. The repository carries progress (master plan §10.2). |
| Review                   | A separate reviewer with its own job id, whose findings carry a `verification` kind that the harness checks before any LLM judgment (`orchestration/objective_verifiers.py`). | None. Lint and tests only.                                              |
| Size                     | 299 top-level modules and 77,399 lines under `orchestration/`, of which 20 modules exist to recover from stalls, stale state, and dead-letter runs. | 640 lines of tested Python plus one prototype script.                   |

The measurements that settle the port-versus-rewrite question:

- **The schemas cannot be extracted.** `orchestration/schemas/common.py`, the base module every
  manifest inherits from, transitively imports Slack and LangGraph through `content_guard` and
  `pipeline_watchdog`. The validator's import closure is 321 modules. Only a five-module cluster
  around `orchestration/validator_core.py` depends on nothing but pydantic.
- **The output-side bet failed in production.** 219 postmortems between 2026-06-12 and
  2026-07-05 record the same classes on repeat: Cursor streams dying after 181 seconds, resume
  loops that advance nothing, and the evidence gate rejecting the harness's own bookkeeping keys
  as hallucinations (`orchestration/schemas/execution.py:12-19` documents that last one). A test
  suite that passed 31 of 31 was blocked over a wrong cwd label
  (`docs/runtime/postmortems/20260623/064611-oneshot-20260623_060704_45678-postmortem.md`).
- **The project is dormant.** The last pipeline commit is 2026-08-30, the harness track is
  closed at 100 percent, and open work moved to a product built on top of it. 280 of its 333
  orchestration test modules are absent from `test-all.sh`.

What survives that record is a set of shapes, not a codebase. §2 names them.

## 2. The six pieces

Each piece names its BusyBrain source, the invariant it carries, how it lands in herdr, and
what is dropped on the way.

### 2.1 The task packet is a template with required slots

**Source.** `orchestration/prompts/executor.md` is a markdown template with `{{TOKEN}}` slots,
filled by `orchestration/executor_prompt.py:209-254`. The contract documents are injected
verbatim from disk (`orchestration/contract.py:32-36`), so each has one copy.

**Invariant.** Every packet is rendered from one template and every slot is filled or the
render fails. A packet is never built by string concatenation in a caller.

**Lands as.** The `PACKET=` heredoc in `attempt_prototype.sh` moves to
`skills/amnesiac-workers/references/task-packet.md` as a template, and `herdr_master/packet.py`
renders it. The slots are the six packet parts from that reference plus two more:

| Slot                | Source at build time                                 | Absent means                       |
| ------------------- | ---------------------------------------------------- | ---------------------------------- |
| `goal`              | The queue line's title and description (§2.3)        | Render fails                       |
| `remaining`         | Queue lines still `[ ]`                              | Rendered as "none"                 |
| `machine`           | `MACHINE.md`, fetched and hash-checked (master §2.1) | Render fails                       |
| `tree`              | The work tree path and `git rev-parse HEAD`          | Render fails                       |
| `last_failure`      | `verification` from `state.json`                     | Rendered as "first attempt"        |
| `facts`             | Validated `facts.json` records                       | Rendered as "none"                 |
| `blocker_rule`      | Fixed text naming `.herdr/blockers.json` and its shape | Never absent. The slot has no default and no override. |
| `nonce`             | Fresh per attempt                                    | Render fails                       |

The blocker slot is fixed text because the 2026-09-12 run showed a packet without it drains the
retry budget confirming an impossibility (master plan §10.2).

**Dropped.** The 19 BusyBrain slots for SDLC steps, domain constraints, wave digests, and
correction blocks. Herdr has no SDLC phases and no waves. The correction block is replaced by
`last_failure`, which is verbatim verifier output rather than a validator's rewording of it.

**Amends nothing.** `herdr_master/herdr.py` already rejects a prompt carrying the matchable
sentinel pair. The template carries the bare literal nowhere, and the test for `packet.py`
asserts that a rendered packet passes that check.

### 2.2 A reviewer role, with findings the supervisor can check

**Source.** Three BusyBrain mechanisms compose here. `orchestration/harness.py:79-90` raises if
the executor and the reviewer share a job id. `orchestration/schemas/review.py:29-56` gives each
finding a `verification` kind, and `orchestration/objective_verifiers.py:1107-1235` checks the
objective kinds with a command before any LLM judgment. `orchestration/anthropic_structured_tools.py:26-31`
hands the reviewer a tool whose input schema is the manifest schema, so the model cannot emit a
shape the validator rejects.

**Invariants.**

- The reviewer never shares a process, a pane, or a transcript with the worker it reviews.
- A finding carries one `verification` kind from a closed set. The supervisor checks `test`,
  `path_exists`, `path_changed`, and `absence` findings with a command it runs itself, under the
  master plan §2.3 exit protocol. A `judgment` finding escalates. It never loops.
- A review manifest with `status: approved` and a nonzero blocking count is unrepresentable.
  The parser rejects it.
- The reviewer's output arrives through a tool call whose schema is the finding schema, not
  through text the supervisor parses.

**Lands as.** `herdr_master/review.py`. The reviewer is an Anthropic Messages API call made by
the daemon, not an agent in a pane. Panes exist because workers need a shell and a repo. A
reviewer needs a diff and a verdict, and the API gives a schema-constrained verdict that a TUI
cannot. The reviewer sees the packet's goal, `git diff origin/<base_branch>..HEAD`, and the
verifier's output. It never sees the worker's transcript. The model is configured per profile in
the supervisor-owned `MACHINE.md` and defaults to a different model family from the worker's
`--kind`.

The finding shape, held as a dataclass with a hand-written JSON schema beside it:

```json
{
  "finding_id": "R1",
  "severity": "blocking",
  "verification": "absence",
  "file": "slugify.py",
  "issue": "debug print left in slugify()",
  "verify_cmd": "grep -n 'print(' slugify.py",
  "expect_exit": 1
}
```

`severity` is `blocking` or `warning`. `verification` is one of `test`, `path_exists`,
`path_changed`, `absence`, `judgment`. `verify_cmd` is required for `test` and `absence`,
`verify_paths` for the two path kinds, and neither for `judgment`. The schema is written by hand
rather than generated because `herdr_master/` uses the standard library only, and a test asserts
that the dataclass fields and the JSON schema properties are the same set, the way
`orchestration/tests/test_sdlc_registry_sync.py` keeps BusyBrain's markdown and registry equal.

**Where it sits in the lifecycle.** After the master plan §6 verifier passes and before the
land step. A blocking objective finding that the supervisor confirms ends the attempt exactly as
a verifier failure does: the finding goes into the next packet's `last_failure` and the retry
budget decrements. One budget, one close path (master plan §10.2). A blocking finding the
supervisor cannot confirm is logged and demoted to `warning`, which is BusyBrain's
`review_gate.py:44-64` rule and the one part of its review loop that reduced churn.

**Dropped.** Five review passes per finding. The 21 and 24 pass caps. `review_normalize.py`,
which exists because BusyBrain parsed reviewer text. The `manifest_contains` and
`command_attribution` kinds, which check a manifest herdr does not have.

### 2.3 Queue fields are parsed or deleted

**Source.** `orchestration/required_decomposition.py:121-186` parses an operator-written block
out of free text into a typed manifest so a human-specified plan skips LLM re-decomposition.
The principle transfers even though the manifest does not.

**Invariant.** A field in `TODO.template.md` that no parser reads does not exist in the
template. Today the template offers Description, Scope/Files, Verification Command, and Expected
Outcome, and `herdr_master/taskqueue.py` reads none of them.

**Lands as.** `taskqueue.py` parses continuation lines the way it already parses
`allow-test-changes:`:

| Field                  | Parsed as                                    | Used by                                                                 |
| ---------------------- | -------------------------------------------- | ----------------------------------------------------------------------- |
| `description:`         | Free text                                    | The packet's `goal` slot (§2.1), after the title                        |
| `scope:`               | A list of repo-relative paths or globs       | The land step. A staged path outside the scope escalates, which sharpens the master plan §6 unseen-path rule from "never seen in this repo" to "not declared for this task". |
| `verify:`              | One shell command                            | Overrides `test_cmd` for this task only. `lint_cmd` still runs, the same rule `ROUTER.json` already has (master plan §6 step 1). |

Expected Outcome is deleted. The exit code is the expected outcome. A continuation line with an
unknown key quarantines the task with `[!]`, matching the master plan §2.5 rule for unknown
marks.

**Amends master plan §2.5.** The recognizer gains the three keys above. The queue line grammar
is otherwise unchanged.

### 2.4 Escalations and status are packets, not buffers

**Source.** `orchestration/failure_packet.py` bounds every field (`summary` at 600 characters,
`first_error` at 300, `evidence_paths` at 20) and points at the raw artifact with
`raw_available_at` instead of inlining it. A static table maps a failure class to one
recommended action (`failure_packet.py:89-106`).

**Invariant.** An operator or a model reading `herdr-master status` or an escalation sees a
bounded record with a class, a pointer to raw evidence, and one recommended action. Never a
pane dump.

**Lands as.** The escalation record in the master plan §5 gains this shape and
`herdr-master status` renders it:

```json
{
  "unit_id": "fix-auth-timeout-9f2a1c",
  "attempt": 2,
  "class": "verifier_failed",
  "step": "verify",
  "summary": "test_refresh_expired_token expected 401, received 500",
  "evidence_paths": ["~/.herdr-master/machines/local/units/fix-auth-timeout-9f2a1c/attempt-2.log"],
  "recommended_action": "retry",
  "raw_available_at": "~/.herdr-master/actions.jsonl#L4410"
}
```

The class set is closed and small: `verifier_failed`, `review_blocked`, `blocker_reported`,
`config_hash_mismatch`, `unseen_path`, `secret_hit`, `stall`, `exhausted`, `unknown_prompt`. The
class-to-action table is a dict in `herdr_master/escalation.py`. There is no confidence score,
because every class in herdr is assigned by a deterministic check, not by a classifier.

**Dropped.** The 16-member BusyBrain class set, the confidence thresholds, and `packet_cli.py`
as a separate command. Status and escalation are already commands of the one binary
(master plan §2.6).

### 2.5 Two identical attempts end the unit early

**Source.** `orchestration/convergence.py:27-37` fingerprints each blocking finding and
escalates when the set repeats for two passes. `herdr_unblocker.py:238-273` already does the
same for blocked prompts with `AntiLoopTracker`.

**Invariant.** When attempt N's verifier excerpt and confirmed review findings hash equal to
attempt N-1's, the unit escalates with class `stall` rather than spending the rest of its
budget. A strict subset of the previous findings is progress and does not trigger this.

**Lands as.** The normalize-and-hash from `AntiLoopTracker` moves into `herdr_master/` and is
applied to the `verification.excerpt` in `state.json` plus the sorted `finding_id` and `issue`
pairs from §2.2. The threshold is two, and it is one of the numbers the master plan §11.2 says
to ratify from the action log.

### 2.6 Every unit closes with a run record

**Source.** BusyBrain writes a postmortem per run: a markdown file with fixed sections
(terminal state, preflight updates, state recovery, mistakes and false blockers, root causes,
harness fixes, remaining risks), a `postmortem-contract.json`, a plan and todo pair, and one
rollup line in `docs/runtime/postmortems/postmortems.jsonl`. `orchestration/run_summary.py:4239`
builds the contract and `:4296` validates it. The corpus is the most valuable artifact in that
repository. Every failure class in §1 was read from it, not from the code.

**What went wrong with it.** Four files per run produced 598 files in a month and a pruning
script. Some runs had a model write the summary, and `AGENTS.md` had to add a rule that Codex
must not be the only component producing one. The most recent entry, 2026-08-02, is
hand-written and labels itself so.

**Invariant.** The daemon writes one close record per unit, from `state.db` and
`actions.jsonl`, with no model in the loop. The record has a fixed field set and is one line
appended to `~/.herdr-master/units.jsonl` on the orchestrator. Markdown is rendered on demand by
`herdr-master status --unit <id>` and never stored.

**Lands as.** `herdr_master/runrecord.py`. The fields:

| Field            | Source                                                                 |
| ---------------- | ---------------------------------------------------------------------- |
| `unit_id`, `profile`, `title` | The queue line and its `task_id`                          |
| `opened_at`, `closed_at`      | The daemon's clock at dispatch and at close                |
| `final`          | `done`, or one class from the §2.4 set                                 |
| `attempts[]`     | Per attempt: `n`, `kind`, `started`, `ended`, `verifier_exit`, `verifier_excerpt`, `findings_confirmed`, `injections`, `nudges`, `close_reason` |
| `blockers[]`     | The validated `blockers.json` records harvested across attempts        |
| `config_sha256`  | The `MACHINE.md` hash the run trusted (master plan §2.1)               |
| `landed`         | The PR URL, the archive path, or `null`                                |

**Why it is not optional.** Master plan §11.2 says to ratify every threshold from the action
log. `actions.jsonl` is one line per injected action. The numbers to ratify (attempts per unit,
nudges before escalation, seconds to first verifier run) are per unit, and this record is the
table they are read from. That is the same reason BusyBrain's corpus outlived its code.

**Dropped.** The markdown file per run, the plan and todo pair per run, the contract validator,
and the `lessons` and `decisions` fields of the rollup. A lessons field is reasoning by another
name. The amnesiac-workers rule that surviving state carries evidence and never reasoning applies
to the master's own records too.

## 3. What is deliberately not taken

Each item names why, so that nobody reopens it without new evidence.

- **The Slack bridge and the Cursor adapters.** Herdr is the interface plane. The operator's
  input channel is the queue file and `herdr-master ack`, the output channel is `herdr-master
  status` and the master plan §5 delivery rules, and the agent surface is a herdr pane with any
  of the 23 `--kind` values. `slack-cursor-bridge/` and the four adapters under `orchestration/`
  exist to give Slack and Cursor those roles, and nothing in them transfers. Decided 2026-09-13.
- **LangGraph.** Herdr's lifecycle is one loop with a daemon and SQLite. BusyBrain wired its own
  JSON state files because LangGraph's checkpointer deadlocked on Cursor subjobs
  (`orchestration/graph.py:6483-6485`).
- **The nine-phase SDLC and per-step evidence manifests.** The evidence gate over-triggers on
  prose heuristics (§1). Herdr's evidence is a command the supervisor ran.
- **A fenced JSON block in the agent's final message.** Herdr harvests `.herdr/*.json` through
  `pane run … cat` (master plan §10.2 step 4), which does not depend on how a TUI renders its
  last message.
- **`execution_manifest_pipeline.py`, `review_normalize.py`, and the 20 recovery modules.** Each
  compensates for a failure class that herdr's design does not produce: no long-lived thread to
  stall, no manifest to repair, no reviewer text to coerce.
- **`content_guard.py` and the injection heuristics.** Relevant only to the incident lane, which
  is blocked (master plan §11.3). Revisit if Phase 8 unblocks.
- **The domain registry and disposition registry.** Herdr routes by queue and `ROUTER.json`, not
  by classifying prompts.
- **pydantic.** `herdr_master/` uses the standard library. §2.2 keeps the schema-as-tool idea
  with a hand-written JSON schema and a sync test. Adopt pydantic only if a third schema appears.

## 4. Order of delivery

The pieces depend on the master plan's phases as follows. The todo file carries the checkboxes.

| Piece | Lands in master plan phase | Depends on                                    |
| ----- | -------------------------- | --------------------------------------------- |
| §2.3  | 3.2 (queue reader)         | Nothing. Can start now.                       |
| §2.1  | 3.5 (packet builder)       | §2.3 for the `goal` slot                      |
| §2.4  | 7.1 and 7.4                | Phase 3's `state.db`                          |
| §2.2  | New phase 4.5, after 4.3   | Phase 4's verify pane and exit protocol       |
| §2.5  | 5.3 (ratify the numbers)   | §2.2, so that findings exist to fingerprint    |
| §2.6  | 3.6 (attempt close) and 7.4 | Phase 3.7's `state.db`                          |

## 5. How the merge proves itself

Each piece ends in a unit test in `herdr_master/`. Two pieces also need a live run on the
throwaway repo `attempt_prototype.sh` used, because a unit test cannot show that an agent
behaves differently:

- **§2.1.** A packet rendered from the template drives one attempt to `MC-DONE` and one to a
  valid `blockers.json`, repeating the 2026-09-12 results with no heredoc in the driver.
- **§2.2.** Plant a defect the verifier cannot see, a leftover debug print with tests still
  green, and show that the reviewer emits an `absence` finding, that the supervisor confirms it
  with `grep`, and that the next attempt removes it. Then plant a design defect and show that a
  `judgment` finding escalates instead of looping.

## 6. Preconditions and open items

1. **The reviewer needs an API key the daemon can read.** Herdr panes have no Keychain access,
   and the daemon may run under launchd with the same limit. The key source is a supervisor
   config value in the orchestrator's own config (master plan §9.2 places Chrome settings there
   for the same reason), never in a pane and never in `MACHINE.md`.
2. **The reviewer model is unchosen.** It must differ from the worker's kind by default. The
   first live run (§5) picks it.
3. **The BusyBrain runtime is still running on the orchestrator host.** `slack-cursor-bridge/watchdog.py`
   has logged 48,273 unhealthy ticks out of 49,080 since 2026-05-29, 45,029 of them for one
   missing Ollama model, and on 2026-09-13 it and four `--once` children held four to five CPU
   cores. This is not part of the merge, but a fleet supervisor sharing that host inherits the
   load. Since Slack is not the interface plane (§3), the fix is to unload
   `com.openbrain.slack-cursor-bridge-watchdog` and `com.openbrain.slack-cursor-bridge` rather than to feed the watchdog the model it wants.
   Do it before Phase 5's timing numbers are ratified, or the load skews them.

4. **Cross-machine handoff is unbuilt in both systems and out of scope for this merge.**
   BusyBrain runs every agent on the Mac Studio and uses Ansible only to deploy. Herdr assigns a
   task to a machine profile at queue time (`~/.herdr-master/machines/<profile>/TODO.md`,
   master plan §2.5) and drives that machine over `herdr --remote` or `ssh`, which is master
   plan Phase 6 and starts with the round-trip test in its todo item 6.2. There is no mid-task
   migration and no plan for one, because a work tree lives on one machine. Subagents that a
   worker spawns inside its pane stay on that machine, are invisible to the supervisor, and
   count against that worker's attempt.

## Revision log

- **2026-09-13.** First version, from the comparison of `~/Developer/busybrain` against the
  master plan and `herdr_master/` at commit `ab3fac6`.
