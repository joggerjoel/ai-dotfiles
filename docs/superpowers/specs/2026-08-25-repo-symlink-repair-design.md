# Repo symlink repair — detect drift, then repair it

**Date:** 2026-08-25
**Status:** draft, council-reviewed, restructured

Two changes, in order. A third is deferred to its own spec.

1. **Detect** — `scripts/preflight.sh` gains a read-only links check. Nothing on
   the fleet reports link drift today; this is the only piece that would have
   caught the incident without anyone running anything.
2. **Repair** — `lib/links.sh` holds every repo-owned link, and all three entry
   paths call it.
3. **Deferred: prune** — removing links whose source left the repo. Split out
   after review: it is the only irreversible act in the design, its evidence is
   two stale links on one machine, and its guards carried the two critical
   findings of the review. It gets its own spec or it does not get built.

Two entry points are easy to confuse:

- **`./update.sh`** — the top-level upgrade script. Gains repair; has none today.
- **`./setup.sh update`** (`cmd_update`) — the config-refresh subcommand the fleet
  runs through `ansible-ai/update.yml`. Already links, through a fragile path.

## Problem

Every Claude Code session on aorus7 failed two Stop hooks:

```
/bin/sh: 1: /home/joggerjoel/.claude/scripts/code-simplifier-gate.sh: not found
/bin/sh: 1: /home/joggerjoel/.claude/hooks/cache-guard.sh: not found
```

Both hooks existed, and `settings.json` referenced them correctly by `$HOME`
path. The per-file symlinks beneath had broken: each link in `~/.claude/scripts/`
and `~/.claude/hooks/` still pointed into `~/ai-dotfiles/`, but the checkout had
moved to `~/Developer/ai-dotfiles/`. Twenty-four links dangled — 20 scripts,
2 hooks, `statusline.sh`, and `~/.local/bin/isolate`.

A fleet survey found aorus7 alone in this state among the six reachable Linux
nodes; the other five keep the checkout at `~/ai-dotfiles`. aorus2 and aorus3
were powered off and remain unsurveyed.

The failures printed to stderr on every session for weeks. Hooks fail
non-fatally, so sessions kept running and **nothing ever looked**.

## Root cause

**The link layer is the coupling point.** `settings.json` is path-portable — it
names `$HOME/.claude/hooks/cache-guard.sh` and never the checkout. The symlink
underneath hardcodes the checkout path. Move the repo and every link breaks.

**Nothing detects it.** No check, no test, no run reports a dangling link. This
is the root cause of the *incident*: `setup.sh update` would have repaired
aorus7 — `cmd_update` reaches every linker — but nobody knew to run it.

**`update.sh` cannot repair it.** It upgrades CLIs, re-vendors skills, prunes
backups, then verifies with `preflight.sh`. A drifted machine can run it forever.

**And the linkers hide behind an unrelated guard.** `cmd_update` reaches
`link_codex_prompts`, `link_claude_hooks`, and `link_bin_tools` only as a side
effect of `link_agent_instructions` (setup.sh:786-788), which returns early when
`~/.claude/CLAUDE.md` is absent:

```bash
link_agent_instructions() {
  local canonical="$CLAUDE_DIR/CLAUDE.md"
  [ -f "$canonical" ] || { warn "CLAUDE.md not found; skipping agent-instruction symlinks"; return 0; }
  ...
  link_codex_prompts
  link_claude_hooks
  link_bin_tools
}
```

Hook installation is conditional on a file unrelated to hooks. No surveyed
machine hit this, so it is hygiene, not evidence — but the fix falls out of
phase 2 for free rather than needing its own change.

## Phase 1 — detection

`scripts/preflight.sh` gains a `repo links` check. Read-only: it reports and
never writes, like every other preflight check. It runs from `just preflight`,
`just audit`, and the verification step already at the end of `update.sh`.

It reports two conditions across the managed paths — `~/.claude/scripts`,
`~/.claude/hooks`, `~/.local/bin`, `~/.codex/prompts`, `~/.claude/statusline.sh`:

**Dangling** — a symlink whose target does not resolve.

**Stale but resolving** — a symlink that resolves, but whose target has an
`ai-dotfiles` path component and does not lie under the current `$DOTFILES_DIR`.
This matters more than it looks: had `~/ai-dotfiles` still existed after the
aorus7 move, every link would have resolved to the *old* checkout and the
incident would have been invisible to a dangling-only check. The design would
have detected nothing.

Both counts appear in the check line; a non-zero count fails the check and names
the repair command. Per the existing preflight contract, `--quarantine` does not
apply — this is not an MCP server and is never auto-disabled.

## Phase 2 — repair

### lib/links.sh

One file defines every repo-owned link, following the `lib/integrations.sh`
precedent: sourced, never executed, no side effects at source time.

**Caller contract.** The caller defines `DOTFILES_DIR`, `CLAUDE_DIR`, and the
`ok`/`warn`/`skip` helpers. `relink_all` asserts them on entry
(`: "${DOTFILES_DIR:?}" "${CLAUDE_DIR:?}"`) and fails loudly rather than
misbehaving quietly. **Both** `setup.sh` and `update.sh` gain a
`source "$DOTFILES_DIR/lib/links.sh"` line in their header block, ahead of any
caller. The lib derives `~/.local/bin` and `~/.codex/prompts` from `$HOME` — the
tools that read them fix those paths.

**Interpreter ceiling.** `#!/bin/bash` resolves to bash 3.2.57 on macOS, so
`lib/links.sh` must run under bash 3.2. No `declare -A`, no `mapfile`, no
`${x^^}`. Current `setup.sh`/`update.sh` already satisfy this.

Moved from `setup.sh` unmodified: `link_bin_tools`, `link_claude_hooks`,
`link_codex_prompts`, `link_agent_instructions`.

Moved and changed: `link_file`.

Added:

- `link_statusline` — `statusline.sh` → `~/.claude/statusline.sh`. It re-tests
  `[ -L "$dst" ]` before `chmod +x` and skips the chmod entirely under dry run,
  so it never chmods through a link that was refused or deliberately not made.
- `link_repo_scripts` — `scripts/*.sh` → `~/.claude/scripts/`, extracted from the
  loop duplicated at setup.sh:996 and :1448.
- `relink_all` — the single entry point.

### relink_all

It resets the counters, runs every linker including `link_agent_instructions`,
then prints one summary.

Folding `link_agent_instructions` *inside* `relink_all` rather than before it is
what makes the accounting sound. Called before, its `link_file` failures would
increment `LINK_FAILED` and then be erased by the reset, so a failed `AGENTS.md`
link would print under `0 failed` — the review's broadest finding. Inside, every
link is counted once, there is one summary, and `update.sh` gains the ability to
repair the four `AGENTS.md` links, which it otherwise could not reach at all.
`link_agent_instructions` keeps its own `CLAUDE.md` guard, which is correct for
`AGENTS.md` — a symlink *to* `CLAUDE.md` — and now gates only those four links.

### Counters

Four: `LINK_CHANGED` (created or repointed), `LINK_OK`, `LINK_SKIPPED`,
`LINK_FAILED`. `relink_all` **assigns each to 0** on entry — not `${VAR:-0}`,
which does not stop an exported value from leaking in: `LINK_CHANGED=7 bash -c
'echo ${LINK_CHANGED:-0}'` prints `7`. Increments use
`LINK_FAILED=$(( LINK_FAILED + 1 ))`, never `(( x++ ))`, which returns non-zero
on a zero result and aborts under `set -e`.

Every outcome has a counter and a slot in the summary, so a machine whose source
directory vanished reads as skipped rather than healthy.

### Change detection in link_file

`link_file` gains an early return: when `dst` is already a symlink whose
`readlink` equals `src`, it increments `LINK_OK` and prints nothing. This ends
the churn where every run removes and recreates every link.

String equality is sound because every `src` is built as
`$DOTFILES_DIR/<subdir>/<name>` and both entry scripts resolve `DOTFILES_DIR`
with `cd … && pwd -P` at startup. Links are read with bare `readlink`, never
`readlink -f` — bare `readlink` prints a link's own target identically on GNU and
BSD, while `-f` differs.

`link_file` always returns 0; signalling through exit status would abort both
scripts at every bare call site under `set -e`. Callers that need to know what
happened read the counters or re-test the destination, which is what
`link_statusline` does.

**Edge cases.** `src` missing → `skip`, no link created. `dst` a directory →
`warn` + `LINK_FAILED`, left alone (today it falls through to `ln -s`, which
would create the link *inside* it). `dst` a regular file → backed up to
`~/.claude/.backups/`, which `link_file` creates with `mkdir -p` rather than
assuming. Replacement uses `ln -sfn` so the destination is never momentarily
absent. A missing *source* directory is a `skip`; a missing *destination*
directory is created; only an unwritable destination is `LINK_FAILED`.

### Call sites

Three code paths across two scripts, each calling `relink_all` and nothing else:

1. **`update.sh`** — new `# ── 1b. Repo links ──` section. Steps are 1 Backup,
   2 Upgrade, 3 Sibling CLIs (3b–3f), 4 9router skills, 5 Prune backups, 6 Fleet,
   then an unnumbered `preflight.sh` verification. 1b sits between 1 and 2,
   borrowing the letter-suffix style of 3b–3f. `--dry-run` exports
   `LINKS_DRY_RUN`; the lib treats any non-empty value as dry run and prints a
   `(dry run)` marker in the summary, so intended work is never mistaken for
   performed work.
2. **`setup.sh` fresh install** — replaces the open-coded statusline call and
   scripts loop at setup.sh:992-1000.
3. **`setup.sh cmd_update`** — replaces the same pair at setup.sh:1445-1453.

A failed `git pull` in `cmd_update` warns and continues into `relink_all`: links
against the existing tree are still correct, and refusing to repair because a
fetch failed is the wrong trade.

## Output

`ok` (`✓`) for a link now correct, `warn` (`!`) for anything wanting attention,
`skip` (`○`) for work that does not apply. The summary prints one fixed field
set, always, with zero-valued fields included; the glyph carries clean vs. dirty.

```
Repo links
  ✓ 0 changed, 27 verified, 0 skipped, 0 failed
```

```
Repo links
  ✓ cache-guard.sh -> hooks/cache-guard.sh
  ✓ code-simplifier-gate.sh -> scripts/code-simplifier-gate.sh
  ...
  ! 24 changed, 3 verified, 0 skipped, 0 failed  (repaired from ~/ai-dotfiles)
```

A run that repairs is a `warn`, not an `ok`, and names the stale prefix it
repaired from. Twenty-four silent repairs under a `✓` would hide exactly the
condition that caused the incident.

## Error handling

The step never fails the update, matching how `update.sh` treats the 9router
re-vendor and the backup prune. Every warn increments exactly one counter, and
the summary always prints, so no warn is discoverable only from scrollback.

## Testing

A new `tests/preflight/links_fixture.sh` supplies the caller contract
`lib/links.sh` requires — `DOTFILES_DIR` and `CLAUDE_DIR` pointing at a throwaway
checkout and `HOME`, plus capturing `ok`/`warn`/`skip` stubs. `tests/preflight/run.sh`
sources it and registers the cases below; `just test` runs them.

**Linking**

1. A dangling link is repointed at the current checkout.
2. A correct link is untouched, prints nothing, counts as verified.
3. `dst` is a directory → refused, `LINK_FAILED`, directory survives.
4. `dst` is a regular file → backed up to `~/.claude/.backups/`, then replaced.
5. `src` missing → skipped, no link created, no chmod attempted.
6. A missing source directory is skipped, not failed.
7. A second run changes nothing and reports only verified counts.

**Counters**

8. An exported `LINK_CHANGED=7` in the environment does not leak into the summary.
9. Every outcome in cases 1-6 lands in exactly one counter, and the four sum to
   the number of links attempted.

**Dry run**

10. `LINKS_DRY_RUN=1` reports a repoint, leaves the link dangling, and does not
    abort — the `link_statusline` chmod is skipped.
11. The dry-run summary carries its `(dry run)` marker.

**Wiring** — the regression this change exists to prevent

12. `cmd_update --no-pull` links hooks when `~/.claude/CLAUDE.md` is absent.
    `--no-pull` is required: a throwaway checkout has no remote.
13. `link_agent_instructions` still skips the `AGENTS.md` links when `CLAUDE.md`
    is absent — the guard it should keep.
14. `update.sh` and both `setup.sh` paths each source `lib/links.sh` and call
    `relink_all`. Asserted statically by grepping each entry script; running
    `update.sh` end-to-end would perform real CLI upgrades.

**Detection**

15. `preflight.sh` reports a dangling link and fails the check.
16. `preflight.sh` reports a stale-but-resolving link into an old checkout that
    still exists — the case a dangling-only check misses.
17. `preflight.sh` writes nothing: the fixture tree is byte-identical after.

## Deferred

**Pruning** (`prune_orphan_links`) — its own spec, or not built. Removing a link
whose source left the repo is irreversible and nothing in the repo backs up a
symlink before deletion, unlike the regular-file path which backs up to
`~/.claude/.backups/`. Until then, phase 1 reports unrepairable links and a
person deletes them.

**Concurrency** — nothing prevents a fleet run and a local run relinking
simultaneously. `ln -sfn` makes each individual replacement atomic, which is
sufficient while nothing deletes.

## Decisions

**Detection before repair.** The incident was not caused by a missing repair
path — `setup.sh update` had one. It was caused by nothing ever looking. A repair
in two scripts nobody demonstrably runs does not close that; a check in the
verifier that already runs does.

**Relink from source of truth, not scan-and-repoint.** Rewriting a stale prefix
in place cannot repair a link that points somewhere wrong yet still resolves, and
duplicates knowledge `setup.sh` already holds.

**No deletion in this change.** Deletion carried both critical findings of the
council review, on evidence of two stale links on one machine. Report first;
decide on automation once phase 1 shows how often it actually happens.

## Follow-up

Operational, not part of this change: aorus2 and aorus3 were powered off during
the survey and still need a pass — by this document's own logic they could be in
aorus7's state. Acceptance is a fleet `ansible-ai/update.yml` run with every node
reporting a clean links check.
