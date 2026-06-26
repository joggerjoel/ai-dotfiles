# Getting Started — Onboarding Layer Design Spec

**Date:** 2026-06-26
**Status:** Approved
**Repo:** `claude-dotfiles` (public, genericized)

---

## Overview / Goal

Add a thin onboarding layer so a fresh user who clones the repo and runs `./setup.sh` can "ship code like a 100x engineer" — even with zero coding ability. The layer is an **orchestrator/router skill** plus layered docs and three small wiring edits. It does not re-implement building; it detects intent and experience level, then routes the user through the toolkit's existing engine (brainstorm → plan → build → verify → ship). Because it delegates, it gets better automatically as the underlying skills improve, with zero duplicated logic.

**Hard constraint (public repo):** No personal infrastructure. No IPs, no private hostnames, no usernames, no private project names. All examples are generic. The skill references only skills/plugins that actually exist in this repo and its installed plugin stack — none are invented.

## Target Audience

Public / mixed. Layered depth throughout:

- **True non-coder** — gets hand-holding, plain-language narration, and recommendations made _for_ them (never asked to choose blind).
- **Developer** — can skim past the hand-holding straight to the power-user map and the architecture/extension docs.

Every artifact (skill steps and docs) is structured so each reader self-selects their depth.

## Architecture — Orchestrator, Not a Monolith

The `getting-started` skill is a **router**. Its job is intent + experience-level detection followed by delegation. It explicitly hands off to the real skills/plugins installed by `./setup.sh` and `scripts/bootstrap-plugins.sh`:

| Stage                | Routes into (real, installed)                                                                            |
| -------------------- | -------------------------------------------------------------------------------------------------------- |
| Brainstorm / scope   | `superpowers:brainstorming`                                                                              |
| Plan                 | `superpowers:writing-plans`                                                                              |
| Build (guided)       | `feature-dev` plugin (architect / explorer / reviewer agents)                                            |
| Verify / test        | `superpowers:test-driven-development`, `superpowers:verification-before-completion`, repo `verify` skill |
| UI / design work     | `frontend-design`, `ui-ux-pro-max`, `design-taste`, `color-strategy`, `react-bits`, `uiverse`            |
| Review changes       | `code-review`, `pr-review-toolkit`, `code-simplifier`, repo `review-changes` skill                       |
| Ship (git)           | `commit-commands` (`/commit`, `/commit-push-pr`), `superpowers:finishing-a-development-branch`           |
| Isolation (optional) | `superpowers:using-git-worktrees`                                                                        |
| Memory               | `claude-mem` (persistent cross-session memory)                                                           |

The skill **must read** these skills/plugins to reference them accurately rather than assume their interfaces, and must degrade gracefully if an optional plugin is not installed (route to the nearest installed equivalent or the built-in repo skill).

## Skill Flow + Guardrails

**File:** `skills/getting-started/SKILL.md` (global skill, copied into `~/.claude/skills/` by setup, same frontmatter format as existing skills: `name` + `description`, with `disable-model-invocation` omitted so the model can auto-invoke it).

### Flow

**(a) Orient.** One plain-language paragraph describing what the user now has (Claude Code + this toolkit). Ask **once**: _"Have you coded before? (no judgment — it just sets how much I explain)."_ The answer sets narration depth for the rest of the session.

**(b) Discover intent.** Ask _"What do you want to build?"_ Map the answer through a capped intent → path matrix (~5 common intents max):

| Intent              | Recommended path                                                  |
| ------------------- | ----------------------------------------------------------------- |
| Web app / site      | Next.js, deploy to Vercel                                         |
| API / backend       | Stack appropriate to the request (e.g. Node/TypeScript or Python) |
| Automation / script | Python with `uv`                                                  |
| Mobile app          | Expo (React Native)                                               |
| Not sure            | Scope it via `superpowers:brainstorming`                          |

The skill **recommends for** the user and never makes a non-coder choose blind.

**(c) Workspace.** Scaffold the project, run `git init`, and make a first checkpoint commit so there is always a safe restore point.

**(d) Build loop.** Route into the existing skills (per the architecture table), narrating each step in plain language scaled to the stated experience level.

**(e) Ship.** Run or deploy via the intent-appropriate path (use existing CLIs and the agent's own ability — no new deploy infrastructure is built here).

**(f) Handoff.** Tell the user they can simply describe their next change, and point them to `GETTING-STARTED.md` for the fuller picture.

### Guardrails (baked into every step)

1. **Verify before "done"** — never claim something works without running, testing, or showing it work (anchored by `verification-before-completion` / `verify`).
2. **Git safety-net** — auto-commit working checkpoints; explain each commit in plain language.
3. **Plain-language narration** — depth scaled to the experience level captured in step (a).
4. **Confirm before risky** — warn and require explicit confirmation before anything that spends money, deploys to production, deletes data, or would commit secrets.

## Docs Structure

**File:** `GETTING-STARTED.md` at the repo root, three layered parts so each audience self-selects:

- **Part 1 — Non-coder.** "You don't need to code. Open Claude Code, say _help me get started_." Covers what to expect, how to talk to it, and the four safety nets.
- **Part 2 — The map.** What the toolkit can do: a capability map of the actual installed skills/plugins, the golden workflow (brainstorm → plan → build → verify → ship), and how persistent memory works (`claude-mem`).
- **Part 3 — Power user / dev.** Architecture of the layered `CLAUDE.md` assembly (base + profile + local), the profile system (desktop vs VPS), how to extend (add skills/plugins), and the full enabled-plugin list (core + optional groups from `scripts/bootstrap-plugins.sh`).

## Activation (belt & suspenders)

1. **Skill description** fires the skill on phrasings like "I'm new", "help me get started", "I want to build X", "what can this do".
2. **`setup.sh` completion screen** — the "Setup complete!" output includes the line: _New here? Open Claude Code and say: help me get started_ (plus a pointer to `GETTING-STARTED.md`). This line already exists in `setup.sh`; the wiring edit confirms/retains it.
3. **`README.md` callout** near the top pointing to `GETTING-STARTED.md`.

## Scope / Non-Goals

**Deliverables (only these):**

- `skills/getting-started/SKILL.md` — the orchestrator skill.
- `GETTING-STARTED.md` — the three-part layered doc.
- Two small wiring edits — `setup.sh` (completion-screen line) and `README.md` (top callout).
- This spec document.

**Explicitly NOT building (YAGNI):**

- No deploy infrastructure — lean on existing CLIs and the agent's ability.
- No TUI of any kind.
- No more than ~5 intents in the matrix.
- No duplication of building logic — the skill orchestrates the existing engine; it does not reimplement brainstorming, planning, building, verifying, or shipping.
