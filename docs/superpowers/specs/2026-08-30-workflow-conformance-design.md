# workflow-conformance — an evidence-audited gate on the skills playbook

**Date:** 2026-08-30
**Status:** approved, not yet implemented

## Problem

`references/workflow-skills.md` defines a six-phase workflow: route, build,
verify, review, ship, learn. It is 308 lines of policy with no mechanism. The
playbook states what should happen and has no way to notice when it doesn't.

Four failure modes were confirmed, all of them observed:

1. **Skipped phases.** Straight to code with no route decided; commits with no
   verify run.
2. **Shallow steps.** The skill is invoked and its checklist skimmed. "Ran
   verify" when only typecheck ran. "Reviewed" without the diff ever being read.
3. **Wrong route.** A bug routed as a feature. `quick-commit` on a risky change.
   No `council` on a high-stakes spec.
4. **Silent drift.** Long runs start on-playbook and shed later phases as
   context fills.

Modes 1, 3 and 4 are detectable from a record. Mode 2 is not, because the agent
that skimmed the step is the same agent reporting on it. Self-attestation
cannot catch self-deception, which rules out an advisory skill.

## Root cause

Skills are prose, and prose is subject to rationalization by the model reading
it. `superpowers:using-superpowers` already carries a red-flag table for exactly
this reason. Enforcement that survives requires either a hook, which cannot read
evidence quality, or a separate context, which can.

## Design

### One direction, one seam

```
references/workflow-skills.md  ──▶ which skill each phase requires  (policy)
skills/workflow-conformance/   ──▶ what evidence proves it happened  (mechanism)
```

The skill embeds no phase content. At triage it reads the playbook, preferring a
project-local `workflow-skills.md` when one exists, exactly as the playbook
already specifies. Editing the playbook updates enforcement on every machine
`setup.sh` deploys to. Nothing is duplicated, so nothing can disagree.

Evidence classes are stable across playbook revisions. Routing tables change;
what proves a verify happened does not.

### Four components

**Triage** runs as the first action of any task. It classifies the task TRIVIAL
or TRACKED and writes the verdict with a reason. A TRIVIAL claim is recorded,
not silent — a false one stays visible in the record afterward. Trivial tasks
cost one line and no subagents, which preserves the playbook's own rule that
mechanical work gets no ceremony.

**Ledger.** One append-only markdown file per run at
`.claude/conformance/YYYY-MM-DD-<slug>.md`, gitignored. Each phase records the
route chosen, the skills invoked, the evidence, and the audit verdict.

**Auditor.** A subagent on Haiku 4.5 with fresh context. It receives the ledger
entry, the rubric row, and the relevant playbook section. It does not receive
the conversation, so it cannot inherit the reasoning that produced the gap.

**Gate.** Phase N+1 does not begin until phase N records a PASS.

### The load-bearing rule

The auditor grades evidence, not claims. "Ran verify" fails. Pasted `just
verify` output covering typecheck, test, lint and build passes. This one rule
converts shallow work from undetectable into blocking, and it is the reason the
auditor needs a separate context rather than a longer checklist.

### Phase rubrics

| Phase      | Auditor must see                                                                                                                                       | Auto-FAIL                                                                                                  |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| 1 · Route  | Task shape named, lane chosen, playbook row quoted verbatim                                                                                            | Route contradicts shape; no row cited                                                                      |
| 2 · Build  | Skills invoked by name; for logic changes, failing-test output timestamped before the implementation diff; design-stack skills named if UI was touched | Test written after implementation; UI diff with no design skill; TDD claimed with no red-phase output      |
| 3 · Verify | Raw command output. Typecheck, test, lint and build each run, or marked N/A with a reason                                                              | Any of the four silently absent; summarized instead of pasted; non-zero exit described as "mostly passing" |
| 4 · Review | Diff enumerated by file and line count, `no-comments` pass, `review-changes` findings or an explicit "none" with what was checked                      | Review claimed without the diff enumerated; findings raised and left unresolved                            |
| 5 · Ship   | Phase 3 PASS on record, commit message, secrets and `.gitignore` check                                                                                 | Any commit with no Phase 3 PASS above it                                                                   |
| 6 · Learn  | Recorded if done                                                                                                                                       | Non-blocking                                                                                               |

Phase 0 is not audited. Loading context is not work, and gating on it would fire
every session. Phase 6 never blocks: a retrospective that prevents shipping is
worse than a missed retrospective.

### Auditor contract

- **Input:** ledger entry, rubric row, playbook section. No conversation history.
- **Output:** `PASS`, or `FAIL: <specific missing evidence>`. Prose that matches
  neither form is rejected and the call is retried once.
- **Standing instruction:** default to FAIL. Ambiguous, summarized or
  self-reported evidence is not evidence. A false PASS is the failure this
  system exists to prevent.
- **Model:** Haiku 4.5. Checklist matching does not need a larger model, and a
  cheap auditor is one that stays enabled. An expensive one gets disabled, and a
  disabled auditor enforces nothing.

### Failure handling

A FAIL sends the agent back to remediate and resubmit. Two FAILs on the same
phase stop the run and escalate, quoting the auditor's reasons. Repeated failure
on one phase usually means the step is structurally blocked — no lint script
exists, no test target — and that is a decision for the user, not a loop to
spend tokens in.

## Cost

Roughly five short subagent calls per tracked task. Trivial tasks cost one
triage line.

## Boundaries against neighbouring skills

`unlazy` asks whether the task is done. This asks whether the process was
followed. A task can pass every acceptance gate while skipping review and
shipping unverified, so the two are not substitutes. `unlazy` also stays
dependency-free, which the playbook's portability analysis names as its main
virtue; folding conformance into it would cost that.

`show-me-your-work` records a decision trail. The ledger records evidence and a
verdict. The trail explains choices; the ledger proves work.

## Deployment

Lives at `skills/workflow-conformance/SKILL.md` in `ai-dotfiles`, deployed by
`setup.sh` like every other skill in `skills/`. `.claude/conformance/` is added
to `.gitignore`.

## The TRIVIAL threshold

TRIVIAL requires all four to hold. Any one failing makes the task TRACKED:

1. No behaviour change a test could observe. Typos, comments, formatting,
   docs, renames confined to one file.
2. One file.
3. No dependency, config, schema, auth or CI change, at any size.
4. Reversible by `git revert` with no coordination.

The threshold is deliberately strict. A task wrongly marked TRACKED costs five
Haiku calls; one wrongly marked TRIVIAL costs the guarantee the system exists
to provide. Tune from the ledgers, in the direction of stricter.
