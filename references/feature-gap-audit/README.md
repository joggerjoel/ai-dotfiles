# Feature Gap Audit

Cumulative comparison of ai-dotfiles against reference projects. `CURRENT.md` is the
living gap log; `runs/` holds one snapshot per run; `references.md` lists what we
compare against. Methodology: the global `feature-gap-audit` skill, configured by
`.claude/skills/feature-gap-audit/SKILL.md` in this repo.

This lives under `references/` rather than `docs/` because the log is only useful if it
accumulates across machines and reclones — `docs/` is gitignored. It holds comparisons of
public repos, not personal context.

Re-run with `/feature-gap-audit <reference>`.
