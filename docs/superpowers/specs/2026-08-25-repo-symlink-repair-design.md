# Repo symlink repair — self-healing links in update.sh

**Date:** 2026-08-25
**Status:** approved, not yet implemented

## Problem

Every Claude Code session on aorus7 failed two Stop hooks:

```
/bin/sh: 1: /home/joggerjoel/.claude/scripts/code-simplifier-gate.sh: not found
/bin/sh: 1: /home/joggerjoel/.claude/hooks/cache-guard.sh: not found
```

Both hooks existed. Both were registered correctly in `settings.json`, by
`$HOME` path. The symlink one level below had broken: `~/.claude/scripts/` and
`~/.claude/hooks/` still pointed at `~/ai-dotfiles/`, but the checkout had moved
to `~/Developer/ai-dotfiles/`. Twenty-four links dangled — every hook, every
script, `statusline.sh`, and `~/.local/bin/isolate`.

A fleet survey found aorus7 alone in this state. The other five reachable Linux
nodes keep the checkout at `~/ai-dotfiles`, where `setup.sh` first put it;
aorus2 and aorus3 were powered off. macstudio carried two dangling links of a
different kind, described under [Orphans](#orphans).

Nothing detected any of this. Hooks fail non-fatally, so sessions kept running
and the breakage surfaced only in stop-hook stderr.

## Root cause

Two failures compound.

**The link layer is the coupling point.** `settings.json` is path-portable — it
references `$HOME/.claude/hooks/cache-guard.sh` and never names the checkout.
The symlink underneath hardcodes the checkout path. Move the repo and every link
breaks at once, silently.

**`setup.sh update` does not repair them.** `cmd_update` re-links
`statusline.sh` and `scripts/*.sh`, but never calls `link_claude_hooks`,
`link_bin_tools`, or `link_codex_prompts`. Running it on aorus7 would have fixed
21 of the 24 links and left `cache-guard.sh`, `injection-guard.py`, and
`isolate` broken through any number of updates. The comment on
`link_claude_hooks` (setup.sh:805-807) already predicts the exact symptom:

> The shared profile settings.json references these by `$HOME` path, so a
> machine that skips this step gets a "No such file or directory" PreToolUse
> error on every Bash call.

`update.sh` touches no links at all.

## Design

### lib/links.sh

One file defines every repo-owned link. It follows the `lib/integrations.sh`
precedent: sourced, never executed, no side effects at source time. It assumes
the caller has defined `DOTFILES_DIR`, `CLAUDE_DIR`, and the `ok`/`warn`/`skip`
helpers, which both `setup.sh` and `update.sh` already do.

Moved verbatim from `setup.sh`:

- `link_file`
- `link_bin_tools` — `bin/*` → `~/.local/bin/`
- `link_claude_hooks` — `hooks/*.{sh,py}` → `~/.claude/hooks/`
- `link_codex_prompts` — `codex/prompts/*.md` → `~/.codex/prompts/`

Added:

- `link_repo_scripts` — `scripts/*.sh` → `~/.claude/scripts/`, extracted from
  the loop copy-pasted at setup.sh:996 and setup.sh:1448. One bug surface today
  becomes one definition.
- `relink_all` — runs the four linkers plus `statusline.sh`, then reports.
- `prune_orphan_links` — removes links the repo created whose source has left.

### Change detection in link_file

`link_file` gains an early return: when `dst` is already a symlink whose
`readlink` equals `src`, it touches nothing and prints nothing.

Signalling "unchanged" through a non-zero return would abort both scripts under
`set -euo pipefail` at every bare call site. So `link_file` always returns 0 and
reports through two counters, `LINK_RELINKED` and `LINK_OK`.

This also stops the current churn, where every run removes and recreates all 24
links whether or not anything changed.

### Orphans

Relinking repairs anything the repo still owns. It cannot touch a link whose
source has left the repo. macstudio held two of these: `herdr-node.sh` and
`herdr-remote.sh` pointed into `ai-dotfiles/scripts/`, but commit `d21a9c2`
moved that tooling to a sibling `~/Developer/herdr` checkout. Nothing removes
such a link, so it dangles forever.

`prune_orphan_links` walks four managed directories — `~/.claude/scripts`,
`~/.claude/hooks`, `~/.local/bin`, `~/.codex/prompts` — and tests each dangling
link's `readlink` against `*/ai-dotfiles/*`:

| Target | Meaning | Action |
| --- | --- | --- |
| Inside an `ai-dotfiles` checkout | The repo created it; the source is gone | Remove, and report |
| Anywhere else | Another tool's, or hand-made | Keep, and report |

The rule deletes only what the repo can prove it created. A checkout cloned
under a different directory name fails the match and is reported rather than
removed — the safe direction.

`~/.claude/debug/latest` sits outside the managed directories, so the scan never
considers it. Claude Code owns that pointer and rewrites it each session.

### Call sites

**update.sh** gains a `# ── 1b. Repo links ──` section, after the backup and
before the upgrade. It matches the existing `3b`/`3c`/`3f` sub-step convention,
and running early means the rest of the update has working hooks. `--dry-run`
reports what would change and mutates nothing.

**setup.sh `cmd_update`** gains the three linkers it never called, and swaps the
inline scripts loop for `link_repo_scripts`. This is the root-cause fix: it
closes the gap for the fleet, which reaches `cmd_update` through
`ansible-ai/update.yml`.

## Output

A fresh install prints every link, because every link is a change. A clean
update prints one line:

```
Repo links
  ✓ 27 links verified
```

A repaired update names what moved:

```
Repo links
  ✓ code-simplifier-gate.sh -> scripts/code-simplifier-gate.sh
  ✓ cache-guard.sh -> hooks/cache-guard.sh
  ...
  ✓ 24 repointed, 3 verified
  ✓ pruned herdr-node.sh (source left the repo)
  ! ~/.local/bin/foo dangles and is not ours -> /opt/foo (left alone)
```

## Error handling

The step never fails the update. A missing `~/.codex` directory, an unwritable
`~/.local/bin`, an absent `bin/` — each is a `warn` and the run continues, in
keeping with how `update.sh` already treats the 9router re-vendor and the
backup prune. An upgrade is not broken because one link could not be written.

## Testing

`tests/preflight/run.sh` already supplies the harness: temp-directory
registration through `add_cleanup_dir`, and `report pass|fail`. Each case builds
a throwaway `HOME` and a throwaway checkout.

1. A dangling link is repointed at the current checkout.
2. A correct link is left untouched and prints nothing.
3. An orphan pointing into `ai-dotfiles` is pruned.
4. A dangling link pointing elsewhere is kept and reported.
5. A second run changes nothing and reports only verified counts.
6. `--dry-run` reports the repair and leaves the link dangling.

## Out of scope

A read-only links check in `scripts/preflight.sh`, so `just preflight` reports
drift on a machine that never runs `update.sh`. Worth doing, and a separate
change.

## Decisions

**Relink from source of truth, not scan-and-repoint.** Rewriting a stale prefix
in place is heuristic: it cannot repair a link that points somewhere wrong yet
still resolves, and it duplicates knowledge that `setup.sh` already holds.
Re-running the canonical linkers is both simpler and strictly more correct.
`link_file` is already idempotent, so the repair needs no detection pass.

**Prune only what we owned.** Deleting every dangling link in the managed
directories self-heals the most, and would also delete a link another tool
placed there.

## Follow-up

aorus7 is the only Linux node with the checkout at `~/Developer/ai-dotfiles`;
the other five use `~/ai-dotfiles`. This design repairs either layout, but the
fleet should settle on one. aorus2 and aorus3 were unreachable during the survey
and still need a pass.
