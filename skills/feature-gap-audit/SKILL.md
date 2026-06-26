---
name: feature-gap-audit
description: Compare the current state of a project against reference projects (predecessor versions, related open-source, internal in-flight branches) to surface missing features. Use when asked to "audit features", "find what's missing", "compare to v1/v2/old version", "feature gap", or to refresh a cumulative gap log. Outputs to a project-local cumulative living document, not a fresh report each time.
---

# Feature Gap Audit (generic methodology)

A reusable methodology for auditing what's missing in a current project relative to reference projects. Designed for monorepos with long-lived feature branches and multiple deployments.

When invoked, **also load any project-local override** at `<repo>/.claude/skills/feature-gap-audit/SKILL.md` for pinned references, worktree paths, and output location. The project skill controls *what to audit*; this skill controls *how*.

## Core principles

1. **Cumulative over snapshot.** Audits accumulate into one living document. Re-running reconciles state — it doesn't replace it. This is the most important property: it's how the audit stays cheap to re-run.
2. **`main`/`dev` is rarely the whole picture.** Always survey feature branches, worktrees, and production deployments alongside the trunk. Stranded work in feature branches is a common source of "we already built that — wait, where is it?".
3. **Code is not the whole picture either.** Search session/conversation history (e.g., claude-mem) for context that explains *why* work was started, paused, or never merged.
4. **Classify, don't fix.** The audit produces a prioritized list of gaps. Implementation happens after, in separate sessions.

## Output structure

The skill expects (or creates) this directory under the repo:

```
docs/<engineering|architecture|wherever>/feature-gap-audit/
├── README.md              # Methodology + how to run
├── references.md          # Reference projects we compare against
├── CURRENT.md             # ✨ The living gap log — single source of truth
└── runs/YYYY-MM-DD.md     # Point-in-time snapshot per run
```

**`CURRENT.md` is the deliverable users return to.** Everything else is supporting material.

### `CURRENT.md` skeleton

```markdown
# Feature Gap Audit — Current State

**Last run:** YYYY-MM-DD
**Run snapshot:** runs/YYYY-MM-DD.md

## TL;DR

2-4 sentences on the most important framing. Often: "X looks missing but is actually built on branch Y" or "the highest-leverage move is merging Z".

## Gap log

Sorted by priority within status groups:

### 🟢 Shipped on main/dev
### ✅ Built (unmerged) — exists somewhere, not on trunk
### 🟡 In progress — partial implementation, active branch
### ❌ Not started — gap vs reference, no work yet

Within "Not started", group by reference source so it's clear what came from where.

## Recommended priority order

Numbered list: the immediate sequence that closes the most gaps with least effort.

## Run history

Table: date → snapshot file → trigger.
```

## The run loop

### 1. Read `CURRENT.md` first

If it doesn't exist, this is a first run — create the directory structure from the skeleton. If it exists, treat the audit as a **delta**: what's changed since the last run?

### 2. Identify what to survey

From the project-local skill (or first-run discovery):

- **External references** — predecessor repos, related open-source projects, anything explicitly named.
- **Internal in-flight work** — `git worktree list`, plus feature branches that haven't merged.
- **Production deployments** — sometimes a deployment runs from a feature branch, not trunk.

### 3. Dispatch parallel research

For each thing to survey, dispatch a research agent (Explore, general-purpose, or appropriate subagent). Send them in a single message so they run concurrently — typically 3-6 agents.

Each agent should return: routes, features, schema, integrations, components, stubs, completion state. Cite file paths.

For external GitHub repos, prefer `gh api` over WebFetch (faster, authenticated, structured).

### 4. Search session/conversation history

If the project has claude-mem or a similar memory tool, search it for context on:

- Work that shipped but didn't merge
- Branches that paused (and why)
- Architectural decisions that explain current state

### 5. Reconcile against `CURRENT.md`

For each gap in the existing log, check if its status changed:

- A "Not started" item turns out to exist on a branch → promote to "Built (unmerged)" with branch reference
- A "Built (unmerged)" item got merged → promote to "Shipped"
- A "In progress" item got abandoned → leave it but note the abandonment

For each new gap discovered, add under the appropriate status group with priority + source.

**Never delete entries.** Move them through the lifecycle. History matters.

### 6. Write a run snapshot

`runs/YYYY-MM-DD.md` captures:

- The trigger (what was the user asking)
- Methodology actually used (which agents dispatched, what queries)
- Critical findings unique to this run
- Conversation context — what would be lost if we reset
- Open questions for the next run

This is what makes the audit cumulative — the snapshot is the *why* behind the diff to `CURRENT.md`.

### 7. Update `CURRENT.md` header + run history

Bump "Last run", point at the new snapshot, add a row to the run history table.

## When to re-run

- Major branch merges (especially when feature branches land on trunk)
- New reference projects are added
- Quarterly sanity check
- Before scoping a roadmap milestone

The skill is idempotent. Re-running it just reconciles state — if nothing changed, the diff to `CURRENT.md` is empty.

## Anti-patterns to avoid

- **Auditing only the trunk branch.** This is the #1 way to miss work. Always survey worktrees and feature branches.
- **Producing a fresh report each time.** The whole value is accumulation. Update `CURRENT.md` in place.
- **Implementing during the audit.** Audit is classification. Implementation is a separate session.
- **Skipping memory/session search.** Code shows what exists; memory explains what was attempted.
- **Long unstructured prose.** Tables and lists with explicit priorities + sources are how this gets used. Save the prose for the snapshot's "conversation context" section.

## Project-local skill template

When initializing the audit on a new project, also write a local skill at `.claude/skills/feature-gap-audit/SKILL.md` with this shape:

```markdown
---
name: feature-gap-audit
description: <project-specific description>
---

# Feature Gap Audit (project-specific)

## Pinned config

### Reference repos
- `<owner>/<repo>` — <one-line why>

### Worktrees to always survey
- `<branch>` — <one-line what>

### Production deployments to spot-check
- `<url>` — <runs from which branch>

### Output location
- `<path/to/CURRENT.md>`

## Project-specific gotchas
<things the generic methodology won't know>

## How to run
Apply the global skill methodology with the pinned config above.
```

This split (generic methodology in global, project specifics in local) follows the reusable-first principle — methodology is reusable across projects, while branch names and deployment URLs are not.
