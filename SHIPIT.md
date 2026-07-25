# SHIPIT — the review-and-ship process, with exact commands

The canonical process for getting a document (plan, spec, design doc) from draft to
shipped, using the tooling in this repo. Companion to `FUSE.md` (which explains _why_
this works); this file is the _what to type_. Follow it literally and there are no
misunderstandings about what "reviewed" or "ship it" means.

## The pipeline

```
isolate pre-loop  →  council  →  write-back  →  isolate post-loop  →  ship it
   (until dry)      (8 lenses)   (criticals      (until dry again)
                                  first + log)
```

Every loop's exit condition is **convergence, not a round count**: repeat until a
pass returns no new material findings. Fixes are new text from a context-loaded
author, which is why both loops exist — each round of fixing can introduce its own
gaps.

**Reviewer economics** — iteration count is driven by _findings per pass_. A single
mid-tier cold pass (the old sonnet default) surfaces a fraction of the material
issues each round, which is how loops stretch to 4–5 rounds. `isolate` now defaults
to a **find-grade deep pass (fable)**, and `isolate --wide` adds four parallel cheap
lenses (completeness, consistency, sequencing, failure-modes) merged with it — one
command, one round, maximal surface. Expected cost drops to 1–2 rounds. One rule is
non-negotiable: **convergence is only declared by the strongest model's silence** —
a weak reviewer finding nothing is absence of evidence, not convergence.

## Phase 1 — isolate pre-loop (shell)

Cold triage so the council spends its budget on hard defects, not noise.

```bash
isolate --wide < docs/plan.md     # round 1: deep fable pass + 4 sonnet lenses, parallel, merged
# write back everything MATERIAL, then:
isolate --review < docs/plan.md   # convergence check: ONE deep pass, MATERIAL/NIT rubric
# repeat write-back + --review until it reports 'MATERIAL: 0'
```

`--review` wraps the doc in a rubric that labels every finding **MATERIAL** (changes
behavior, correctness, sequencing, security, a gate, or a promise with no producer)
or **NIT**, ending with a counts line — `MATERIAL: 0` from the deep model is the
phase-done signal. (Model counts wobble; trust the labels over the arithmetic.)

Variants:

```bash
pbpaste | isolate                                   # generic cold call (no rubric)
isolate --review "$(cat docs/plan.md docs/todo.md)" # multiple docs as one review
isolate -m sonnet < docs/plan.md                    # explicit model override
```

## Phase 2 — council (Claude Code session)

```
council review docs/plan.md
```

Runs the 8 mandated lenses as parallel subagents and merges them into one ranked
consensus (dedupe by finding, root-cause groups, anti-herd counter-argument on any
unanimous finding). Run it on the **converged** draft from phase 1, never the raw one.

## Phase 3 — write-back (same session)

```
write back
```

The session applies the consensus into the document — criticals first — and appends a
revision-log entry so the audit trail lives in the doc itself.

## Phase 4 — isolate post-loop (shell)

```bash
isolate --wide < docs/plan.md     # same find-then-converge loop, on the revised doc
```

This phase is not optional. Post-council cold passes empirically keep finding real
items in the fixes themselves; loop until dry again.

## Ship

```
ship it
```

**"ship it" means: commit and push all changes.** Tests run before the commit where a
test suite exists. Nothing is shipped mid-pipeline — shipping happens only when both
of these are true at once:

1. The council consensus is fully written back.
2. The most recent isolate pass returned nothing new.

What legitimately remains open after shipping is only what a document cannot close:
named owners filled in, and gate numbers ratified from baseline evidence.

## When the subject is a decision or a build, not a document

```bash
S=~/.claude/skills/fusion/scripts/fusion.sh
bash "$S" opinion "your question"                  # two models, side by side
bash "$S" fuse "your question"                     # + fusion agent merges (consensus/divergence/discarded)
bash "$S" autovalidate "build task" --rounds 3     # gate written BEFORE the build; run from the target dir
open /tmp/fusion-harness/run-*/report.html         # visual report for any run
```

## The entire surface

One binary (`isolate`), one script (`fusion.sh`), two session phrases
(`council review …`, `write back`), one shipping phrase (`ship it`).
Everything else is repetition until dry.
