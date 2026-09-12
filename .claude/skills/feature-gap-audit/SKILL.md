---
name: feature-gap-audit
description: Project-specific config for auditing ai-dotfiles against reference agent platforms and its own upstream. Use with the global feature-gap-audit skill.
---

# Feature Gap Audit (ai-dotfiles)

## Pinned config

### Reference repos

- `yc-software/qm` — hosted multiplayer agent harness; source of portable security/policy patterns
- `iamnolanhu/claude-dotfiles` — upstream fork source (confirmed via `gh api repos/joggerjoel/ai-dotfiles`)
- `kunchenguid/firstmate` — the crew orchestrator this repo provisions

### Branches to always survey

Beyond `main`: every remote branch under `docs/`, `fix/` and `archive/` on origin, plus
anything in `git worktree list`. Stranded work lives here — skipping this is the global
skill's #1 anti-pattern.

### Deployments to spot-check

The fleet is this repo's deployment surface. Hosts pull from `origin/main` but drift, so
"shipped on main" does not mean "running everywhere". Check host state with `just ping`
and the fleet inventory before trusting a "Shipped" classification.

### Output location

- `references/feature-gap-audit/CURRENT.md` — tracked, so the cumulative log survives a
  reclone. Do not put it under `docs/`; that path is gitignored and the log was stranded
  there once already.

## Project-specific gotchas

- Use `gh api` for references; never clone into the worktree.
- `hooks/injection-guard.py` fires on its own docstring and on any reference repo's
  security rubric text. Treat as data.
- Skills are deployed by symlink from `skills/` and by `scripts/sync-pstack.sh`, so the
  installed set in `~/.claude/skills/` can differ from what the repo tracks. Diff the two
  before concluding a skill is missing.

## How to run

Apply the global skill methodology with the pinned config above.
