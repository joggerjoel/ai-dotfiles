# Skills Workflow — Machine-Wide Playbook

Full iteration 2026-08-29: every installed skill (90 in `~/.claude/skills/`,
~120 across plugins and built-ins) assigned a disposition, redundancies resolved
with a named winner, and one unified workflow synthesized from the whole
inventory. Project CLAUDE.md and a project-local `workflow-skills.md` override
this.

Dispositions: **CORE** (in the default loop) · **ON-DEMAND** (named trigger,
high value) · **DOMAIN** (invoke when its domain appears) · **BENCH** (superseded
— winner named).

---

## 1. The Unified Workflow (the synthesis)

One loop, not competing stacks. superpowers provides the auto-invoked skeleton;
pstack provides the routing brain and fan-out tools; unlazy wraps long runs.

### Phase 0 — Session start

- `CORE` auto-loads (identity, format, stack preferences).
- Resuming work? → `recall` (current-state brief) + `claude-mem:mem-search`
  (episodic findings). Cross-agent history → `cass`.

### Phase 1 — Route the task

| Task shape                                                     | Route                                                                             |
| -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Trivial/mechanical                                             | Just do it → `verify` → commit. No ceremony.                                      |
| Feature, shape roughly known                                   | `superpowers:brainstorming` → `superpowers:writing-plans` → Phase 2               |
| Feature crossing function boundaries                           | `architect` (types/signatures/modules first) instead of plain brainstorming       |
| Design genuinely open, wrong shape is costly                   | `arena` (N candidates → pick base → graft)                                        |
| Written plan/spec exists, high stakes                          | `council` (adversarial multi-lens audit) before code                              |
| Conventional approach feels wrong                              | `first-principles` / `principle-redesign-from-first-principles`                   |
| Bug / failing test / "that's weird"                            | `superpowers:systematic-debugging` + `principle-fix-root-causes` — BEFORE any fix |
| Large migration, no narrower playbook                          | `figure-it-out` (auditable playbook + hypothesis loop)                            |
| Long/multi-part/unattended, or burned before by half-done work | wrap everything in `unlazy` (§2) + `show-me-your-work`                            |
| Question, not a change                                         | `how` (mechanics) / `why` (rationale) / `teach` (both, for a human)               |

### Phase 2 — Build

- `superpowers:test-driven-development` for logic changes (the standalone `tdd`
  skill is intentionally narrower — only when explicitly asked or a cheap local
  test target exists).
- `typescript-best-practices` on any `.ts`/`.tsx`.
- UI touched (≥1% chance): design stack — `ui-ux-pro-max` → `design-taste` →
  `color-strategy` → source via `react-bits` (big animated React) or `uiverse`
  (small primitives) → `dataviz` REQUIRED before any chart → project
  `/design-system` if present.
- Principles in force while coding: `principle-model-the-domain` (name the data
  shape first), `principle-laziness-protocol` + `principle-subtract-before-you-add`
  (bias to deletion), `principle-type-system-discipline`,
  `principle-boundary-discipline`, `principle-build-the-lever` (script the bulk
  edit, don't hand-edit), `principle-guard-the-context-window` (bulk → subagents).
- Parallel work: `swarm` (coverage/races/gauntlets),
  `superpowers:dispatching-parallel-agents` (independent plan tasks),
  `principle-separate-before-serializing-shared-state` (before agents share files).

### Phase 3 — Verify

- `verify` (typecheck+test+lint+build) — the floor for every change.
- Surface-specific: `verify-ui` (browser), `verify-tui` (tmux buffer),
  `responsive-audit` (mobile sweep), `run` (see it working in the real app).
- `test-and-fix` to burn down failures; `autoresearch:fix` for zero-error pushes.
- `superpowers:verification-before-completion` + `principle-prove-it-works`:
  the real artifact, not "it compiles".
- Small diff you don't trust → `blast-radius` (prove safety by running code).

### Phase 4 — Review

1. `no-comments` (comment hygiene) → 2. `review-changes` (uncommitted diff) —
   the default. Escalations: `/code-review` (PRs), `interrogate` (contested design,
   multi-model adversarial), `pr-review-toolkit:review-pr` (big/risky PRs only),
   `security-review` (security-sensitive branches), `simplify` (quality-only pass),
   second opinion → `codex:rescue` or `fusion` `/opinion`.

### Phase 5 — Ship

- `commit-commands:commit` / `commit-push-pr` (default). `quick-commit` only for
  small solo changes. Never commit without Phase 3.
- `superpowers:finishing-a-development-branch` (merge/PR/cleanup decision);
  pairs with `superpowers:using-git-worktrees` from the start of isolated work.
- Pre-release gate on risky changes: `autoresearch:regression`.

### Phase 6 — Learn (close the loop)

- `reflect` — transcript → concrete skill edits. `reflection` — config-level
  suggestions. `hookify` — turn "never again" into enforced hooks.
  `claude-md-management:revise-claude-md` — session learnings into CLAUDE.md.
  `principle-encode-lessons-in-structure` — 2nd repeated instruction becomes a
  lint/check, not more prose.

---

## 2. unlazy — the wrapper for long autonomous work

Triggers: multi-part tasks, exhaustive audits/builds, work that returned
half-done before, "/unlazy", "gates", "tree N", "do not stop until done".
Enforces: (1) executable **acceptance gates written BEFORE execution**,
(2) **Depth Tree** decomposition — leaves map onto `swarm`/subagents,
(3) evidence **re-verified against gates** before reporting.
Pairs with `show-me-your-work` (decision trail),
`principle-sequence-verifiable-units` (each leaf ends in a check), and the
`verify*` family as gate implementations. Alternative gate-writer: `fusion`
`/auto-validate` (a _different model_ writes the gate before the builder runs).

---

## 3. Full Iteration — every skill, dispositioned

### 3a. Process & execution (the loop's skeleton)

| Skill                                                                             | Disp.     | Notes                                                                   |
| --------------------------------------------------------------------------------- | --------- | ----------------------------------------------------------------------- |
| superpowers:using-superpowers                                                     | CORE      | Session entry rule: check skills before acting                          |
| superpowers:brainstorming                                                         | CORE      | Default pre-creative gate                                               |
| superpowers:writing-plans / executing-plans                                       | CORE      | Multi-step work                                                         |
| superpowers:test-driven-development                                               | CORE      | Default build discipline                                                |
| superpowers:systematic-debugging                                                  | CORE      | Before any fix                                                          |
| superpowers:verification-before-completion                                        | CORE      | With principle-prove-it-works                                           |
| superpowers:using-git-worktrees / finishing-a-development-branch                  | CORE      | Worktree lifecycle                                                      |
| superpowers:dispatching-parallel-agents / subagent-driven-development             | ON-DEMAND | Plan-task fan-out                                                       |
| superpowers:writing-skills / requesting- / receiving-code-review                  | ON-DEMAND |                                                                         |
| poteto-mode                                                                       | ON-DEMAND | pstack router; user-triggered mode (`disable-model-invocation`)         |
| principle-* (21 leaves)                                                           | CORE      | The decision rules; cite the leaf that drove the choice                 |
| architect / arena / swarm / interrogate                                           | ON-DEMAND | Design-first, bakeoff, fan-out, adversarial — see Phase 1/2/4           |
| blast-radius                                                                      | ON-DEMAND | Pre-ship for untrusted diffs                                            |
| figure-it-out                                                                     | ON-DEMAND | Big migrations                                                          |
| unlazy · show-me-your-work                                                        | ON-DEMAND | Long-run wrapper + decision trail                                       |
| recall · teach · how · why                                                        | ON-DEMAND | Context resume; explanation                                             |
| explore-plan-code-test                                                            | BENCH     | → superpowers skeleton (same phases, less enforcement)                  |
| feature-dev:feature-dev (+ code-explorer/architect/reviewer agents)               | BENCH     | → superpowers + pstack cover it; agents usable à la carte               |
| claude-mem:make-plan / do / babysit / pathfinder / smart-explore / learn-codebase | BENCH     | → writing-plans, Explore agent, `how`; keep mem-search/standup/timeline |
| getting-started                                                                   | DOMAIN    | Onboarding a new person only                                            |
| first-principles                                                                  | ON-DEMAND | When convention itself is suspect                                       |
| council                                                                           | ON-DEMAND | Plan/spec audit, high stakes                                            |
| unslop                                                                            | CORE      | Always applies to prose                                                 |
| technical-writing                                                                 | ON-DEMAND | Docs/RFCs/PR descriptions (Diátaxis + style rules)                      |
| elements-of-style / humanizer / bro                                               | ON-DEMAND | Prose polish; de-AI; plain restatement                                  |
| no-comments                                                                       | CORE      | Pre-review comment pass                                                 |
| setup-pstack                                                                      | ON-DEMAND | Re-run when entitled models change (writes Cursor-side rule)            |
| automate-me                                                                       | ON-DEMAND | Capture user style into a -mode skill                                   |
| CORE                                                                              | CORE      | Auto-loads at session start                                             |

### 3b. Verification & shipping

| Skill                                                   | Disp.     | Notes                                                                                                                                                                                                                                                                                    |
| ------------------------------------------------------- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| verify                                                  | CORE      | The pre-commit floor                                                                                                                                                                                                                                                                     |
| verify-ui / verify-tui                                  | ON-DEMAND | Surface-specific acceptance                                                                                                                                                                                                                                                              |
| create-verification-skill / maintain-verification-skill | ON-DEMAND | Generate + upkeep a project-local control skill — do this once per serious repo                                                                                                                                                                                                          |
| test-and-fix                                            | ON-DEMAND | Failure burn-down                                                                                                                                                                                                                                                                        |
| run                                                     | ON-DEMAND | See the change in the real app                                                                                                                                                                                                                                                           |
| responsive-audit                                        | ON-DEMAND | 4-viewport mobile sweep with shareable diff page                                                                                                                                                                                                                                         |
| tdd (standalone)                                        | ON-DEMAND | Narrow by design; superpowers TDD is the default                                                                                                                                                                                                                                         |
| review-changes                                          | CORE      | Default diff review                                                                                                                                                                                                                                                                      |
| code-review (built-in) / security-review / simplify     | ON-DEMAND | PR review; security branches; quality-only                                                                                                                                                                                                                                               |
| pr-review-toolkit:review-pr (+ 6 agents)                | ON-DEMAND | Big/risky PRs; agents (silent-failure-hunter, type-design-analyzer, pr-test-analyzer, comment-analyzer, code-simplifier) à la carte                                                                                                                                                      |
| interrogate                                             | ON-DEMAND | Multi-model adversarial                                                                                                                                                                                                                                                                  |
| commit-commands:commit / commit-push-pr / clean_gone    | CORE      | Default ship path + branch hygiene                                                                                                                                                                                                                                                       |
| quick-commit                                            | ON-DEMAND | Small solo changes only                                                                                                                                                                                                                                                                  |
| autoresearch pack (14)                                  | ON-DEMAND | Distinct verbs: `:fix` (zero errors), `:regression` (baseline gate), `:security` (STRIDE), `:ship` (8-phase deploy), `:plan/:probe/:predict/:reason/:scenario` (planning rigor), `:learn` (docs gen), `:evals/:improve/:debug`, core loop. Opt-in per verb; overkill for routine changes |
| unlazy                                                  | (see §2)  |                                                                                                                                                                                                                                                                                          |
| code-simplifier / codex:rescue / fusion                 | ON-DEMAND | Cleanup; second model; two-model harness with /auto-validate                                                                                                                                                                                                                             |
| isolate                                                 | ON-DEMAND | SHIPIT cold-review loop on documents                                                                                                                                                                                                                                                     |

### 3c. Design & UI (auto-invoke on any UI work)

| Skill                                                                                | Disp.     | Notes                                  |
| ------------------------------------------------------------------------------------ | --------- | -------------------------------------- |
| ui-ux-pro-max (pack of 7: design, brand, design-system, ui-styling, slides, banner)  | CORE (UI) | Entry vocabulary + systems             |
| design-taste                                                                         | CORE (UI) | Motion/polish/anti-slop                |
| color-strategy                                                                       | CORE (UI) | Skip if a design system governs color  |
| react-bits / uiverse                                                                 | CORE (UI) | Big animated React vs small primitives |
| dataviz                                                                              | CORE (UI) | REQUIRED before any chart, any medium  |
| frontend-design                                                                      | ON-DEMAND | Whole layouts                          |
| chrome-devtools-mcp pack (a11y-debugging, debug-optimize-lcp, memory-leak-debugging) | DOMAIN    | Perf/a11y/leak investigations          |

### 3d. Research, memory, context

| Skill                                                              | Disp.     | Notes                                                                                                                                                 |
| ------------------------------------------------------------------ | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| claude-mem:mem-search / standup / timeline-report / weekly-digests | CORE      | Episodic recall; the rest of the 17-skill pack (what-the, wowerpoint, oh-my-issues, knowledge-agent, design-is, how-it-works, version-bump) on demand |
| recall / cass                                                      | ON-DEMAND | Session resume; cross-agent history                                                                                                                   |
| headroom                                                           | ON-DEMAND | Context-optimization proxy status                                                                                                                     |
| context7 / firecrawl / scrapegraph                                 | CORE      | Docs; scraping; prompt-driven extraction (per tool-priorities.md)                                                                                     |
| context-dump                                                       | ON-DEMAND | Tab triage                                                                                                                                            |
| feature-gap-audit                                                  | ON-DEMAND | Cumulative gap log vs reference projects                                                                                                              |
| anthropic-skills pack (11)                                         | ON-DEMAND | docx/pdf/pptx/xlsx (documents), morning/schedule (routines), consolidate-memory/import-memory, explain-usage, skill-creator, setup-cowork             |

### 3e. Harness & meta

| Skill                                                                            | Disp.                   |
| -------------------------------------------------------------------------------- | ----------------------- |
| update-config · keybindings-help · fewer-permission-prompts · hookify (5 skills) | ON-DEMAND               |
| skill-creator · plugin-dev pack (8) · claude-code-guide agent                    | ON-DEMAND               |
| reflect · reflection · claude-md-management (2)                                  | CORE (Phase 6)          |
| install · maintain (host health) · loop (interval runner)                        | ON-DEMAND               |
| herdr-* (file-viewer + references)                                               | ON-DEMAND (Herdr panes) |

### 3f. Domain packs (invoke only when the domain appears)

| Domain                                | Skills                                                                                           |
| ------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Postgres/PostGIS/Timescale/pgvector   | `0.5.1:*` pack (10) + `supabase:supabase-postgres-best-practices`                                |
| Supabase / Stripe                     | `supabase:*`, `stripe:*` (both need MCP auth)                                                    |
| n8n                                   | `n8n-mcp-skills:using-n8n-mcp-skills` FIRST — routes to 15 specialists                           |
| Claude API / Agent SDK                | `claude-api` (read BEFORE any LLM/pricing answer), `agent-sdk-dev:*` (3)                         |
| API → CLI                             | `printing-press` family (10): press → polish → score → publish → retro/amend/reprint             |
| 9Router gateway                       | `9router` entry → 8 capability skills (chat/image/tts/stt/embeddings/video/web-search/web-fetch) |
| iOS                                   | simulator MCP tools                                                                              |
| Bot UI / webhooks                     | `make-bot-ui`                                                                                    |
| Karpathy guidelines / codex prompting | `andrej-karpathy-skills`, `codex:*` (3 references)                                               |

**Availability caveat:** pstack skills (`poteto-mode`, `arena`, `architect`,
`swarm`, `tdd`, `blast-radius`, `figure-it-out`, `recall`, `teach`, `reflect`,
`interrogate`, `show-me-your-work`, `quick-commit`, `test-and-fix`, and others)
live in `~/.claude/skills/` but may not appear in a session's Skill-tool list —
they're user-invocable by name/slash. Check `ls ~/.claude/skills/` before
concluding a skill is missing. pstack was authored for Cursor: `setup-pstack`
writes `~/.cursor/rules/`; substitute `unslop` for `deslop` and
`superpowers:writing-skills` for `create-skill` in Claude Code.

---

## 4. Redundancy Verdicts (the winners)

| Capability           | Winner                                                                                 | Benched                                                                                                                  |
| -------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| Process skeleton     | superpowers phases + pstack routing (§1)                                               | explore-plan-code-test, feature-dev:feature-dev, claude-mem:make-plan/do                                                 |
| Design exploration   | brainstorming (default) → architect (boundaries) → arena (open) → council (spec audit) | — (tiered, not redundant)                                                                                                |
| Diff review          | review-changes → /code-review → interrogate → pr-review-toolkit (escalation ladder)    | —                                                                                                                        |
| TDD                  | superpowers:test-driven-development                                                    | standalone `tdd` (kept, narrow use)                                                                                      |
| Commit               | commit-commands:commit                                                                 | quick-commit (small solo only)                                                                                           |
| Browser automation   | agent-browser CLI                                                                      | chrome-devtools (perf/network only), claude-in-chrome (logged-in profile only), playwright/browser-tools (not installed) |
| Skill authoring      | superpowers:writing-skills + skill-creator                                             | plugin-dev:skill-development (plugin-hosted only); anthropic-skills:skill-creator (duplicate)                            |
| Scraping/docs        | context7 (docs), firecrawl (scrape), gh CLI (GitHub)                                   | WebFetch/WebSearch for these; crawl4ai MCP (broken — REST only)                                                          |
| Memory               | MEMORY.md (durable) + claude-mem (episodic) + recall (resume)                          | claude-mem exploration skills vs Explore agent                                                                           |
| Gate-first execution | unlazy                                                                                 | fusion:/auto-validate (kept: cross-model gate variant)                                                                   |
| Retrospective        | reflect (skills) / reflection (config) / hookify (enforcement)                         | — (different targets)                                                                                                    |

---

## 4b. Which Stack Is Better — and Model Portability

Skills are plain markdown instructions, so they're model-agnostic by default.
Portability breaks in exactly three ways: hardcoded model slugs, harness-specific
tool names, or external CLI dependencies. Graded head-to-head:

| Stack / skill                                                           | Any model?         | Why                                                                                                                                                                                  | Verdict                                                                                                                                    |
| ----------------------------------------------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **superpowers** (14)                                                    | ✅ fully           | Pure process prose; no model names, no harness-specific tools                                                                                                                        | **Best portable core.** Works identically on Fable, Opus, Sonnet, GPT-class — any model that reads skills                                  |
| **unlazy**                                                              | ✅ fully           | Pure discipline (gates, Depth Tree, evidence); zero dependencies                                                                                                                     | **Best portable wrapper** for long work                                                                                                    |
| **principle-\*** (21)                                                   | ✅ fully           | Decision rules in prose                                                                                                                                                              | Portable; the most transferable knowledge in the inventory                                                                                 |
| **pstack delegation** (arena, swarm, architect, interrogate, how, why…) | ✅ _if configured_ | Concepts are portable; the model-per-role map is the only coupling. `setup-pstack` supports `inherit-parent` / `auto` aliases — every role then runs on whatever the parent model is | Portable **once roles are set to `inherit-parent`**; hardcoded slugs (e.g. `gpt-5.6-sol-max`) break on machines without those entitlements |
| **poteto-mode** (router)                                                | ⚠️ partial         | References Cursor built-ins (`AskQuestion`, `create-skill`, `deslop`, cursor-team-kit)                                                                                               | Usable in Claude Code with substitutions (unslop, writing-skills); routing logic itself is portable                                        |
| **fusion / codex:rescue**                                               | ❌ by design       | Requires `claude -p` + `codex exec` CLIs installed                                                                                                                                   | Not model-agnostic — that's the point (cross-model checking). Machine-bound, not model-bound                                               |
| **autoresearch** (14)                                                   | ✅ fully           | Process prose                                                                                                                                                                        | Portable                                                                                                                                   |
| **verify / review-changes / design stack / domain packs**               | ✅ mostly          | Depend on project tooling (vitest, tsc) and MCPs, not on the model                                                                                                                   | Portable across models; bound to the _machine's_ tools                                                                                     |

**The verdict:** the best model-agnostic setup is
**superpowers (skeleton) + principle-\* (decision rules) + unlazy (long-run
wrapper) + verify family (gates)** — that stack runs unchanged on any model.
Layer pstack's fan-out tools (arena/swarm/interrogate) on top with
`setup-pstack` roles set to `inherit-parent`, so panels inherit whatever model
the session runs instead of pinning slugs. Reserve fusion/codex for when you
_want_ model diversity, accepting the CLI dependency.

One nuance: multi-model panels (interrogate, arena cross-judges) lose their
diversity benefit when every role inherits the same parent model — you keep the
independent-angles structure but not the different-model blind spots. That's an
acceptable trade for portability; re-pin slugs via `setup-pstack` on machines
where multiple model entitlements exist.

**Measured (pilot bakeoff, 2026-08-29):** one fixed-spec pure-logic task
(pin-map rich paste parser), two arms, same model and base commit, 12 held-out
gates written first, blind judge, pre-committed decision rule. Result:
**statistical tie — 12/12 gates both; judge 22 (superpowers) vs 21 (pstack);
superpowers won the cost tiebreak** (64k vs 75k tokens, 209s vs 235s; pstack
had the smaller diff, 294 vs 415 lines). Both arms independently chose the same
architecture (compose the existing modules) — the process changed details and
tests, not the design. The judge found one triggerable latent bug in the pstack
arm (whitespace collapsed in names) and one dead-today fail-fast violation in
the superpowers arm (error-swallowing catch). Scope: does NOT cover pstack's
fan-out tools (arena/swarm/interrogate), open-ended design, debugging, or
multi-model panels — expect pstack's depth to pay off there, not on fixed-spec
implementation. Full data: pin-map `bakeoff/RESULTS.md`.

---

## 5. TL;DR Card

```
Trivial:         do it → verify → commit
Feature:         brainstorm|architect → plan → TDD (+design stack if UI) → verify → no-comments → review-changes → commit-push-pr
Open design:     arena → then the feature loop        High-stakes spec: council first
Bug:             systematic-debugging → regression test → verify → commit
Untrusted diff:  blast-radius (+ interrogate if contested)
Migration:       figure-it-out + principle-sequence-verifiable-units
Long autonomous: unlazy gates + show-me-your-work → any loop above
Parallel:        swarm (coverage) | arena (competition) | dispatching-parallel-agents (plan tasks)
Resume:          recall + mem-search → route via Phase 1
Question:        how | why | teach — no code changes
Research:        mem-search → context7/firecrawl → write-up (unslop + technical-writing)
Pre-release:     autoresearch:regression | :security          Big PR: pr-review-toolkit:review-pr
Session end:     reflect | hookify | revise-claude-md
```
