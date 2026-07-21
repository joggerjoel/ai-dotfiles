---
name: fusion
description: Two-model fusion harness over the local headless agent CLIs (claude -p as ARCHITECT, codex exec as BUILDER). Three commands — /opinion (both models answer independently, side by side), /fusion (both answer, a third fusion agent merges with [ARCHITECT]/[BUILDER] attribution and a Consensus/Divergence/Discarded analysis), /auto-validate (validator writes an executable acceptance gate BEFORE any work, builder builds, the gate runs, failures loop back until green). Every run emits artifacts plus a self-contained report.html with side-by-side panels and convergence cards. Use when the user says "/opinion", "/fusion", "/auto-validate", "model fusion", "fuse the models", "get both models' take", "second opinion from two models", or wants architect/builder two-agent work with validation-first building.
---

# Fusion harness

Two hard-labeled agents (ARCHITECT = `claude -p`, BUILDER = `codex exec`), spawned headless
and clean-room (`--ephemeral`, no session persistence for the builder; artifacts in
`/tmp/fusion-harness/run-*`, never in the repo). AND, not OR: combine the models' answers
instead of picking one. This is the general-purpose two-model sibling of the council skill
(which is the 8-lens document-audit specialization of the same idea).

## Commands

All via the bundled script (this skill's dir):

```bash
S=~/.claude/skills/fusion/scripts/fusion.sh

bash "$S" opinion      "<prompt>"                     # 2 agents, side-by-side answers
bash "$S" fuse         "<prompt>" ["merge instr"]     # 2 agents + fusion agent merges
bash "$S" autovalidate "<prompt>" [--rounds N]        # gate-first build loop (default 3)
```

- **opinion** — both models answer independently in parallel (no file writes). Read both,
  compare latency/tokens/cost in the stat table. A pure A/B; relativity is the best benchmark.
- **fuse** — opinion first, then a FUSION agent (architect model, fresh context) merges per
  the merge instruction (default: critical merge, inline `[ARCHITECT]`/`[BUILDER]`/`[BOTH]`
  attribution) and must emit `## Fused Result / ## Consensus / ## Divergence / ## Discarded`.
- **autovalidate** — VALIDATOR (architect) writes `gate.sh` — an executable acceptance gate
  with `PASS:`/`FAIL: <feedback>` lines — BEFORE any build. BUILDER (codex,
  `-s workspace-write`) then builds in the current directory; the harness runs the gate,
  feeds `FAIL` lines back verbatim, and loops until green or the round cap. The gate is
  chmod-protected and restored if tampered with. Exit code 0 only on green.

## Workflow guidance

- Chain them as a micro-SDLC: `opinion` (scout) → `fuse` (plan) → `autovalidate` (build+test).
- Run `autovalidate` from the directory the work should land in.
- After any run, tell the user the run dir and offer the report:
  `open <run-dir>/report.html` — side-by-side panels, consensus (green) / divergence (amber)
  / discarded (red) cards, gate rounds with pass/fail counts. The HTML is self-contained;
  it can also be published as an Artifact for sharing.
- Engine overrides: none needed normally; the script uses `claude` and `codex` from PATH.
  Model/effort selection follows each CLI's own configured defaults.
- Cost note: every command spends real tokens on two or three agents. For trivial questions
  a single model is cheaper — reach for fusion when perspective diversity or validation
  rigor actually pays.
