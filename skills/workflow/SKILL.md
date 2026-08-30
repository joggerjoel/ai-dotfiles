---
name: workflow
description: Route a task through the skills playbook and run it end to end. Use for /workflow, or when the user describes work ("build me X", "fix this", "migrate Y") and wants the playbook's phases applied rather than picking skills by hand. Names the task shape, quotes the routing row it matched, announces the skill chain, then executes build, verify, review and ship.
argument-hint: "[what you want done, in plain language]"
---

# workflow

One front door for the six-phase playbook. You give it a task; it decides the
lane, says so out loud, and then does the work.

## The one rule that keeps this honest

**This skill embeds no phase content.** The routing table, the phase steps and
the escalation ladder live in the playbook. Read them at run time; never copy
them here. Two copies drift, and the copy that drifts is always the one the
agent actually follows.

Resolve exactly one policy, in this order, and name which you used:

1. A project-local `workflow-skills.md` in the repo you are working in.
2. `~/.claude/references/workflow-skills.md` (machine-wide).

The machine-wide playbook grants project-local files precedence in its own
header, so this order is the playbook's rule, not a new one. If neither
resolves, say so and stop — guessing a workflow defeats the point of having one.

## Step 1 — Triage

Before routing, decide whether this needs the playbook at all. The playbook's
first routing row exempts trivial work: mechanical changes get no ceremony.

Trivial means **all** of: no behaviour change a test could observe, one file,
no dependency/config/schema/auth/CI change, and revertible with no
coordination. Anything else is tracked.

Trivial → do it, run `verify`, commit. Print one line saying you took the
trivial lane and why. Do not print the announcement block.

## Step 2 — Route and announce

Match the task against the playbook's Phase 1 routing table. Quote the row you
matched **verbatim** — if you cannot point at a row, you have not routed, you
have guessed.

Then print exactly this block before doing any work:

```
  Route  · <task shape, in the playbook's words>
         · playbook row: <the matched row, quoted>
  Chain  · <skill> → <skill> → <skill>
         → <skill> → <skill> → <skill>
  ────────────────────────────────────────
  Phase 1 Route ....... done
  Phase 2 Build ....... running (<what you are about to do>)
```

The chain is the actual skills you will invoke, in order, drawn from the
playbook's phases — not a paraphrase. The user reads this to catch a wrong
route _before_ it costs anything, so a vague chain wastes its only purpose.

## Step 3 — Execute

Run the chain. Announce each phase as it starts by reprinting its progress
line; keep going to the end without asking for approval at phase boundaries.
Stop only for a real failure or a decision genuinely outside the task.

Non-negotiables, all of them the playbook's own:

- **Logic changes are test-first.** The failing test runs, and is seen to fail,
  before the implementation exists.
- **UI work invokes the design stack** before code is written. Any chance the
  task touches UI counts.
- **`verify` runs before any commit.** Typecheck, test, lint, build — each one
  run, or explicitly marked N/A with a reason. Never commit on an unrun gate.
- **Review before ship**, per the playbook's escalation ladder. Read the diff;
  do not review from memory of having written it.

## Step 4 — Report

Close with what actually happened: phases run, commands run and their real
results, and anything skipped with the reason. Report failures as failures. A
phase you skipped is reported as skipped, never quietly dropped from the list —
an accurate short report beats a tidy false one.

## Red flags

These thoughts mean you have left the playbook:

| Thought                                | Reality                                                     |
| -------------------------------------- | ----------------------------------------------------------- |
| "The route is obvious, skip the block" | The block is how the user catches a wrong route. Print it.  |
| "I'll write the test after"            | Then it tests what you wrote, not what was asked.           |
| "Typecheck passed, that's verify"      | `verify` is four gates. One is not four.                    |
| "Small diff, skip review"              | Diff size does not predict defect count.                    |
| "I'll note the skipped phase silently" | An unreported skip is the failure mode this skill prevents. |
| "This task is trivial" (on 3+ files)   | Re-read Step 1. Trivial is stricter than it feels.          |

## Boundaries

`unlazy` asks whether the task is **done**; this asks whether it was **routed
and run** the way the playbook says. Wrap a long autonomous run in `unlazy` on
top of this — they compose and do not substitute.

`poteto-mode`, when the user has it on, is a competing routing authority with
its own playbooks and it wins. Detect it, use its matched playbook as the
policy in Step 1, and do not invoke it — its frontmatter forbids that.
