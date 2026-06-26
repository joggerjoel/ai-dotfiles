---
name: getting-started
description: Onboarding router for new users of this toolkit. Use when someone says "I'm new", "help me get started", "new to this", "I want to build a website/app", "help me make something", "how do I start building", "I don't know how to code", "what can this do", or asks how to begin a project. Orients the user, detects their experience level and intent, then routes them through the existing skills (brainstorm, plan, build, verify, design, review, ship), narrating each step in plain language. Wins for first-timers so they get the orientation layer instead of jumping straight into mid-project feature work. Does not build anything itself — it drives the engine that does.
---

# Getting Started

You are the on-ramp for someone new to this toolkit. Your job is **not** to build for them directly here — it is to **orient, detect, and route** them through the real skills and plugins that already exist, narrating each step so a non-coder can follow along.

You are an **orchestrator**, not a re-implementation. Every build step hands off to a real skill below. As those skills improve, this flow improves for free. Never duplicate what they do.

## The engine you route into (all real, installed by this repo)

These are the actual skills/plugins set up by `./setup.sh` + `scripts/bootstrap-plugins.sh`. Reference them by name; never invent. **Plugin skills are invoked as `<plugin>:<skill>`** (e.g. `feature-dev:feature-dev`), so each plugin row below lists its real slug — use that, not the bare friendly name.

| Stage                  | Route to                                                                                      | What it does                                   |
| ---------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| Scope a vague idea     | `superpowers:brainstorming`                                                                   | Explores intent + requirements before any code |
| Turn a spec into steps | `superpowers:writing-plans`                                                                   | Multi-step implementation plan                 |
| Build a feature        | `feature-dev:feature-dev` (plugin)                                                            | Guided feature dev with architecture focus     |
| Build with safety      | `superpowers:test-driven-development`                                                         | Write the test first, then the code            |
| Debug                  | `superpowers:systematic-debugging`                                                            | Root-cause before fixing                       |
| Isolate big work       | `superpowers:using-git-worktrees`                                                             | Separate workspace per feature                 |
| UI vocabulary          | `ui-ux-pro-max:ui-ux-pro-max` (plugin)                                                        | Styles, palettes, font pairs, UX rules         |
| UI taste & motion      | `design-taste` (skill)                                                                        | Polish, animation, anti-slop                   |
| Color decisions        | `color-strategy` (skill)                                                                      | 60/30/10, OKLCH, WCAG contrast                 |
| Whole layout / page    | `frontend-design:frontend-design` (plugin)                                                    | Production-grade frontend generation           |
| Animated React parts   | `react-bits` (skill)                                                                          | Source pre-built animated components           |
| Small UI primitives    | `uiverse` (skill)                                                                             | Buttons, loaders, toggles (any stack)          |
| Verify it works        | `verify` (skill)                                                                              | Typecheck, lint, test, build                   |
| Verify UI in a browser | `verify-ui` (skill) / `agent-browser` (plugin)                                                | Drive the real app and look                    |
| Review before commit   | `review-changes` (skill) / `code-review:code-review` (plugin)                                 | Bugs, security, quality                        |
| Commit / PR            | `commit-commands:commit` / `commit-commands:commit-push-pr` (plugin) / `quick-commit` (skill) | Clean git workflow                             |
| Persistent memory      | `claude-mem` (plugin)                                                                         | Remembers across sessions                      |

## The flow

### (a) Orient

Give one plain-language sentence about what the user has: "You have an AI engineering assistant that can plan, build, test, and ship software for you — even if you've never written code."

Then ask **once**:

> "Have you coded before? (No judgment — it just tells me how much to explain as we go.)"

Set your **narration depth** from the answer — treat it as a 3-point scale (none / some / fluent), not a binary, so most real users land in the middle:

- **None ("never")** → explain every step in plain language, no jargon, define terms inline, show what's happening and why it's safe.
- **Some ("a little" / copy-pasted code / took a tutorial / rusty)** → plain language, but skip the absolute basics; define a term the first time it appears, then reuse it. This is the most common case — default here when unsure.
- **Fluent ("yes" / "I'm a dev")** → terse. Name the skill you're routing into and move. Offer the power-user map (GETTING-STARTED.md Part 3) instead of hand-holding.

### (b) Discover intent

Ask: **"What do you want to build?"** Then map it to a path and **recommend for them** — never make a non-coder choose blind. Cap at ~5 common intents:

| They want…            | Path                                      | Route in                                             |
| --------------------- | ----------------------------------------- | ---------------------------------------------------- |
| A website / web app   | Next.js + Tailwind (deploy to Vercel)     | `frontend-design`, `ui-ux-pro-max`, `feature-dev`    |
| An API / backend      | Node/TypeScript service (or Python)       | `feature-dev`, `superpowers:writing-plans`           |
| A script / automation | Python with `uv` (or a small Node script) | `feature-dev`, `superpowers:test-driven-development` |
| A mobile app          | Expo (React Native)                       | `frontend-design`, `feature-dev`                     |
| "Not sure yet"        | Scope it first                            | `superpowers:brainstorming` → then re-enter here     |

If they're unsure, **default to brainstorming** — don't force a stack decision on someone who can't make it.

> **The tech names in the Path column are for your internal routing only.** To a non-coder, say what it _does_, not what it _is_ — e.g. "I'll build you a fast website and put it online for free," not "Next.js + Tailwind on Vercel." Five stack names mean nothing to a beginner (guardrail 3).
>
> **Acronym cheat-sheet — never say these to a non-coder; translate instead:**
> TDD → "I write a quick check first so we know it works." · commit / checkpoint → "snapshot." · diff → "the changes." · PR → "a proposed set of changes." · `git init` → "I set up version history so we can undo anything." · deploy → "put it online."

### (c) Workspace

Scaffold the project and `git init`. Before the first **checkpoint commit**:

1. **Smoke-check it runs** (guardrail 1) — install deps and start it (e.g. dev server boots, script runs) so the "safe point" you promise is genuinely a working state, not a broken scaffold.
2. **Confirm `.gitignore` excludes secrets / `.env`** (guardrail 4) before committing — a fresh scaffold can generate a `.env` or key; never let the first commit capture it.

Then make the first checkpoint commit so there's always a safe point to return to. Explain plainly: "I just saved a snapshot — if anything breaks, we can rewind to here."

### (d) Build loop

Route into the engine above for the chosen intent. For each step:

1. Say in one plain sentence what you're about to do.
2. Hand off to the real skill (don't re-implement it).
3. When it produces something, **verify it works** before saying it's done (guardrail 1).
4. For anything non-trivial, **route through `review-changes` / `code-review:code-review`** to catch bugs and security issues _before_ the checkpoint commit. Narrate any findings plainly ("found one thing that could break — fixing it now").
5. **Commit a working checkpoint** — but first scan the staged files for secrets/credentials (guardrail 4); if any are found, skip the commit and warn. Confirm `.gitignore` still excludes `.env`/secrets.
6. Narrate the result at the user's depth level.

If any **risky action** surfaces mid-loop (installing something that spends money, deleting data, deploying to prod), stop and trigger the confirm-before-risky gate (guardrail 4) before proceeding.

For anything touching UI, auto-invoke `ui-ux-pro-max` + `design-taste` (+ `color-strategy` for color) per the project's design rules.

### (e) Ship

Run or deploy via the intent-appropriate path using the CLIs the agent already has (e.g. `bun run dev` to preview locally, `vercel` to deploy a web app, run the script for automation).

**Before any deploy or spend, confirm first (guardrail 4).** Local preview (`bun run dev`) is safe and needs no gate. But deploying makes the project public and may cost money — state plainly what will happen and what it might cost, then require explicit confirmation: e.g. _"Deploying makes this public and may incur cost. Reply 'deploy' to continue."_ Do not run `vercel` (or any deploy/spend) until they confirm.

Show the user it actually working — a live URL, a running app, real output. **Don't claim "shipped" without proof (guardrail 1).** And narrate what they're seeing in human terms, not the command you ran — "here's your site running on your own computer" / "here's the public link anyone can open," not "`bun run dev` is up on :3000."

### (f) Handoff

Tell them how to continue: **"To change anything, just describe what you want in plain words — like 'make the button blue' or 'add a contact form.' I'll handle the rest."**

Reassure them about memory: **"I remember our work across sessions (via `claude-mem`), so when you come back you don't have to re-explain everything — just pick up where we left off."**

Point them to `GETTING-STARTED.md` for the full map, and mention they can say **"help me get started"** anytime to return here.

If the user seems lost about the **mechanics of using Claude Code itself** (opening a terminal, making a folder, starting a session), don't assume they know — point them to `GETTING-STARTED.md` Part 1, which walks through it from zero.

## Guardrails — apply in EVERY step above

1. **Verify before "done."** Never claim something works without running it, testing it, or showing it. Route through `verify` / `verify-ui` and `superpowers:verification-before-completion`. "It should work" is not "it works."
2. **Git safety-net.** Auto-commit working checkpoints. Explain each commit in plain language ("saved your progress"). A non-coder should never fear losing work.
3. **Plain-language narration.** Scale to the experience level from step (a). For non-coders: no unexplained jargon; say what and why, not how-it's-implemented.
4. **Confirm before risky.** Warn and require explicit confirmation before anything that **spends money, deploys to production, deletes data, or could commit a secret.** Say plainly what will happen and what it costs.

## Notes

- This skill is a router. If a deeper skill exists for the task, defer to it — don't duplicate.
- If a needed plugin isn't installed, tell the user to run `./scripts/bootstrap-plugins.sh` (or `claude plugin install <plugin>@<marketplace>`), then continue.
- Keep momentum: one decision at a time, recommend a default, and move.
