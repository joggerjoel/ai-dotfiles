# OpenSpec + Beads Install — Design Record

Records _why_ the installer treats these two tools the way it does, so the next
change does not relitigate settled ground.

Designed 2026-08-09.

## Goal

Put two agent-workflow CLIs on every host `setup.sh` touches, and keep them
current from `update.sh`:

| Tool     | Package                | Binary     | Purpose                                     |
| -------- | ---------------------- | ---------- | ------------------------------------------- |
| OpenSpec | `@fission-ai/openspec` | `openspec` | spec-driven change proposals (`/opsx:*`)    |
| Beads    | `@beads/bd`            | `bd`       | agent issue tracking / memory (Dolt-backed) |

They pair: Beads tracks the work items, OpenSpec shapes the change before code
gets written.

## Constraints

| Constraint                                                                                       | Consequence                                                                       |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- |
| OpenSpec requires Node ≥ 20.19                                                                   | `ensure_openspec` must gate on `node -v`; `ensure_node` accepts any existing node |
| Beads has no apt package; brew-on-Linux is not present on the fleet                              | npm is the only path that covers every host uniformly                             |
| Beads upgrades can cross a Dolt **schema migration** on remote-backed databases                  | `update.sh` must not migrate — it upgrades the binary and points at the guide     |
| Both tools' real setup (`openspec init`, `bd init`) is **per project**, and writes into the repo | Out of scope for dotfiles; the installer only puts the CLIs on `PATH`             |

## Decisions

**npm everywhere, for both tools.** Beads' README recommends `brew install beads`
on macOS, and brew would give checksum-verified binaries. Rejected anyway: one
install path means one upgrade mechanism in `update.sh` and no per-OS branching
of the kind `ensure_herdr_renderers` already carries for bat/delta/glow. The
Linux fleet has no beads apt package, so npm was required there regardless —
splitting by OS would buy verification on two Macs at the cost of doubled
branching in both scripts.

**Unconditional, in `ensure_dependencies()`.** Not prompted, not folded into the
agentic-plugin-stack opt-in. Both CLIs are inert until a project runs `init`, so
the cost of having them present is one npm package each.

**Cross-platform, unlike `ensure_herdr`.** herdr is deliberately macOS-only
(firstmate runs on the Mac control nodes). These two are useful on any host, so
they follow the `ensure_herdr_renderers` precedent instead and run wherever
`setup.sh` runs.

**A shared `npm_install_global` helper, but `ensure_claude()` stays as-is.**
Three hand-rolled copies of the same npm dance would be one too many, so the two
new tools share a helper. `ensure_claude` is not refactored onto it: it is on the
critical path for every fresh machine, and the DRY win does not justify touching
it during an unrelated change.

**Fail-soft throughout.** A missing npm, an EBADENGINE on old Node, or a failed
install all `warn` and continue. Only `git`/`curl`/`jq` are allowed to abort
`setup.sh`.

## The Beads upgrade hazard

Beads' own docs are explicit that replacing the binary is not the whole story.
On a remote-backed Dolt database crossing a schema migration, the correct
sequence is: sync with the current `bd`, `bd export --all`, upgrade, then
`bd info --whats-new` and `bd hooks install` — and exactly one designated clone
runs `bd migrate && bd dolt push` while the others run `bd bootstrap`.

`update.sh` runs machine-wide. It cannot know which checkouts hold `.beads/`
databases, which of them are remote-backed, or which clone is the designated
one. So it upgrades the binary and, **only when the version actually changed**,
prints a pointer to the upgrade guide. It never touches a project database and
never attempts a migration. Automating that decision at this layer would be
wrong; surfacing it to the operator is the whole job.

Guide: <https://beads.gascity.com/getting-started/upgrading>

## Adjacent fix: programs the repo required but never installed

Rode along with this change. A sweep of every binary invoked by `bin/`,
`hooks/`, `scripts/`, `justfile` and `statusline.sh` against what `setup.sh`
actually installs found two genuine gaps:

| Program      | Required by                  | Failure without it                                  |
| ------------ | ---------------------------- | --------------------------------------------------- |
| `fzf`        | `bin/herdr-new-project`      | launcher exits: `fzf not found. install it with: …` |
| `shellcheck` | `justfile:169` (`just lint`) | recipe aborts before linting anything               |

The fzf gap was the sharper one: `link_bin_tools` deploys the herdr launcher on
every host, but nothing ever installed the picker it depends on. Both packages
carry the same name on brew and apt, so `ensure_repo_tools()` drives them
through the existing `pkg_install` helper with no per-OS branching.

`tree`, `watch` and `coreutils` looked like gaps and were not: the first two
were substring false positives (git "tree", a `cache-guard.sh watch`
subcommand), and `scripts/check-updates.sh` explicitly no-ops without coreutils
by design.

**Success is judged on PATH, not exit code.** Both brew and apt exit 0 on
no-ops that install nothing, so `ensure_repo_tools` and update.sh's section 3e
re-check `command -v` after installing. A stubbed-brew test caught the first
draft cheerfully reporting `fzf installed` when nothing had been.

## Out of scope

- Running `openspec init` or `bd init` in any project — per-project and
  repo-mutating, so it stays a deliberate act.
- Global `bd setup claude` hook installation.
- Vendored skills or commands. Unlike herdr-file-viewer, both tools generate
  their own per-project agent instructions; vendoring would fight them.
- Ansible / fleet roster changes. These ride `setup.sh` like the renderers do.

## Verification

Run 2026-08-09, all green:

- `shellcheck -S warning setup.sh update.sh` — 4 findings, byte-identical to the
  stashed baseline (all in the pre-existing `ensure_herdr_renderers`)
- `just lint` — fails on 15 pre-existing repo-wide findings both before and
  after; `diff` of the finding sets is identical, so nothing new was introduced
- `just test` — 51 passed, 21 failed; the same 21 MCP probe/quarantine failures
  present on a clean tree
- Installers exercised in isolation rather than by running the interactive
  `setup.sh`: fresh install, re-run idempotency, and the node `>= 20.19` guard
  at v18.20.4 (skip), v20.18.9 (skip) and v20.19.0 (proceed)
- update.sh section 3d driven against a stubbed `npm` so the real, unmodified
  code ran on controlled versions — dry-run, no-op, and the `1.0.0 → 2.0.0`
  bump that fires the Beads schema-migration warning
- Section 3e driven against a stubbed no-op `brew` on a restricted PATH, to
  confirm it reports failure rather than false success

Both CLIs verified live afterwards: `openspec 1.8.0`, `bd version 1.1.2`.
