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
start with `herdr_master/` are relative to `herdr/orchestrator/`; `skills/` paths are relative
to this repository.

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

## 2. The thirteen pieces

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
| `remaining`         | SQLite requirement state after import; legacy pending queue otherwise (§2.11) | Rendered as "none" |
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

**Source.** BusyBrain separates worker and reviewer identities, constrains verdicts with a
schema, and confirms objective findings. Carry those rules, not arbitrary command strings.

**Invariant.** Review, objective confirmation, verification, and landing authorize one immutable
tuple: repository, unit base SHA, candidate SHA, and verification-policy hash. Freeze the
candidate and stop its writer before verification. Store that tuple with every result. A changed
member invalidates the result. Integration creates a new candidate requiring applicable checks
again before the final pull request.

**Lands as.** `herdr_master/review.py`. A separate daemon-owned Anthropic Messages request
receives the goal, the diff between the recorded unit base and candidate SHAs, and bounded
verifier evidence. It receives neither the worker transcript nor prior reasoning. The model is
configured per profile and defaults to a different family from the worker. An unavailable approved
family causes a durable wait or escalation, never an implicit provider switch.

Before sending, screen the complete payload, including goal, diff, paths, and verifier output,
under the profile's egress and secret policy. An unresolved hit blocks the request with
`secret_hit`. Redaction must preserve sufficient evidence; otherwise review stays incomplete.
Log redaction alone does not authorize sending a raw secret.

A versioned closed schema defines the verdict and typed findings. For example:

```json
{
  "finding_id": "R1",
  "severity": "blocking",
  "verification": "absence",
  "operands": {"path": "slugify.py", "literal": "print("},
  "issue": "debug print left in slugify()"
}
```

Objective kinds are `test`, `path_exists`, `path_changed`, and `absence`; `judgment`
has no executable operands. Tests reference an approved policy check ID. Paths must be normalized
repository-relative paths contained in the immutable candidate. Absence checks search a bounded
literal in a bounded regular file without a shell. Reject absolute paths, parent traversal,
symlink escapes, unknown keys, oversized operands, and arbitrary commands. No `verify_cmd` or
model-selected executable is accepted. Supervisor-owned adapters construct argument vectors for
approved checks. Operator-approved project tests still execute project code under the master
plan's verifier permissions; typed checks do not claim OS containment of a same-user worker.

Dataclasses and schema must agree on required fields, types, enums, closed objects, and cross-field
rules, not only names. Reject `approved` with blocking findings. Missing or malformed structured
output is a failed review operation, never approval.

Confirmation returns `confirmed`, `disproved`, or `inconclusive`. Finding the literal above
confirms the defect; a completed search finding none disproves it. Timeouts, missing execution
dependencies, invalid output, and transport errors are inconclusive. Only a disproved finding
may become a warning. A confirmed blocker closes the attempt through the single existing retry
budget and supplies the next packet's failure evidence. A blocking judgment escalates
`review_blocked`.

Persist review operation ID, candidate tuple, status, deadline, and next action. Transport,
schema, and confirmation failures receive bounded operation retries and backoff within active,
calendar, and spend limits. They do not masquerade as worker defects. Exhaustion escalates
`review_blocked`. A timeout after a possibly accepted request retains uncertain usage; recovery
reconciles the operation before retrying. If the provider cannot disambiguate acceptance, follow
a bounded wait or escalation policy rather than blindly duplicate the call.

Profiles set maximum request-input and evidence bytes. Review the unit delta, not accumulated
dependency changes since a remote branch. An oversized review blocks under `review_blocked`
with reason `review_input_too_large`, requesting decomposition or an explicitly approved
complete-coverage strategy. Never truncate silently or approve uncovered files. Every model
request, including retries, passes §2.8 admission.

**Dropped.** Same-thread review loops, model-authored shell, and prose normalization.
**Amends master plan §6.** This gate follows independent verification and precedes land.
Existing test-surface, scope, secret, and authorization gates remain required.

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

Expected Outcome is deleted from the legacy queue template. Its verification command succeeds
by exit code; initiative acceptance criteria are preserved separately in §2.11, never discarded.
Only operator-approved policy supplies executable `verify:` commands. Model-produced intake may
select approved check IDs, not create a new shell command. A continuation line with an
unknown key quarantines the task with `[!]`, matching the master plan §2.5 rule for unknown
marks.

**Amends master plan §2.5.** The recognizer gains the three keys above. The queue line grammar
is otherwise unchanged.

### 2.4 Escalations are packets, not buffers

**Source.** `orchestration/failure_packet.py` bounds every field (`summary` at 600 characters,
`first_error` at 300, `evidence_paths` at 20) and points at the raw artifact with
`raw_available_at` instead of inlining it. A static table maps a failure class to one
recommended action (`failure_packet.py:89-106`).

**Invariant.** An operator or a model reading an escalation sees a bounded record with a class,
a pointer to raw evidence, and one recommended action. It never sees a pane dump. Normal status
uses the typed projections in §2.10 and includes this record only when the unit has an open
escalation.

**Lands as.** The escalation record in the master plan §5 gains this shape:

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
as a separate command. Status and escalation remain commands of the one binary, but they return
different record types (master plan §2.6 and §2.10).

### 2.5 Two identical attempts end the unit early

**Source.** BusyBrain's convergence checks and Herdr's `AntiLoopTracker` stop repeated failures.
Carry the bounded-stop rule, not presentation-dependent identity.

**Invariant.** Fingerprint canonical confirmed failures: approved check ID or kind, normalized
typed operands and path, expected result, observed result category, and verification-policy
hash. Exclude model-assigned finding IDs, issue prose, timestamps, and unstable excerpts.
Verifier adapters produce stable failure identities. If unavailable, record that limitation and
use the hard retry budget without claiming convergence.

Two equal nonempty failure sets under the same policy escalate as `stall`. A strict subset is
progress. Policy changes start a new comparison series but never replenish the attempt budget.
Tests cover renumbering, paraphrases, reordering, volatile logs, true subset progress, and missing
identity. Ratify the threshold of two from run records under master plan §11.2.

**Lands as.** Shared supervisor failure-identity code used by review and verification. Retain
buffer-based `AntiLoopTracker` for interactive prompt repetition until that separate
responsibility moves into the daemon.

### 2.6 Every unit closes with a run record

**Source.** BusyBrain's postmortems exposed repeated failures. Preserve deterministic evidence
and aggregate queries, not many per-run plans or model-authored reasoning.

**Invariant.** Unit closure inserts one canonical versioned run record in SQLite in the same
transaction as terminal state and an export obligation. A unique `unit_id, close_generation`
key prevents duplicate closure. Reopening creates a new generation and preserves prior history.
Status and metrics read SQLite. JSONL is an optional export, never authority.

**Lands as.** `herdr_master/runrecord.py`. The closed versioned shape includes:

| Field | Meaning |
| --- | --- |
| `schema_version`, `unit_id`, `close_generation` | Schema and closure identity |
| `profile`, `title`, `initiative_id`, `requirement_ids` | Input identity and requirement mapping |
| `opened_at`, `closed_at`, `final` | Times and `done` or one §2.4 escalation class |
| `attempts[]` | Attempt ID, kind, actor, machine, dispatch ID, lease epoch, start/end, first verifier start, close reason, injections, nudges |
| `attempts[].evidence` | Base/candidate SHAs, policy hash, check IDs, exits, bounded excerpts, artifact hashes, canonical failure identities |
| `attempts[].progress` | Observation/material-progress timestamps and typed waits |
| `attempts[].usage` | Reservation and settlement IDs and uncertain billing; quantities follow §2.8 |
| `blockers[]`, `config_sha256`, `landed` | Validated blockers, trusted config hash, integration/PR/archive reference |

A failed unit closure does not complete its initiative (§2.11). Waiting alone does not close a
unit. Reject unknown fields and unsupported versions at boundaries; migrate current rows and
retain readers for archived record versions.

A single exporter builds `~/.herdr-master/units.jsonl` from canonical rows ordered by closure
identity. Initially, write a complete temporary projection, flush it, and atomically replace the
export on the same filesystem. A crash leaves a valid old or new projection; replaying the
pending export generation cannot duplicate lines. An incremental replacement must prove
equivalent recovery. Do not append independently of the terminal transaction.

Render Markdown on request. Aggregate queries report attempts, nudges, and time to first verifier
from recorded timestamps. Test crashes around terminal commit, export replacement, and
acknowledgment, plus reopen generations and old-schema readers.

### 2.7 The supervisor recovers stopped workers

**Source.** BusyBrain's bridge runs `pipeline_progress_reconciler.py` when a child leaves the
active set, rather than waiting for a person to notice that the graph parked. Its watchdog then
uses checkpoints, bounded recovery, and `resume_lease.py` fencing tokens to prevent repeated
resume attempts from running at once. The useful rule is that a live process is not evidence of
progress and a stopped worker is not the end of supervision.

**Invariant.** Models perform bounded attempts. The supervisor owns continuation. Every
nonterminal unit has a durable owner or a durable `next_action_at`. A worker that becomes idle,
stops, crashes, or makes no material progress ends an attempt. It does not end the unit or the
run.

Run versioned SQLite migrations before daemon startup. Reconcile existing nonterminal rows
against real processes and assign each an owner or due action. Block ambiguous legacy state;
test upgrade fixtures, migration rollback, and restart.

The unit phases are `ready`, `running`, `verifying`, `reviewing`, `waiting`, `blocked`, and
`complete`. `waiting` carries a typed reason such as `provider_quota`, `host_capacity`,
`machine_offline`, or `retry_backoff`. `blocked` is reserved for a human decision, a safety
failure, a hard budget limit, or repeated identical failures.

An active unit records `owner_machine`, `worker_id`, `dispatch_id`, `lease_expires_at`,
`fencing_epoch`, `last_observed_at`, `last_material_progress_at`, `next_action_at`,
`attempt_deadline_at`, and `candidate_commit`. Material progress is a changed candidate commit,
a changed verifier result, a satisfied acceptance criterion, or a valid blocker. A status message
does not count.

When a worker becomes idle without the current completion sentinel, the supervisor sends one
closeout prompt that restates the task goal and names any known failed checks. A second idle result
without material progress closes the attempt. The supervisor preserves the candidate and runs the
verifier. A failing candidate starts a fresh worker when budget remains. A worker whose buffer and
process tree are both idle past the stall threshold follows the same close, verify, and retry path.
For these recoverable worker failures, the supervisor escalates after retry exhaustion or two
identical failures (§2.5). Safety failures, authorization decisions, and hard deadlines still block
immediately under their own policies; recovery never overrides them.

Herdr owns fan-out. A worker may not create an unmanaged child agent as a substitute for a unit.
Create actor rows before dispatch with actor ID, parent actor, unit/attempt IDs, role, capability
mode, lease, deadline, and budget allocation. Registered children are supervisor-created units
linked to the parent actor and initiative, not status-only rows. Allocate child budgets from the
initiative's remaining allowance without manufacturing capacity. Reviewer and verifier actors
have their own operation lifecycle but share the unit candidate and initiative limits.
Registration, dispatch, observation, close, and recovery are fenced execution-layer transitions.
A parent cannot certify a child's completion.
Large work is decomposed into supervisor-visible units with their own leases, budgets, and
verification. A child process that a worker still starts remains part of that worker's attempt and
cannot extend the attempt deadline or report completion independently.

**Amends master plan §§1, 3, 5, 6, 10.1, and 10.2.** A run may enter `waiting` without opening a
human escalation. Idle and frozen workers take the automatic attempt-close path above before the
supervisor escalates. Verification may start from a preserved candidate after that close even
when the worker omitted `MC-DONE`; the verifier, not the sentinel, determines whether the candidate passes. Unit and initiative
completion additionally require §2.11 requirement and integration gates. Startup reconciliation claims due work with a lease and fencing epoch before it sends
an action. Duplicate dispatch, close, verify, wake, and resume operations converge on the same
persisted state.

**Lands as.** `herdr_master/reconciler.py` plus lease, progress, deadline, and wake fields in
`state.db`. The daemon scans `next_action_at` independently of pane events. `launchd` or `systemd`
restarts the daemon. On startup, the reconciler adopts valid live attempts, expires stale leases,
and resumes every due nonterminal unit. Dispatch, review, transfer, and integration persist
operation intents and result identities. Before retrying an external side effect, query the
target by that identity. If it cannot be queried or deduplicated, preserve an uncertain state and
wait or escalate instead of blindly repeating the action. Database compare-and-swap alone is not
proof of exactly-once external execution.

An explicit install/preflight task provisions the launchd or systemd service with pinned executable
paths, environment, restart policy, logs, and an uninstall procedure. Test restart under the
actual service account. Documentation changes alone never authorize changing running services.

### 2.8 Provider capacity pauses the run without spending retries

**Source.** BusyBrain supplies quota observations and usage vocabulary but lacks concurrent
reservation. Herdr separates observation, admission, and billing evidence.

**Invariant.** Strict workers cannot make model calls without daemon admission. Reserve capacity
in SQLite before every daemon-owned request, including review and recovery. A pane is not an
interception boundary. Each worker-kind adapter must prove pre-call and post-call hooks, or a
credential-mediating gateway covering child calls too. A bounded session allowance is permitted
only if its adapter enforces a hard session cap and reports usage.

The support matrix declares `strict_call`, `bounded_session`, or `reactive_observed`.
Reject unsupported kinds before unattended strict dispatch. Explicitly approved serialized
reactive execution may proceed with its weaker guarantees visible. Do not claim that every
Herdr `--kind` supports per-call enforcement or complete token accounting.

Quota identity is provider, non-secret account fingerprint, limit ID, and window identity.
Machines and model names do not create capacity unless the provider reports separate pools.
Adapters report observation time/freshness, reset, generation, consumed units, capacity, and
snapshot coverage semantics. Normalize each window's units. Tokens, requests, money, and
subscription percentages are not interchangeable.

For a numerically reservable window, compute
`projected = observed_used + locally_uncovered_use + outstanding_reservations + proposed_bound`
inside one transaction. Require `projected <= 0.95 * capacity` and all applicable initiative
time/spend/attempt limits. The proposed bound must be adapter-enforced, not an optimistic
estimate. Count each local call once as outstanding, uncertain, or settled-but-not-covered until
provider evidence covers it. Settlement replaces a reservation in this sum; it is not added twice.

Percentage-only telemetry can enforce an observed stop threshold, but cannot support projected
reservation without a conservative provider-supported conversion. Pause strict admission when
that conversion is unavailable; never invent a percentage-to-token mapping. The 95 percent rule
is a soft admission policy, not protection from usage by other applications sharing the account.
Require fresh observations and disclose unmediated account use.

At or above 95 percent, start no new model call against the pool. Let an accepted call finish
within its enforced bound unless rejected by the provider. Continue non-model lint, test, and
build work. Persist `waiting(provider_quota)`, pause/wake timestamps, source observation, and
reset. The pause consumes no worker attempt or retry. If a CLI cannot pause safely, preserve and
close the attempt, then resume with a fresh worker without charging a failure.

After reset plus a safety margin, one durable probe lease refreshes every applicable window.
Resume only with fresh evidence and successful admission. Failed, stale, or unknown observations
pause with bounded backoff. Passing reset time or reservation expiry is not capacity evidence.

Reservations record ID, operation/actor/unit/attempt, window generation, units, enforced bound,
creation/expiry, state, and provider request ID where available. Uncertain billing remains reserved.
A reconciliation job owns its next action and deadline. At deadline, block for an authorized
resolution instead of silently releasing capacity. Expiry releases only a call proven unaccepted.

Adapters define which calls each snapshot includes. Without a usable watermark, conservatively
retain possibly uncovered use and disclose potential overcount; do not claim exact reconciliation.
Attribute reset-spanning calls by provider semantics. If unknown, retain the bound against each
possibly charged window until evidence resolves it. Old obligations never disappear on a timer.
Tests cover delayed snapshots, another client's usage, duplicate observations, reset-spanning
calls, uncertain billing, and reservations settling without double counting.

Fallback never changes provider, account, family, or machine to avoid a pause unless the approved
profile permits it. Active execution, calendar deadlines, spend, attempt count, and typed waits
remain separate. Quota wait counts against an operator's calendar deadline, not active time.

**Amends master plan §§2.6, 3, 6, 9.3, and 10.2.** Quota pause is durable scheduler state.
**Lands as.** `herdr_master/usage.py`, admission/usage adapters, and a tested worker support
matrix. Unsupported telemetry fields stay unavailable rather than fabricated.

### 2.9 Route before dispatch and relocate only between attempts

**Source.** BusyBrain's decomposition graph schedules dependency-ready work in waves, and
`host_resources.py` limits concurrency from live host capacity. `resume_lease.py` supplies the
lease and fencing rule needed to reject late results. BusyBrain does not move work across
machines, but its recovery rules show that Git state and verified artifacts survive while model
context does not.

**Invariant.** Live model sessions do not move between machines. The scheduler selects a machine
before dispatch from repository access, base-commit availability, operating system, architecture,
browser, Docker, GPU, data and secret policy, host capacity, quota availability, cached build
state, and transfer cost.

A retry may move after the source attempt closes. The source machine preserves a secret-scanned
candidate commit or a content-addressed Git bundle plus hashed non-code artifacts. The daemon
records the unit, attempt, source machine, base and candidate commits, verification-policy hash,
artifact hashes, and lease epoch. The destination acquires a higher fencing epoch, fetches the
exact candidate, runs preflight and verification again, and starts a fresh worker. A late result
from the old epoch is stored for diagnosis and cannot change unit state.

A local commit is not a fleet checkpoint until its secret-scanned data is acknowledged by the
orchestrator artifact store or approved remote. Record that acknowledgment and hash. If the source
disappears before export, fence it and resume from the last acknowledged candidate or base only
when the profile permits loss of unexported work. Record that loss explicitly. Otherwise persist
`waiting(machine_offline)` with a next probe and deadline; missing required artifacts eventually
block for a human decision. Never claim an unavailable candidate transferred. Test disconnects
before export as well as after destination verification.

Large initiatives use supervisor-visible dependencies. An initiative has one integration branch
per repository. Each unit branch starts from the integration commit that contains its verified
dependencies. Independent scopes may run in parallel. Overlapping scopes and integration are
serialized by leases. The supervisor integrates verified unit commits in dependency order and
runs affected checks after each integration. Final build, integration, and browser tests run
against the exact integration commit on machines with the required capabilities.

Multi-repository initiatives carry explicit cross-repository dependencies and candidate commits.
Their output is an ordered set of pull requests with compatibility checks. The system does not
claim that separate repositories land atomically.

**Amends master plan §§2.4, 2.5, 6, 7, and 10.2.** Standalone queue items retain one task branch
and one pull request. Initiative units use internal unit branches and one final pull request per
repository. Static per-machine queues remain valid for pinned repositories, but the scheduler may
route an unassigned ready unit to any eligible machine. Machine loss never authorizes duplicate
execution until the old lease expires or the daemon revokes it with a higher fencing epoch.

**Lands as.** `herdr_master/scheduler.py` owns capability matching, leases, placement, and ready
unit selection. `herdr_master/transfer.py` moves Git and artifact data by content hash. SQLite
stores initiatives, dependencies, assignments, resource leases, integration commits, and fencing
epochs. Live terminal and process migration remain out of scope.

### 2.10 Status is a projection of supervisor state

**Source.** BusyBrain exposes useful progress, usage, and child-run data, but spreads those facts
across Markdown, process state, logs, and provider responses. Herdr already separates current
state in `state.db`, history in `actions.jsonl`, code state in Git, and verifier output in evidence
artifacts. The status system reads those authorities instead of treating pane text or an agent's
completion claim as state.

**Invariant.** The Markdown TODO is an operator-friendly projection of requirements. It is not
the live status record. Its marks remain compact: `[ ]` is pending or ready, `[>]` is running,
verifying, reviewing, or waiting, `[x]` is verified and integrated, and `[!]` is blocked or
exhausted. Only the supervisor updates these marks from persisted state. §2.11 defines operator import;
a generated TODO is never polled as new input.

The live hierarchy is initiative, requirement, unit, attempt, and actor. An actor is a worker,
registered child, reviewer, or verifier job. Each actor records its parent, role, model, machine,
pane or process ID, state, start time, active time, wait time, last observation, last material
progress, current bounded action, next action, deadline, budget, and evidence references. A
registered child has its own lease and budget through §2.7 execution-layer registration. An unmanaged child remains part of the parent
attempt and cannot report independent completion or extend the parent's deadline.

Alive, active, and progressing are separate facts. Alive means that a process exists. Active
means that the actor owns a valid lease and remains within its deadline. Progressing means that
the candidate commit, verifier result, satisfied requirement, or validated blocker changed. A
status message updates `last_observed_at` but never `last_material_progress_at`.

The status interface uses separate closed records: `FleetStatus`, `InitiativeStatus`,
`UnitStatus`, `EscalationRecord`, and `RunRecord`. This amends §2.4. A normal status record cannot
use the escalation schema because healthy work has no failure class or recommended recovery
action. All human-readable views render these records, and every command offers the same data as
JSON.

The first interface is `herdr-master status`, `status --initiative <id>`, `status --unit <id>`,
`watch`, `history --unit <id>`, `diff --unit <id>`, and `evidence --unit <id>`. A dedicated status
pane may run the terminal interface, but agent panes remain execution contexts. Status never
comes from scraping their buffers.

The supervisor records usage around each mediated call or enforced session (§2.8). Unsupported
per-call attribution remains unavailable in reactive modes. A settled record includes the provider,
non-secret account fingerprint, model, role, initiative, unit, attempt, actor, input tokens,
output tokens, cached tokens, reservation, start and end times, and billing status. API cost uses
a versioned price schedule and remains `estimated` until provider billing reconciles it. A
subscription without per-call billing reports available tokens and quota use, not a fabricated dollar
amount. Missing usage is `unavailable`, never zero. Normalize disjoint billed categories: uncached
input, cache read, cache write by billing class, output, and other provider-priced categories.
Retain raw totals and overlap rules; never count cached tokens twice. Cost is the sum of category
quantities times matching versioned rates and units. A pricing-data task pins source, currency,
effective date, model revision, and category coverage, validates the initial schedule, and names
refresh ownership. An absent matching rate makes the estimate unavailable. Billing adjustments
retain their evidence rather than replace history.

A later read-only web viewer consumes the daemon's snapshot and event API. It owns no scheduler
state and no second database. It shows the dependency graph, actor tree, attempt timeline,
machine placement, waits, usage, Git changes, and verification evidence. It binds to loopback by
default and uses authenticated private access when viewed remotely. Scheduler controls remain out
of the first viewer release. Evidence downloads resolve authorized IDs rather than arbitrary
filesystem paths and enforce containment and redaction. Remote viewing requires a named private
transport/authentication install and live access test.

**Amends master plan §§2.4, 5, 7.4, 10.2, and the web-dashboard exclusion.** The exclusion narrows
to a write-capable or multi-operator dashboard. Read-only inspection is in scope after the CLI
status contract ships.

**Lands as.** `herdr_master/status.py` builds typed snapshots from SQLite, Git, run records, and
evidence artifacts. `herdr_master/events.py` records events in the same SQLite transaction as
state transitions. Snapshots carry a revision; clients replay monotonic event IDs after it.
Duplicate delivery is idempotent and a retention gap requires a fresh snapshot. Test disconnect,
replay, and concurrent updates against CLI/viewer consistency. The optional viewer reads the same local API. It does not read pane buffers or write
supervisor state.

### 2.11 One intake creates requirements and schedulable work

**Lands as.** `herdr_master/intake.py` and `requirements.py`. A user supplies a plain goal,
repository or repositories, and an approved profile. The profile supplies default scope,
verification policy, model/host eligibility, and budgets. Missing choices that change scope,
authorization, or acceptance create a bounded clarification request and durable
`blocked(human_decision)`, not repeated model nudges.

Intake has a request ID and revision. Retrying a request cannot create another initiative.
Explicit authorized user requirements and decomposition take precedence over model proposals;
existing ratified requirements persist unless an authorized revision changes them. A planner
proposes normalized requirements and units; the supervisor validates them before an atomic
SQLite insert. Planning/replanning calls use the same quota and initiative budgets as execution.

Store stable requirement IDs, acceptance criteria, verification-policy/check IDs, unit mappings,
dependencies, required capabilities, scope, and the authorized goal revision. Every requirement
must map to a check or an explicit human acceptance decision. Reject missing references, cycles,
uncovered requirements, ambiguous repository identity, and units without an approved check policy.
Unsupported checks block for policy approval, never become generated shell authority. A failed
proposal may be replanned within a bounded count; exhaustion blocks with the rejected evidence.
A material scope or acceptance change requires user approval.

The local ready-set scheduler is part of intake delivery; §2.9 extends it with fleet placement.
It advances all dependency-ready units while capacity remains. No ready
work with unfinished requirements is not completion: report the dependency blockers or invalid
graph, and persist a next action or human escalation. Completion is a deterministic query, not a
worker claim. Every required item must be verified against the final integration candidate and
integrated, or explicitly waived by an authorized operator with identity, reason, and revision.
All final required pipeline checks must pass on each repository's integration SHA and policy.
A human-blocked or failed requirement keeps the initiative blocked or incomplete. Administrative
closure is a separate outcome and cannot render as successful completion. For the first release,
integration means the verified initiative branch and prepared PR set, not automatic PR merge.

Requirement status is derived from evidence and integration state. Replanning invalidates affected
mappings and evidence, preserves prior history, and never replenishes spent budget. Unaffected
evidence is reusable only when its immutable candidate/policy dependencies remain valid.

**Amends master plan §2.5 and this plan §§2.1, 2.3, 2.9, 2.10.** The authoritative input queue
remains the legacy standalone entry point until an explicit import migrates it. Import creates
stable SQLite requirements and units under an idempotent request ID and records its source hash.
After migration, Markdown is a generated projection, not a second editable authority. Operator
edits use an explicit revision-checked import/update command; reject stale imports and agent-made
completion changes. Do not automatically reimport the generated file. Packets read remaining work
from SQLite for imported initiatives and legacy queue lines only for unmigrated standalone work.
Initiative completion overrides the legacy rule that all quarantined items imply a done run.

Design Markdown remains versioned rationale; implementation TODOs track engineering work.
Capability grids and council reports are dated evidence, not runtime authority. Retain historical
reviews with the source version they audited. Do not inject the entire document collection into
every worker packet or create per-attempt plan/TODO files.

### 2.12 Real application verification is a required contract

**Lands as.** `herdr_master/verification.py` and a policy-owned REST/browser runner.
Rewrite the small scenario vocabulary; no BusyBrain executable module is imported.
Each versioned verification profile names approved lint, unit, build, integration, REST, and
browser check IDs, dependencies, cwd, timeout, service lifecycle, and required host capabilities.
Projects may explicitly mark inapplicable gates with an authorized reason; missing required
tools, tests, or services are not successful skips.

A service specification supplies approved start/readiness/stop operations, loopback base URLs,
leased ports, isolated data fixtures, test identity/secret references, and allowed egress.
Start the exact candidate's backend/frontend, wait for readiness within a deadline, and verify
service instance identity against candidate, policy, and attempt. Never attach to an unrelated
already-running server merely because its port responds.

REST scenarios assert method, endpoint, status, schema, and observable state changes. Browser
scenarios navigate, click, fill, and assert state through the real application. Correlate each
required action with its expected REST method, endpoint, payload constraints, response, and
independent backend-state observation. UI text or a screenshot alone is not action correctness.
Assert forbidden/unexpected requests where the scenario requires them. Generated HTML, mock
backends, and portal state cannot substitute for a real-app gate. An unavailable app fails.

Pin runner/package and browser executable revisions and host dependencies in an approved
verification profile. Acquire and live-probe them before advertising a machine as browser-capable.
Test credentials use scoped fixture accounts and supervisor secret references; do not place them
in prompts, traces, or screenshots without required redaction. Visual regression is separately
opt-in and does not replace action correctness.

Each result binds check ID, repository, base/candidate SHAs, policy hash, service-instance ID,
command/runner version, exit, duration, and content-addressed evidence. Capture bounded and
redacted network, console, screenshot, and failure artifacts. Always stop owned services and
clean fixtures and leased ports, including on cancel or crash. Persist cleanup obligations so
startup reconciliation can finish them. Cleanup failure is a visible blocked resource state.

Integration creates a new candidate: rerun affected checks after unit integration and the full
required pipeline on the final integration candidate. Cross-machine checks fetch that exact
candidate and policy; a result for another tuple cannot satisfy the gate.

**Amends master plan §6.** Project exit codes remain evidence for approved commands, but every
required profile gate and requirement mapping must be satisfied before completion. Acceptance
includes wrong REST target/payload, missing backend mutation, absent app, stale server, omitted
required test, leaked service after crash, and synthetic fallback. All must fail closed.

### 2.13 The supervisor enforces proportional design quality

**Lands as.** `herdr_master/design.py`, design records in SQLite, and architecture checks
registered in the §2.12 verification policy. This is a required lifecycle gate, not a request
that a worker judge its own code. It does not guarantee optimal architecture.

For substantial work, intake assigns a separate architect actor before implementation. The
actor schema gains `architect` and `architecture_reviewer` roles with the same persisted leases,
budget attribution, and recovery rules as other supervised actors. The
versioned design record identifies requirement revision, scope, affected interfaces, component
ownership, allowed dependencies, failure behavior, existing code to reuse, simplest viable
alternative, and the reason for each chosen abstraction or pattern. A documented choice to use
no pattern is valid. The worker packet carries the applicable approved design revision and
constraints, not the complete archive of design prose.

The approved profile defines substantial work by observable triggers such as a new module
boundary, public interface, persistent state, concurrency, provider adapter, or dependency.
Small changes may reuse an applicable approved design with a recorded applicability check.
A model cannot exempt its own change merely by calling it small. Missing policy or an ambiguous
classification takes the full design gate or requests an authorized decision. Architectural
changes affecting product scope, permissions, or acceptance require operator approval.

Design review checks whether the proposed structure solves the actual problem, reuses appropriate
existing components, and avoids unnecessary abstraction. Design approval is recorded against the
requirement and policy revisions by an actor independent of the implementer. The supervisor
validates record completeness and approved authority; it does not treat a pattern name as proof.

Recommended applications are Adapter for provider integrations, Strategy for interchangeable
placement policies, typed Command for approved checks, explicit state transitions for lifecycle,
and committed events for status subscribers. Choose functions or data types where sufficient;
neither inheritance nor a named GoF pattern is mandatory. Durable leases, fencing, and atomic
event publication remain separate distributed-systems obligations under §§2.7-2.10.

Implementation gates combine deterministic tests and an independent architecture review:

- Check forbidden dependency directions, cycles, and provider-specific imports outside adapters.
- Run shared behavioral contract tests for every declared supported adapter.
- Verify the state, authorization, and ownership invariants selected by the design contract.
- Compare the actual candidate diff with that contract; review duplicated responsibilities,
  unjustified abstractions, interface changes, and failure paths.
- Use complexity/duplication metrics as review signals unless an approved policy gives a
  justified enforceable threshold. Never require pattern counts or class counts as quality proof.

Each check and architecture verdict records the repository/base/candidate/policy tuple plus
design and requirement revisions. A changed tuple or revision invalidates affected approval.
The reviewer sees the actual code delta and approved design, not the worker's self-evaluation.
Findings require a location, violated constraint or concrete consequence, and proposed correction.
Objective violations use typed confirmation under §2.2. Unconfirmable judgments follow its
escalation policy; a subjective concern cannot become an endless automatic rewrite loop.

Persist design and review operations with actor, status, deadline, budget, evidence, and next
action. Use explicit pending, running, approved, changes-requested, inconclusive, and waived
outcomes. Missing or failed review is not approval. Bounded recovery uses G; model calls and
quota waits use H. A waiver requires authorized operator identity, reason, scope, revision, and
expiry where appropriate; it cannot override non-waivable safety or authorization policies.

The integration gate requires applicable design approval, passing architecture checks, and
candidate-bound independent review, or a valid explicitly permitted waiver. Integrated changes
receive the same applicable checks on the combined candidate so independently acceptable units
cannot violate the shared architecture after assembly. J shows design/check/review state,
violations, attempts, waits, waivers, and evidence separately from functional test status.

**Amends master plan §6 and this plan §§2.1, 2.2, 2.7, 2.10-2.12.** Design approval precedes
substantial implementation; architecture evidence precedes integration and completion.
Acceptance tests cover forbidden imports, incompatible adapters, unjustified worker exemption,
worker self-approval, missing review, reviewer crash/quota pause, stale design or candidate,
expired waiver, and an integrated dependency cycle. Each must block the appropriate transition.

## 3. What is deliberately not taken

Each item names why, so that nobody reopens it without new evidence.

- **The Slack bridge and the Cursor adapters.** Herdr is the interface plane. The operator's
  input channel is §2.11 intake, explicit queue import, and `herdr-master ack`, the output channel is `herdr-master
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
- **The domain registry and disposition registry.** Herdr uses approved intake, queue, and verification profiles, not
  an unbounded domain classifier.
- **A new schema dependency by default.** Keep the standard-library implementation unless a
  separate dependency decision justifies change. Shared validation helpers must cover types,
  required fields, closed objects, and cross-field constraints, with negative fixtures.

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
| §2.7  | 3.7 and 5.3                 | Phase 3 dispatch, attempt close, and verifier   |
| §2.8  | 3.7 and 9.3                 | §2.7 waiting and wake transitions               |
| §2.9  | 6 (multi-machine fleet)     | §2.7 leases and §2.8 quota admission            |
| §2.10 | 7.4, then a read-only viewer | §§2.6-2.9 and §2.11 state and actor producers |
| §2.11 | Local initiative release | Phase 3 lifecycle, §2.8 admission for planner calls |
| §2.12 | Local verification release, then fleet | §2.2 candidate identity and approved profiles |
| §2.13 | Planning and pre-integration gate | K design records; B/C/L contracts; G/H recovery and admission |

Phase labels identify integration points, not a strictly numerical execution order. Deliver a
local vertical slice first: A/B and the master daemon; F/G durable lifecycle; H supported-mode
admission; K intake (§2.11) and C/L verification (§§2.2/2.12); then I fleet placement. J's local
CLI can use the single-machine subset before fleet work, while its viewer follows the shared
snapshot/event contract. M adds design records during K planning, packet constraints in B, and
architecture checks/review in C/L before integration. Deployment and visual regression remain deferred.

## 5. How the merge proves itself

Each piece ends in a unit test in `herdr_master/`. The following pieces also need a live run on the
throwaway repo `attempt_prototype.sh` used, because a unit test cannot show that an agent
behaves differently:

- **§2.1.** A packet rendered from the template drives one attempt to `MC-DONE` and one to a
  valid `blockers.json`, repeating the 2026-09-12 results with no heredoc in the driver.
- **§2.2.** Plant a defect the verifier cannot see, a leftover debug print with tests still
  green, and show that the reviewer emits an `absence` finding, that the supervisor confirms it
  with the typed literal-search adapter, and that the next attempt removes it. Then plant a design
  defect and show that a `judgment` finding escalates instead of looping. Reject arbitrary commands;
  simulate a check timeout, outbound secret, changed candidate, and oversized diff without approval.
- **§2.7.** Run workers that exit early, lose their pane, freeze with an idle process tree, and
  return only a progress summary. Each case must close the attempt and continue automatically.
  Crash the daemon before and after lease, dispatch, close, verify, and wake transitions. Each
  restart must converge without duplicate work.
- **§2.8.** Simulate 94.9 percent, 95 percent, multiple concurrent reservations, an unknown billed
  timeout, daemon restart during a pause, duplicate wake timers, and a reset time that passes
  without capacity returning. No case may oversubscribe the recorded pool or spend a retry.
- **§2.9.** Route units across two throwaway machine profiles, reject an ineligible host, relocate
  a closed attempt by exact commit, reject a late result from the old fencing epoch, integrate two
  independent units, and serialize two units with overlapping scope.
- **§2.10.** Run two registered workers and one verifier across two machines. Confirm that the CLI,
  JSON snapshot, TODO projection, event stream, and viewer report the same state. A chatty stalled
  worker must remain alive and active but stop progressing. Token totals must reconcile to settled
  provider records where available; unsupported token fields and subscription cost stay unavailable.

- **§2.11.** Start from one plain goal, create requirements and dependency-ready units, interrupt
  a worker, and complete all remaining work automatically. A blocked requirement prevents success;
  duplicate imports, stale revisions, cycles, and missing checks are rejected.
- **§2.12.** Run the real candidate frontend and backend. Prove the expected REST request and
  backend mutation; fail wrong target/payload, unavailable app, stale server, and synthetic fallback.
  Kill the runner mid-scenario and prove restart cleanup releases services, fixtures, and ports.

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

4. **Remote transport must pass the master plan Phase 6 round-trip test.** BusyBrain runs every
   agent on the Mac Studio and uses Ansible only to deploy. Herdr still must choose and verify
   `herdr --remote` or `ssh` before §2.9 can route or relocate work. Live process and terminal
   migration remain excluded. Attempt-boundary relocation is part of this merge.
5. **Each supported worker kind needs an admission/usage adapter or an explicit reactive-only policy.** The
   daemon can claim projected quota enforcement only with compatible window units and an enforced
   call/session boundary. Percentage-only telemetry supports an observed threshold, not a strict
   projected reservation guarantee. A failed or unknown probe pauses by default and must not mean that capacity is
   available.

## Revision log

- **2026-09-13.** Added §2.13 supervisor-enforced design quality and roadmap Piece M. Imported
  historical review evidence under `inventory/reviews/` and added `guides/building-herdr.md`.

- **2026-09-13.** Applied the capability-grid council findings: typed candidate-bound review,
  durable records and recovery, supported-mode quota admission, intake/completion, real-app gates,
  and explicit actor, pricing, and runtime producers. See `merge-busybrain-herdr-council-resolution.md`.

- **2026-09-13.** Added typed status projections, registered actor visibility, token and cost
  evidence rules, a derived TODO view, and a read-only web viewer.
- **2026-09-13.** Added durable liveness recovery, quota reservations and 95 percent pause, and
  capability-based machine routing with attempt-boundary relocation.
- **2026-09-13.** First version, from the comparison of `~/Developer/busybrain` against the
  master plan and `herdr_master/` at commit `ab3fac6`.
