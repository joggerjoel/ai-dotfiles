# workflow-conformance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a skill that gates each phase of whichever workflow playbook is in force behind a fresh-context auditor that grades evidence rather than claims.

**Architecture:** One enforcement engine over a pluggable policy. Triage resolves the policy (poteto-mode playbook, project-local `workflow-skills.md`, or the machine-wide one) and classifies the task TRIVIAL or TRACKED. Tracked tasks write an append-only ledger; each phase is audited by a Haiku subagent that sees only the ledger entry, the rubric row, and the policy section. Phase N+1 is blocked until phase N records PASS.

**Tech Stack:** Markdown skill under `skills/`, deployed by `setup.sh install_skills`. Validation via the existing `just fix-skills` recipe. Behavioural acceptance via a blind eval per `skills/poteto-mode/playbooks/eval.md`.

**Spec:** `docs/superpowers/specs/2026-08-30-workflow-conformance-design.md`

## Global Constraints

- Skill directory name and frontmatter `name` must be identical: `workflow-conformance`. `just fix-skills` fails otherwise.
- Every `references/<file>` link in `SKILL.md` must resolve on disk. `just fix-skills` checks this, ignoring fenced code blocks.
- Skill lives at `skills/workflow-conformance/` in `ai-dotfiles`. Do not write to `~/.claude/skills/` by hand; `setup.sh` copies it there.
- Auditor model id: `claude-haiku-4-5-20251001`.
- Ledger path: `.claude/conformance/YYYY-MM-DD-<slug>.md`, gitignored.
- Auditor output grammar is exactly `PASS` or `FAIL: <reason>`. Nothing else is a valid verdict.
- Prose follows `unslop`. Agent-facing prose earns its keep by changing a decision; delete sentences that do not.
- `poteto-mode` sets `disable-model-invocation: true`. Never invoke it. Detect it only.
- Commit after each task. `docs/` is gitignored in this repo but specs and plans are tracked anyway, so `git add -f` is required for files under `docs/`.

---

### Task 1: Skill skeleton that passes structural validation

**Files:**

- Create: `skills/workflow-conformance/SKILL.md`
- Test: `just fix-skills` (existing recipe, `justfile:355`)

**Interfaces:**

- Consumes: nothing.
- Produces: the skill directory and frontmatter `name: workflow-conformance` that every later task appends to.

- [ ] **Step 1: Run the validator to see the current state**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills
```

Expected: `✓ every skill: frontmatter name matches directory, all references resolve`. This is the green baseline. Any pre-existing failure must be resolved before starting, otherwise you cannot tell your own breakage apart from someone else's.

- [ ] **Step 2: Create the skill with a deliberately wrong name to prove the validator bites**

```bash
mkdir -p ~/Developer/ai-dotfiles/skills/workflow-conformance
```

Write `skills/workflow-conformance/SKILL.md`:

```markdown
---
name: wrong-on-purpose
description: temporary
---

# placeholder
```

- [ ] **Step 3: Run the validator and confirm it fails**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills
```

Expected: `✘ workflow-conformance: frontmatter name 'wrong-on-purpose' != directory` and a non-zero problem count. If this passes, the validator is not covering your new skill and every later validation step in this plan is worthless. Stop and fix the recipe first.

- [ ] **Step 4: Write the real frontmatter and skeleton**

Replace `skills/workflow-conformance/SKILL.md` entirely with:

```markdown
---
name: workflow-conformance
description: Use when a task is non-trivial enough to owe a workflow — routing, building, verifying, reviewing, shipping. Resolves which playbook is in force, records each phase's evidence to a ledger, and gates every phase behind a fresh-context auditor that grades evidence rather than claims. Invoke before the first substantive action of a task, not after.
---

# Workflow conformance

Playbooks say what should happen. This says whether it did.

The agent that skimmed a step is the same agent reporting on it, so
self-attestation cannot catch shallow work. Every phase is graded by a separate
context that never sees your reasoning.

## Triage

First action of any task, before exploring or editing.

Resolve the policy, in this order, and record which one won:

1. `poteto-mode` active with a matched playbook → that playbook's steps, verbatim.
2. A project-local `workflow-skills.md` → its phases.
3. Otherwise `~/.claude/references/workflow-skills.md`, phases 1 to 6.

No policy resolves → FAIL. Do not proceed on a guess.

Then classify. TRIVIAL requires all four:

1. No behaviour change a test could observe.
2. One file.
3. No dependency, config, schema, auth, or CI change, at any size.
4. Reversible by `git revert` with no coordination.

Any one failing makes the task TRACKED. The threshold is strict on purpose. A
task wrongly marked TRACKED costs five Haiku calls. One wrongly marked TRIVIAL
costs the guarantee.

Write the verdict and its reason to the ledger either way. A TRIVIAL claim is a
recorded assertion, not an exit.

## Ledger

One append-only file per run at `.claude/conformance/YYYY-MM-DD-<slug>.md`.

Per phase: route chosen, skills invoked, evidence, audit verdict.

## Audit

See [rubrics](references/rubrics.md) for what each phase must show, and
[the auditor prompt](references/auditor-prompt.md) for the contract.

Phase N+1 does not start until phase N records PASS.

## Red flags

| Thought                              | Reality                                     |
| ------------------------------------ | ------------------------------------------- |
| "This is obviously trivial"          | Then say so in the ledger, with the reason. |
| "The auditor will just slow me down" | It only blocks on missing evidence.         |
| "I'll paste the evidence later"      | Later is where the evidence stops existing. |
| "Close enough to a PASS"             | The auditor decides that, not you.          |
```

- [ ] **Step 5: Run the validator and confirm the name check passes but references fail**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills
```

Expected: two dead-reference failures, `references/rubrics.md` and `references/auditor-prompt.md`. The name error is gone. Those two files are Tasks 2 and 3; the failure is the plan working as intended.

- [ ] **Step 6: Commit**

```bash
cd ~/Developer/ai-dotfiles
git add skills/workflow-conformance/SKILL.md
git commit -m "conformance: the skill skeleton, triage, and ledger format"
```

---

### Task 2: Phase rubrics

**Files:**

- Create: `skills/workflow-conformance/references/rubrics.md`
- Test: `just fix-skills`

**Interfaces:**

- Consumes: the `references/rubrics.md` link written in Task 1.
- Produces: the rubric rows the auditor prompt in Task 3 quotes by phase name.

- [ ] **Step 1: Write the rubrics file**

Create `skills/workflow-conformance/references/rubrics.md`:

```markdown
# Phase rubrics

What the auditor must see. Evidence is raw output, file paths, and diff stats.
Prose describing work is not evidence of work.

These rows are policy-agnostic. Under poteto-mode the phase names come from the
matched playbook's steps; map each step to the closest row below by what it
produces, and audit the `skip: <reason>` line on any step the playbook lists but
the run omitted.

## 1. Route

Must see: task shape named, lane chosen, and the policy row quoted verbatim.

Auto-FAIL: the route contradicts the shape (a defect routed as a feature); no
row cited; the policy source not recorded.

## 2. Build

Must see: skills invoked by name. For logic changes, failing-test output
produced before the implementation diff. If UI was touched, the design-stack
skills named.

Auto-FAIL: test written after the implementation; a UI diff with no design
skill; TDD claimed with no red-phase output.

## 3. Verify

Must see: raw command output. Typecheck, test, lint, and build each either run
or marked N/A with a reason.

Auto-FAIL: any of the four silently absent; output summarised instead of pasted;
a non-zero exit described as "mostly passing".

## 4. Review

Must see: the diff enumerated by file and line count, a `no-comments` pass, and
`review-changes` findings — or an explicit "none" naming what was checked.

Auto-FAIL: review claimed without the diff enumerated; findings raised and left
unresolved.

## 5. Ship

Must see: a Phase 3 PASS already on record, the commit message, and a secrets
and `.gitignore` check.

Auto-FAIL: any commit with no Phase 3 PASS above it in the ledger.

## 6. Learn

Recorded if done. Never blocks.
```

- [ ] **Step 2: Run the validator**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills
```

Expected: one remaining failure, `✘ workflow-conformance: dead reference references/auditor-prompt.md`. The rubrics reference now resolves.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/ai-dotfiles
git add skills/workflow-conformance/references/rubrics.md
git commit -m "conformance: phase rubrics, keyed to evidence rather than claims"
```

---

### Task 3: The auditor contract

**Files:**

- Create: `skills/workflow-conformance/references/auditor-prompt.md`
- Test: `just fix-skills`

**Interfaces:**

- Consumes: `references/rubrics.md` from Task 2, by phase heading.
- Produces: the verdict grammar `PASS` / `FAIL: <reason>` that the gate in Task 4 branches on.

**Note for the implementer:** the standing instruction in Step 1 is a working
default, not a placeholder. The user has asked to tune this block themselves
because it calibrates the whole system. Ship the default, then surface it for
review before Task 6.

- [ ] **Step 1: Write the auditor prompt**

Create `skills/workflow-conformance/references/auditor-prompt.md`:

```markdown
# Auditor contract

Spawn one subagent per phase. Model `claude-haiku-4-5-20251001`, except inside
poteto-mode, where the Subagents section of that skill governs.

## Input

Exactly three things:

1. The ledger entry for this phase.
2. The matching row from `rubrics.md`.
3. The relevant section of the policy in force.

Never the conversation. An auditor that can see the reasoning inherits the
rationalisation.

## Output

`PASS`, or `FAIL: <specific missing evidence>`. Anything else is rejected and the
call retried once. A second malformed reply is a FAIL.

## Standing instruction

Default to FAIL.

Ambiguous, summarised, or self-reported evidence is not evidence. "Ran the
tests" is a claim. Pasted output with a pass count is evidence.

You are not being helpful by being lenient. A false PASS is the exact failure
this system exists to prevent, and it is worse than a false FAIL because it gets
recorded as proof.

Judge only what is in front of you. Do not infer that a step probably happened
because the surrounding work looks competent.
```

- [ ] **Step 2: Run the validator and confirm it is fully green**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills
```

Expected: `✓ every skill: frontmatter name matches directory, all references resolve`.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/ai-dotfiles
git add skills/workflow-conformance/references/auditor-prompt.md
git commit -m "conformance: auditor contract, defaulting to FAIL"
```

---

### Task 4: The gate and failure handling

**Files:**

- Modify: `skills/workflow-conformance/SKILL.md` (append after the `## Audit` section)
- Test: `just fix-skills`

**Interfaces:**

- Consumes: the verdict grammar from Task 3.
- Produces: the escalation behaviour the eval in Task 7 measures.

- [ ] **Step 1: Append the gate section**

In `skills/workflow-conformance/SKILL.md`, replace the `## Audit` section with:

```markdown
## Audit

See [rubrics](references/rubrics.md) for what each phase must show, and
[the auditor prompt](references/auditor-prompt.md) for the contract.

Phase N+1 does not start until phase N records PASS.

## When the auditor fails a phase

Remediate and resubmit. Two FAILs on the same phase stop the run. Escalate to
the user, quoting the auditor's reasons verbatim.

A twice-failed phase usually means the step is structurally blocked. No lint
script exists. No test target exists. That is a missing capability, not a
decision the agent declined to make.

This escalation overrides `principle-never-block-on-the-human`, which otherwise
governs under poteto-mode. That principle covers reversible work the agent could
simply attempt. Supplying an absent capability is the user's call. The override
is narrow: two FAILs on one step, nothing else.
```

- [ ] **Step 2: Validate**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills
```

Expected: still fully green. Both references still resolve.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/ai-dotfiles
git add skills/workflow-conformance/SKILL.md
git commit -m "conformance: gate the next phase, escalate after two failures"
```

---

### Task 5: poteto-mode interoperation

**Files:**

- Modify: `skills/workflow-conformance/SKILL.md` (append a section before `## Red flags`)
- Test: `just fix-skills`

**Interfaces:**

- Consumes: the triage policy order from Task 1.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Append the interop section**

Insert into `skills/workflow-conformance/SKILL.md`, immediately before `## Red flags`:

```markdown
## Under poteto-mode

poteto-mode wins when it is on. It sets `disable-model-invocation: true`, so only
the user turns it on. Detect it; never invoke it.

Its todolist is the ledger. poteto already requires the matched playbook's steps
copied in verbatim, and already requires an omitted step to stay in the list as
`skip: <reason>`. Do not keep a second list. Audit those reasons.

A `skip:` reason the evidence contradicts is a FAIL. "skip: no UI surface" fails
when the diff touches a UI file.
```

- [ ] **Step 2: Validate**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills
```

Expected: fully green.

- [ ] **Step 3: Commit**

```bash
cd ~/Developer/ai-dotfiles
git add skills/workflow-conformance/SKILL.md
git commit -m "conformance: audit poteto's skip reasons instead of duplicating its list"
```

---

### Task 6: Wire it into the repo and the fleet

**Files:**

- Modify: `.gitignore` (append one line)
- Modify: `references/workflow-skills.md` (two edits: §3a table row, §5 TL;DR card)
- Test: `just fix-skills`, plus a deploy check

**Interfaces:**

- Consumes: the finished skill from Tasks 1 to 5.
- Produces: the deployed copy at `~/.claude/skills/workflow-conformance/` that the eval in Task 7 requires.

- [ ] **Step 1: Confirm the ledger directory is not already ignored**

```bash
cd ~/Developer/ai-dotfiles && grep -n "conformance" .gitignore
```

Expected: no output. If a line already exists, skip Step 2.

- [ ] **Step 2: Ignore the ledger directory**

Append to `.gitignore`:

```
.claude/conformance/
```

- [ ] **Step 3: Register the skill in the playbook's disposition table**

In `references/workflow-skills.md` §3a, add this row directly beneath the
`superpowers:using-superpowers` row:

```markdown
| workflow-conformance | CORE | Gates each phase behind an evidence auditor; policy is whichever playbook is in force |
```

- [ ] **Step 4: Add it to the TL;DR card**

In `references/workflow-skills.md` §5, inside the fenced block, add this line
directly beneath the `Trivial:` line:

```
Non-trivial:     workflow-conformance triages first, then the loop below
```

- [ ] **Step 5: Validate and deploy**

```bash
cd ~/Developer/ai-dotfiles && just fix-skills && ./setup.sh update --no-pull
```

Expected: `fix-skills` green, and `setup.sh` reporting an installed skill count.

`--no-pull` is required, not optional. Plain `setup.sh update` git-pulls before
re-applying config (`setup.sh:1389`), which would rebase your in-progress work.
`--no-pull` re-applies from the working tree as it stands.

- [ ] **Step 6: Verify the deployed copy exists and matches**

```bash
diff -r ~/Developer/ai-dotfiles/skills/workflow-conformance ~/.claude/skills/workflow-conformance && echo "DEPLOYED CLEAN"
```

Expected: `DEPLOYED CLEAN`. `setup.sh install_skills` copies rather than symlinks, so a stale copy is possible and this is the only check that catches it.

- [ ] **Step 7: Confirm no ledger files are staged**

```bash
cd ~/Developer/ai-dotfiles && git status --short | grep conformance
```

Expected: only `.gitignore` and `references/workflow-skills.md` modifications. No `.claude/conformance/` paths. If any appear, the ignore rule is wrong.

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/ai-dotfiles
git add .gitignore references/workflow-skills.md
git commit -m "conformance: register the skill in the playbook and ignore its ledgers"
```

---

### Task 7: Blind behavioural eval and the promotion decision

**Files:**

- Create: `docs/superpowers/evals/2026-08-30-conformance-eval.md` (results, written at the end)
- Test: the eval itself

**Interfaces:**

- Consumes: the deployed skill from Task 6.
- Produces: the promote-or-revert verdict. Nothing depends on this task; it decides whether the previous six survive.

This task follows `skills/poteto-mode/playbooks/eval.md`. Read it in full first.
Its blinding rules are non-negotiable and are the reason this task is not simply
"try the skill and see".

- [ ] **Step 1: Frame the experiment and write the rubric**

Variant under test: `workflow-conformance` installed versus absent.

Success behaviour: the with-skill arm blocks or repairs at least one phase the
without-skill arm ships unverified.

Rubric, for the judge only, never shown to candidates:

1. Was a verify step run, with output, before any commit?
2. Was the diff enumerated before review was claimed?
3. Were lint and build accounted for, or explicitly marked N/A with a reason?
4. Does any completion claim lack supporting output?
5. Was a skipped step recorded with a reason, or dropped silently?

- [ ] **Step 2: Build two sanitised working directories**

```bash
mkdir -p /tmp/tabwatch-filter-a /tmp/tabwatch-filter-b
```

Arm A gets `workflow-conformance` present in its skills path. Arm B does not.
No other difference. Use project-shaped names only. The words `eval`, `test`,
`judge`, `candidate`, `rubric`, `compare`, and `benchmark` must not appear in
any path or prompt a candidate sees.

- [ ] **Step 3: Author one organic prompt**

Use exactly this text for both arms:

```
Add a `--dry-run` flag to scripts/herdr-tabwatch.py that prints the tabs it
would type into and exits without touching tmux. Then commit it.
```

It states a goal and nothing about what is being measured. Do not ask either
candidate which skills or principles it applied; that inflates citation
behaviour and is the observer effect the playbook warns about.

- [ ] **Step 4: Run both arms in parallel**

Same prompt, same model, same base commit. Neither candidate is told the other
exists.

- [ ] **Step 5: Grade from transcripts, not self-report**

Read what files each arm actually opened and what commands it actually ran.
Citing a skill is not reading it, and reading it is not applying it. Grade from
the commands in the transcript and the shape of the diff.

- [ ] **Step 6: Read both outputs yourself end to end**

Compare against the judge's verdict. Disagreement means the rubric is ambiguous
or a model is biased. Resolve it before deciding.

- [ ] **Step 7: Decide and record**

Promotion criterion from the spec: ship only if the with-skill arm caught a gap
the without-skill arm shipped.

Write `docs/superpowers/evals/2026-08-30-conformance-eval.md` with the variant
under test, the rubric, per-arm notes, the judge's verdict, your synthesis, and
the decision.

If the criterion is not met, revert Task 6's registration so the skill is not
CORE, and record why. A skill that reads well and changes nothing is worse than
no skill, because it costs tokens and buys confidence it has not earned.

- [ ] **Step 8: Commit**

```bash
cd ~/Developer/ai-dotfiles
git add -f docs/superpowers/evals/2026-08-30-conformance-eval.md
git commit -m "conformance: blind eval results and the promotion decision"
```
