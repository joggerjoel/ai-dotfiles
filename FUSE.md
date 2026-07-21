# FUSE — model fusion tooling in this repo

> **AND, not OR.** Two models beat one; two models _merged with attribution_ beat two;
> a validation gate written before the build beats reviewing after it.

This document explains the fusion tooling that lives here — what it is, why it exists,
and how to use it — for developers who want to run it or port the pattern.

## Lineage

The pattern has had many names: aider called it
[architect/editor](https://aider.chat/2024/09/26/architect.html), Devin calls it
[fusion](https://cognition.com/blog/devin-fusion), OpenRouter
[ships it server-side](https://openrouter.ai/blog/announcements/fusion-beats-frontier/),
and [disler's fusion-harness](https://github.com/disler/fusion-harness) made it a
first-class workflow on the Pi coding agent. Our implementation ports that workflow onto
the agent CLIs already deployed on every machine here — **no Pi, no new dependencies**:
the ARCHITECT is `claude -p` and the BUILDER is `codex exec`, both spawned headless.

## Why it works (the part that isn't hype)

Frontier models writing a plan reliably miss their own gaps — not from lack of
capability, but structurally:

1. **Generation ≠ verification.** Writing optimizes for a coherent, complete-_looking_
   document. The search "what did I promise but never produce?" is a verification
   behavior that generation never runs.
2. **Blind spots correlate within a model class.** A frontier model re-reading frontier
   output re-derives the same assumptions that created the gaps. (Empirically: seven
   parallel frontier reviewers once missed the same undeclared dependency for the same
   principled reason — one differently-mandated reviewer caught it instantly.)
3. **Mandate and isolation beat model rank.** A mid-tier model with a fresh context and
   a narrow adversarial mandate finds what the author cannot, because the author never
   runs that search at all.

The tools below operationalize those three facts at three rigor levels.

## The tools

### 1. `isolate` — one cold reviewer (`bin/isolate`)

```bash
pbpaste | isolate            # clipboard -> sterile sonnet
isolate < plan.md            # file
isolate "inline prompt"
```

A clean-room, zero-context, single-shot call to **one fixed model** (sonnet;
`ISOLATE_MODEL` env to change). Fresh session, **replaced** system prompt, no skills,
no memory, no MCP, no tools, no CLAUDE.md, empty temp cwd. The replaced system prompt is
the load-bearing flag — with the default prompt, the skills listing and memory system
still leak into context. Paste a plan in, get cold eyes out.

### 2. `fusion` skill — two perspectives, merged (`skills/fusion/`)

```bash
S=~/.claude/skills/fusion/scripts/fusion.sh
bash "$S" opinion      "<prompt>"                  # both models answer, side by side
bash "$S" fuse         "<prompt>" ["merge instr"]  # + a FUSION agent merges them
bash "$S" autovalidate "<prompt>" [--rounds N]     # gate-first build loop
```

Three commands, one value ladder on the same two agents:

| Command        | Agents   | What you get                                                                                                                                                                                                                                                                                                      |
| -------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `opinion`      | 2        | Independent answers in parallel (no file writes), plus a stat line per agent — a running head-to-head of your models on _your_ work. Relativity is the best benchmark.                                                                                                                                            |
| `fuse`         | 3        | A FUSION agent (architect model, fresh context) critically merges both answers with inline `[ARCHITECT]`/`[BUILDER]`/`[BOTH]` attribution and a mandatory `Fused Result / Consensus / Divergence / Discarded` structure.                                                                                          |
| `autovalidate` | 2 + gate | A VALIDATOR writes an executable acceptance gate (`PASS:`/`FAIL: <feedback>` lines) **before any work happens**; the BUILDER builds in your cwd; the gate runs; `FAIL` lines feed back verbatim; loop until green or the round cap. The gate is chmod-locked and restored if tampered with. Exit 0 only on green. |

Chain them — `opinion` (scout) → `fuse` (plan) → `autovalidate` (build+test) — and you
have a micro software-development lifecycle inside one harness.

**Every run emits a self-contained `report.html`** (in
`/tmp/fusion-harness/run-*/`, never your repo): side-by-side answer panels, a stat table
(wall time, tokens, cost), consensus/divergence/discarded cards color-coded green/amber/
red, and — for autovalidate — the gate script plus per-round pass/fail breakdowns. That
file is the "TUI": open it, archive it with the run, or publish it for a teammate.

Implementation notes worth stealing:

- **Clean-room children.** The builder runs `codex exec --ephemeral` (no session
  persistence); each agent's entire contract comes from the harness's prompt files, so
  runs are reproducible on any machine regardless of installed skills.
- **Nested-sandbox reality.** A nested `claude -p` may only write inside its cwd; the
  validator therefore gets `--add-dir <run-dir>` plus a cwd fallback for the gate file.
- **Gate integrity.** `gate.sh` is `chmod 555` after creation and byte-compared/restored
  after every builder round.

### 3. `council` skill — the full adversarial audit (`skills/council/`)

The 8-lens specialization of the same idea for plans/specs/design docs: eight
differently-mandated reviewers (architecture, red-team, security, cost, reliability,
code-quality, provisioning/bill-of-materials, devil's-advocate) run as parallel
subagents, then merge into a ranked consensus with dedupe, root-cause grouping,
consensus scoring, and an anti-herd counter-argument on any unanimous finding. The
`provisioning` lens is the one reviewer allowed to bring ecosystem knowledge the
document doesn't state — added after the correlated-blind-spot incident above.

## Where each surface sees it

- **Claude Code** — the `fusion` skill triggers on `/opinion`, `/fusion`,
  `/auto-validate`, or plain-language asks ("get both models' take").
- **Codex** — `/opinion`, `/fusion`, `/auto-validate` custom prompts
  (`codex/prompts/*.md`, symlinked to `~/.codex/prompts/` by `setup.sh`).
- **Cursor** — discovers `~/.claude/skills` natively; the skill just appears.
- **Any shell** — call `fusion.sh` / `isolate` directly; they're plain bash over
  headless CLIs.

Deployment is automatic: `setup.sh` links `bin/*` into `~/.local/bin`, copies
`skills/*` into `~/.claude/skills`, and symlinks the codex prompts — so a fleet update
propagates everything.

## Picking a rigor level

| Situation                                                  | Tool                         |
| ---------------------------------------------------------- | ---------------------------- |
| "Does this plan hold up to fresh eyes?"                    | `pbpaste \| isolate`         |
| A decision with trade-offs; you want perspective diversity | `fusion.sh opinion` → `fuse` |
| A build you want proven, not reviewed                      | `fusion.sh autovalidate`     |
| A plan/spec about to become code                           | council review               |

Cost scales with rigor: isolate is one model call; fuse is three; a council run is
eight-plus. Reach for the level the decision deserves — and remember the whole point:
**the wrong question is "which model." The right question is "which role."**
