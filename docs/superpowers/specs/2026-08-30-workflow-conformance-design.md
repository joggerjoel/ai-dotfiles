# workflow-conformance — an evidence-audited gate on the skills playbook

**Date:** 2026-08-30
**Status:** built, evaluated, **not promoted**. Three blind eval rounds failed the
acceptance criterion below. The branch was deleted; `skills/workflow` on main
keeps the routing and non-negotiables without the gate. Kept as the design
record and for the findings in
`docs/superpowers/evals/2026-08-30-conformance-eval.md`, which are the durable
output of this work.

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
policy source (varies)        ──▶ which step each phase requires   (policy)
skills/workflow-conformance/  ──▶ what evidence proves it happened (mechanism)
```

The skill embeds no phase content. It is one engine over a pluggable policy.
Editing a policy updates enforcement on every machine `setup.sh` deploys to.
Nothing is duplicated, so nothing can disagree.

Evidence classes are stable across policy revisions. Routing tables change; what
proves a verify happened does not. That stability is what makes one engine
sufficient for more than one policy.

### Policy resolution

Triage resolves exactly one policy and records which, in this order:

1. `poteto-mode` active, with a matched playbook → **that playbook's steps**,
   copied verbatim, are the audited list.
2. A project-local `workflow-skills.md` → its phases. The machine-wide playbook
   already grants project-local files precedence.
3. Otherwise `references/workflow-skills.md`, phases 1 through 6.

Ambiguity is resolved by recording the choice, not by guessing silently. If no
policy resolves, that is a FAIL, not a pass.

### poteto-mode interoperation

`poteto-mode` is a second routing authority with its own playbooks, and it wins
when it is on. Three consequences:

**It cannot be invoked.** Its frontmatter sets `disable-model-invocation: true`,
so only the user turns it on. Conformance detects and adapts; it never calls it.

**Its todolist replaces the step list, not the evidence record.** poteto
already requires the matched playbook's steps copied verbatim, and already
requires that a skipped step remain in the list as `skip: <reason>`.
Conformance does not keep a second step list — the todolist is the one true
list of steps. But the ledger file is still written under poteto-mode: it
holds the evidence for each step, keyed to the todolist's step names, and it
is what the auditor reads. Conformance audits the `skip:` reasons against that
evidence. A `skip:` whose reason the evidence contradicts is a FAIL.

**Its subagent defaults apply.** Inside poteto-mode the auditor spawns per that
skill's Subagents section rather than on this design's Haiku default.

### Four components

**Triage** runs as the first action of any task. It classifies the task
TRIVIAL, SMALL, or TRACKED and writes the verdict with a reason. A TRIVIAL or
SMALL claim is recorded, not silent — a false one stays visible in the record
afterward. Trivial tasks cost one line and no subagents, which preserves the
playbook's own rule that mechanical work gets no ceremony. SMALL tasks cost
two auditor spawns — Verify and Ship only — so bounded work with a real test
surface draws proportionate ceremony instead of full.

**Ledger.** One append-only markdown file per run at
`.claude/conformance/YYYY-MM-DD-<slug>.md`, gitignored. Each phase records the
route chosen, the skills invoked, the evidence, and the auditor's reply pasted
verbatim. A verdict the agent typed is not a verdict, and a PASS that names no
evidence is not a PASS.

**Auditor.** A subagent on Haiku 4.5 with fresh context. It receives the ledger
entry, the matching rubric section, and the relevant policy row or step in
force. It does not receive the conversation, so it cannot inherit the
reasoning that produced the gap.

**Gate.** Phase N+1 does not begin until phase N records a PASS.

### The load-bearing rule

The auditor grades evidence, not claims. "Ran verify" fails. Pasted `just
verify` output covering typecheck, test, lint and build passes. This one rule
converts shallow work from undetectable into blocking, and it is the reason the
auditor needs a separate context rather than a longer checklist.

### Phase rubrics

| Phase      | Auditor must see                                                                                                                                       | Auto-FAIL                                                                                                  |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| 1 · Route  | Task shape named, lane chosen, playbook row quoted verbatim                                                                                            | Route contradicts shape; no policy row or step cited                                                       |
| 2 · Build  | Skills invoked by name; for logic changes, failing-test output timestamped before the implementation diff; design-stack skills named if UI was touched | Test written after implementation; UI diff with no design skill; TDD claimed with no red-phase output      |
| 3 · Verify | Raw command output. Typecheck, test, lint and build each run, or marked N/A with a reason                                                              | Any of the four silently absent; summarized instead of pasted; non-zero exit described as "mostly passing" |
| 4 · Review | Diff enumerated by file and line count, `no-comments` pass, `review-changes` findings or an explicit "none" with what was checked                      | Review claimed without the diff enumerated; findings raised and left unresolved                            |
| 5 · Ship   | verify-step PASS on record (Phase 3 under the default policy, or its mapped equivalent), commit message, secrets and `.gitignore` check                | Any commit with no verify-step PASS above it in the ledger                                                 |
| 6 · Learn  | Recorded if done                                                                                                                                       | Non-blocking                                                                                               |

Phase 0 is not audited. Loading context is not work, and gating on it would fire
every session. Phase 6 never blocks: a retrospective that prevents shipping is
worse than a missed retrospective.

### Auditor contract

- **Input:** ledger entry, rubric section, policy row or step in force. No conversation history.
- **Output:** `PASS: <the specific evidence seen, named>`, or `FAIL: <specific
missing evidence>`. Prose that matches neither form — including a bare
  `PASS` with no evidence named — is rejected and the call is retried once.
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

This escalation overrides `principle-never-block-on-the-human`, which is
otherwise in force under poteto-mode. That principle governs reversible work the
agent could simply attempt. A twice-failed audit is not a choice the agent
declined to make; it is a capability the environment does not have. Supplying it
is the user's call. The override is deliberately narrow: two FAILs on one step,
nothing else.

## Acceptance

The skill is prose, so it has no unit tests. Two checks, both of which already
exist in this repo or its skills:

**Structural.** `just fix-skills` — frontmatter `name` matches the directory and
every `references/<file>` link resolves. This is the validation step
`poteto-mode/playbooks/authoring-a-skill.md` requires.

**Behavioural.** A blind eval per `poteto-mode/playbooks/eval.md`. Candidates run
an organic-looking task with and without the skill installed; the rubric is held
back from candidates; chain-following is graded from transcripts and code shape,
never from self-report. This is the only honest way to show the skill changes
behaviour rather than merely reading well, and its central rule is the same one
the auditor enforces: what an agent claims it did is not evidence it did it.

Promotion criterion: the skill ships only if the eval shows the with-skill arm
catching a gap the without-skill arm shipped.

## Cost

Roughly five short subagent calls per tracked task. SMALL tasks cost two —
Verify and Ship only. Trivial tasks cost one triage line.

## Boundaries against neighbouring skills

`unlazy` asks whether the task is done. This asks whether the process was
followed. A task can pass every acceptance gate while skipping review and
shipping unverified, so the two are not substitutes. `unlazy` also stays
dependency-free, which the playbook's portability analysis names as its main
virtue; folding conformance into it would cost that.

`show-me-your-work` records a decision trail. The ledger records evidence and a
verdict. The trail explains choices; the ledger proves work.

`poteto-mode` is a policy, not a competitor. It says which steps a task owes;
this says whether they were paid. It also self-enforces by requiring `skip:
<reason>` on omitted steps, but that reason is self-reported, which is the
failure mode this design exists to close. Conformance audits the reasons.

## Deployment

Lives at `skills/workflow-conformance/SKILL.md` in `ai-dotfiles`, deployed by
`setup.sh` like every other skill in `skills/`. `.claude/conformance/` is added
to `.gitignore`.

## The TRIVIAL and SMALL thresholds

TRIVIAL requires all four to hold. Any one failing drops the task to SMALL,
not straight to TRACKED:

1. No behaviour change a test could observe. Typos, comments, formatting,
   docs, renames confined to one file.
2. One file.
3. No dependency, config, schema, auth or CI change, at any size.
4. Reversible by `git revert` with no coordination.

SMALL requires all four to hold. Any one failing makes the task TRACKED:

1. Three files or fewer.
2. A test target already exists — the change does not have to create the
   project's test infrastructure.
3. No dependency, config, schema, auth or CI change, at any size.
4. Reversible by `git revert` with no coordination.

SMALL differs from TRIVIAL in permitting an observable behaviour change, and
from TRACKED in requiring bounded size plus an existing test surface. SMALL
audits only Verify and Ship — the two phases where evidence is cheap to
produce and a miss is expensive — leaving Route, Build, Review and Learn
unaudited for that tier.

Triage may perform the minimum exploration needed to judge these criteria
honestly — enough to know the file count and whether config/schema/CI is in
scope, no more. That is not the exploration a TRACKED task owes; it is only
enough to classify.

**Re-triage.** A TRIVIAL or SMALL verdict is not final. If later exploration
contradicts it, the ledger records the upgrade with the reason — TRIVIAL to
SMALL, TRIVIAL to TRACKED, or SMALL to TRACKED. Every phase already elapsed
under the lower tier is now owed an audit before the run proceeds — submit
its evidence and get PASS, or restart at Route if that evidence was never
captured — so upgrading is never cheaper than having classified correctly at
the start.

Build's red-before-green ordering cannot be produced retroactively on a
restart, since the implementation already exists. On any upgraded run —
TRIVIAL to SMALL, TRIVIAL to TRACKED, or SMALL to TRACKED — Build's evidence
is instead the tests that now exist and pass, plus a ledger note that the run
was upgraded and red-phase evidence was unavailable. That note is itself the
evidence of what happened, and the auditor grades it rather than deadlocking.
This exception applies only to upgraded runs — a run TRACKED from the start
still owes red-before-green.

The thresholds are deliberately strict. A task wrongly marked TRACKED costs
five Haiku calls, or two under SMALL; one wrongly marked TRIVIAL or SMALL
costs the guarantee the system exists to provide. The same cost applies from
the other direction: ceremony an agent judges disproportionate gets refused
outright, which costs the guarantee just as completely, and that is the
reason SMALL exists — to keep refusal from being the rational choice on
ordinary small work. Tune from the ledgers, in the direction of stricter.
