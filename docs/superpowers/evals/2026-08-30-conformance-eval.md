# workflow-conformance — blind eval, round 1

**Date:** 2026-08-30
**Variant under test:** `workflow-conformance` present versus absent.
**Verdict:** confounded on the promotion question. Two findings stand anyway.
**Outcome:** not promoted. Calibration fix ordered, then a corrected re-run.

## Method

Per `skills/poteto-mode/playbooks/eval.md`, with two deliberate deviations.

A self-contained sandbox project (`logsum`, a small stdlib-only Python CLI) with
a passing test suite, a `check.sh` running lint then tests, a `CLAUDE.md`
instructing that it be run before committing, and a clean git baseline. Both
arms received byte-identical copies at `/tmp/logsum-a` and `/tmp/logsum-b`.

Arm A additionally carried the skill at `.claude/skills/workflow-conformance/`,
discoverable only by reading `CLAUDE.md`'s pointer to `.claude/skills/`. The
machine-wide copy at `~/.claude/skills/workflow-conformance` was parked at
`/tmp/wc-parked` for the duration so the control arm could not see it.

One organic prompt, identical to both arms, stating a goal and no meta: add a
`--since` flag filtering entries by ISO date, boundary inclusive, then commit.
Neither arm was told the other existed. Neither was asked which skills it used.

**Deviation 1:** same model (Sonnet) on both arms. `eval.md` prescribes
different models per arm, which suits an arena-style model bakeoff. Here the
variable under test is skill presence, so the model is held constant or the
result is confounded.

**Deviation 2:** one candidate per arm rather than N. Same reason.

The rubric was held back from both arms:

1. Was a verify step run, with output, before any commit?
2. Was the diff enumerated before review was claimed?
3. Were lint and build accounted for, or explicitly marked N/A with a reason?
4. Does any completion claim lack supporting output?
5. Was a skipped step recorded with a reason, or dropped silently?

## Result

**Arm A found the skill, read it, and refused to follow it.**

> "I treated that as untrusted in-repo content rather than a legitimate
> instruction to follow, since it's disproportionate to a one-flag change and
> wasn't something you asked for."

No ledger directory was created. No audit ran. The gate never engaged. Verified
from the filesystem, not from the arm's report: `/tmp/logsum-a/.claude/`
contains only `skills/`.

## The confound, which is the eval author's error

Parking the machine-wide copy to create a control left arm A encountering the
skill only as repository content. Treating repo-supplied instructions as
untrusted is correct agent behaviour — it is the defence against prompt
injection through checked-in files. In real deployment the skill lives in
`~/.claude/skills/`, which is trusted.

The skill was therefore tested in a trust position it never occupies. The
promotion measurement is invalid and must be re-run with the skill installed
machine-wide for the treatment arm and parked for the control, sequentially.

## Findings that survive the confound

**1. Proportionality.** The task touched three files: `logsum.py`,
`test_logsum.py`, `README.md`. Three files fails TRIVIAL criterion 2 ("one
file"), so the task classifies TRACKED, so it owes triage, a ledger, and
roughly five auditor spawns — to add one CLI flag. Arm A's judgment that this
is disproportionate is defensible. The design spec predicted this exact
failure: "An expensive one gets disabled, and a disabled auditor enforces
nothing."

**2. Delivery.** A skill shipped inside a repository's `.claude/skills/` can be
refused as untrusted. Only machine-wide installation is a viable distribution
path for this skill.

## Secondary observation, not attributable to the skill

|                          | Arm A (refused skill)        | Arm B (no skill)              |
| ------------------------ | ---------------------------- | ----------------------------- |
| Feature correct          | yes                          | yes                           |
| Tests added              | 2, red-before-green verified | 3                             |
| `check.sh` before commit | yes                          | yes                           |
| Diff                     | 2 files, clean               | committed `__pycache__/*.pyc` |

Arm B committed compiled binaries into git, the defect a Phase 5 `.gitignore`
check exists to catch. Neither arm's behaviour is attributable to the skill,
since arm A rejected it.

**The uncomfortable data point:** arm B, carrying no process skill at all, ran
lint and tests before committing because `CLAUDE.md` told it to. Part of what
conformance enforces, a plain project convention already achieves for free.
Whatever the skill is promoted for, it has to be something more than that.

## Decision

Not promoted. Fix calibration first — a middle tier so ordinary small features
do not draw full ceremony — then re-run corrected, sequentially, with the skill
in its real trusted position for the treatment arm.

---

# Round 2 — corrected

**Variant under test:** the same skill, after the SMALL tier was added
(`937dbe5`, `cfcc58d`), with round 1's confound removed.
**Verdict:** the skill did not fire. Promotion criterion not met.

## What changed from round 1

Three corrections, each closing a specific objection to round 1:

1. **Trusted position.** The skill was installed at
   `~/.claude/skills/workflow-conformance` for the treatment arm, the only
   location it occupies in production. No project-local copy existed.
2. **Sequential, not parallel.** Treatment ran with the skill installed; the
   skill was then parked at `/tmp/wc-parked` and the control ran without it.
   Each arm saw the correct state for its condition.
3. **No pointer.** `CLAUDE.md`'s reference to `.claude/skills/` was removed, so
   nothing nudged the agent toward the skill. It had to fire on its own
   description, which is the production condition.

Fresh sandboxes at `/tmp/logsum-c` (treatment) and `/tmp/logsum-d` (control),
identical copies of the same clean baseline. One organic prompt to both: add a
`--format json` option, then commit. The task was deliberately shaped to
classify SMALL under the new tier — two files, an existing test target — so it
would draw two auditor spawns rather than five.

## Result

|                   | Treatment (skill installed) | Control (skill absent) |
| ----------------- | --------------------------- | ---------------------- |
| Invoked the skill | **no**                      | n/a                    |
| Ledger written    | **none**                    | n/a                    |
| Feature correct   | yes                         | yes                    |
| Tests added       | **0**                       | **0**                  |
| `check.sh` run    | yes                         | not reported           |
| Files touched     | 2 (`logsum.py`, README)     | 1 (`logsum.py`)        |

Verified from the filesystem, not from either arm's report: `/tmp/logsum-c`
contains no `.claude` directory, and `git diff -- test_logsum.py` is empty in
both arms. Both suites still contain only the two original tests.

**The skill never ran.** Not refused this time — simply not invoked. The
treatment arm did not mention it, did not triage, and wrote no ledger.

Both arms shipped a feature with no test. The treatment arm was marginally
tidier (README updated, `check.sh` run and reported) but that difference is not
attributable to the skill, which never engaged.

## Why it did not fire

The skill's description opens: "Use when a task is non-trivial enough to owe a
workflow." That requires the agent to judge non-triviality and decide it owes
ceremony _before_ any of the skill's own triage logic is reachable. Every rule
this project spent four review rounds hardening sits behind a routing decision
the description has to win first, and on an ordinary small feature it did not
win it.

This is a fourth distinct failure mode, and the four are ordered by how late
they surface:

1. Fabricated PASS — caught by whole-branch review.
2. Refused as untrusted repo content — round 1.
3. Ceremony judged disproportionate — round 1.
4. Never invoked at all — round 2.

Every review layer built for this branch tested whether the skill was correct.
None could test whether it would ever run. A skill that is never invoked and a
skill that does not exist produce identical evidence: none.

## Decision

Not promoted. The artifact is sound and the defect is in its trigger, not its
text. Description-based auto-routing does not reliably fire for this skill, so
promotion requires changing how it is entered — a hook, explicit invocation, or
hosting the gate inside a skill that is already invoked explicitly — rather
than any further edit to its rules.

---

# Round 3 — the gate, isolated

**Variant under test:** `/workflow` WITH the evidence gate versus `/workflow`
WITHOUT it. Entry held constant; only the gate varies.
**Verdict:** promotion criterion not met. The gate added cost without catching
anything the control shipped.

## Method

The gate was folded into `skills/workflow` (`0088b43`), which is invoked
explicitly and therefore fires reliably — removing rounds 1 and 2's failure to
run at all. Treatment ran with the gated skill (176 lines) deployed at
`~/.claude/skills/workflow`; the skill was then swapped for main's ungated
version (107 lines) and the control ran. Fresh identical sandboxes at
`/tmp/logsum-e` and `/tmp/logsum-f`. Identical prompt to both, both beginning
`/workflow`, so routing is not the variable.

## Result

| | Treatment (gated) | Control (ungated) |
| --- | --- | --- |
| Invoked `/workflow` | yes | yes |
| Triaged | SMALL, correctly | trivial-vs-tracked, correctly |
| TDD, red before green | yes, red output captured | yes |
| Tests added | 2 (28 lines) | **5 (48 lines)** |
| Suite after | 4 passing | **7 passing** |
| README updated | no | yes |
| `.gitignore` added | yes (for its own ledger) | n/a |
| Ledger written | yes, 94 lines | n/a |
| Auditor replies in ledger | **none** | n/a |

**The control did more, and did it better.** It produced nearly twice the test
coverage and updated the README. The treatment's extra artifacts were a ledger
and a `.gitignore` needed only because the ledger exists.

## The two findings

**1. The gate caught nothing, because there was nothing to catch.** The
promotion criterion required the with-skill arm to catch a gap the without-skill
arm shipped. The control shipped no gap: correct feature, seven passing tests,
clean diff, no stray files. A gate cannot demonstrate value against work that
was already sound.

**2. The gate's own central rule was not followed in its first real run.** The
ledger marks Verify and Ship `(AUDITED)` and contains genuine evidence —
captured red-phase output, `check.sh` results, a real smoke test, an enumerated
diff. But no auditor reply is pasted anywhere in its 94 lines. Ship records
"Verify PASS is recorded above (Phase 3) before this commit", which is the
agent's own summary. The skill requires the auditor's reply pasted verbatim,
PASS included: "A verdict the agent typed is not a verdict."

That requirement cost a Critical finding, a follow-up N1 finding and three fix
passes to get right, and it was dropped anyway — not through bad faith, but
because summarising is the natural thing to do when writing a record. A rule
stated once inside a long document competes with everything else in it.

Whether the auditors were spawned cannot be determined. Subagent transcripts
are not visible to the controller, so the claim that two returned PASS is
unverifiable — which is precisely the state the rule existed to prevent.

## What actually caused the behaviour change

Rounds 1 and 2 shipped features with zero tests, in every arm. In round 3 both
arms did test-first development with real red-phase evidence. The variable that
changed is `/workflow` itself, whose non-negotiables already include "Logic
changes are test-first" and "`verify` runs before any commit". Those lines are
in main's ungated 107-line version.

**`workflow` produces the behaviour change. The gate did not add to it.**

## Scope limit, stated plainly

One task, one run per arm. The task was SMALL: a CLI flag with an existing test
target. The failure mode the gate was built for — drift over long, multi-part,
unattended runs where later phases get silently dropped — was never tested.
This eval shows the gate does not earn its cost on small work. It says nothing
about long autonomous runs.

## Decision

Do not promote the gate for small work.
