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
pass returns no new material findings. Typical cost is 2–3 rounds; 5 is the runaway
cap. Fixes are new text from a context-loaded author, which is why both loops exist —
each round of fixing can introduce its own gaps.

## Phase 1 — isolate pre-loop (shell)

Cold single-reviewer triage so the council spends its budget on hard defects,
not noise. Each round is one model call.

```bash
isolate < docs/plan.md            # round 1: cold, zero-context review
# fix what it found, then run the SAME command again; repeat until dry
```

Variants:

```bash
pbpaste | isolate                                   # review the clipboard
isolate "$(cat docs/plan.md docs/todo.md)"          # multiple docs as one review
```

With an explicit stop signal for the loop:

```bash
{ echo "Review this plan for gaps, ambiguities, and promises with no producer. If nothing material remains, reply exactly: NO MATERIAL GAPS."; cat docs/plan.md; } | isolate
```

`NO MATERIAL GAPS` → phase 1 is done.

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
isolate < docs/plan.md            # same convergence loop, on the revised doc
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
