# cass (Coding Agent Session Search) — Install Record

Records _why_ the installer treats cass differently from every other skill in
this repo, so the next change does not reintroduce a licence problem.

Designed 2026-08-09.

## What it is

`cass` — a Rust CLI/TUI that indexes and searches this machine's local coding
agent history (Claude Code, Codex, Cursor, Aider, Gemini CLI and ~20 others)
as one timeline. Upstream:
<https://github.com/Dicklesworthstone/coding_agent_session_search>

## Two install paths, because the fleet has no Homebrew

| Host                | Path                                                        |
| ------------------- | ----------------------------------------------------------- |
| macOS control nodes | `brew tap dicklesworthstone/tap` + `brew install …/cass`    |
| Linux workers       | upstream `install.sh --easy-mode --verify` → `~/.local/bin` |

The Linux boxes are x86_64 with no brew, so the tap is unavailable there.
Upstream publishes a prebuilt `cass-linux-amd64` release asset with a sha256,
which `--verify` checks — so no source build and no Rust toolchain on the
fleet. `--from-source` would be the fallback, and it is worth avoiding across
six machines.

`update.sh` upgrades only where cass already **runs**. A host that never ran
`setup.sh` does not silently gain a tool mid-update.

## The prebuilt Linux binary needs glibc >= 2.39

The `cass-linux-amd64` asset is built against glibc 2.39, i.e. Ubuntu 24.04.
On 22.04 it downloads, verifies, extracts and installs without complaint, then
dies on every invocation:

```
cass: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found
```

This is the nastiest shape of failure available: the installer reports success,
`command -v cass` is true, and the tool is completely unusable. Both scripts
therefore gate on `cass --version` succeeding rather than on the binary
existing, and remove a present-but-dead binary instead of leaving it to be
"upgraded" on every future run.

Upstream publishes no musl build, and **every release back to v0.6.11 requires
2.39** — so there is no older version to fall back to. A 22.04 host needs
either a source build or an OS upgrade. Neither is worth doing implicitly, so
`ensure_cass` reports the host as unsupported and moves on.

Do not try to upgrade glibc on its own. It is the floor the whole userland is
compiled against; forcing 2.39 onto a 22.04 system is a good way to lose sshd
on a headless box. The supported route is an OS upgrade to 24.04, where glibc
comes along as a consequence.

### Ubuntu 22.04: build once, copy to the rest

The cheap fix, used on this fleet's three 22.04 hosts. A binary compiled
natively on 22.04 links against glibc 2.35 and runs on every host of that
release, so **one** toolchain covers all of them:

```bash
# on one 22.04 host
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal --default-toolchain nightly
git clone --depth 1 --branch <tag> \
  https://github.com/Dicklesworthstone/coding_agent_session_search.git
cd coding_agent_session_search && cargo build --release
install -m 755 target/release/cass ~/.local/bin/cass

# then, from a machine that can reach both
ssh builder 'cat ~/.local/bin/cass' > /tmp/cass
scp /tmp/cass other-host:/tmp/cass.new
ssh other-host 'install -m 755 /tmp/cass.new ~/.local/bin/cass'
```

`rust-toolchain.toml` pins **nightly**, so this is not a stable-Rust build to
reproduce casually. Measured once: ~11 minutes on 32 cores, 54 MB binary,
`ldd` clean on every 22.04 host.

**These binaries are unmanaged.** `update.sh` upgrades through brew or the
upstream installer, and neither touches a hand-built binary — so those hosts
stay pinned at whatever tag was built until someone repeats the procedure.
That is the standing cost of keeping 22.04.

## The archive is per-machine

There is no shared index. Each host indexes the sessions on its own disk, so a
worker's agent history is searchable only on that worker. This is why cass is
installed fleet-wide rather than on the control nodes alone — searching a
worker's history means running cass there, typically in that host's herdr
space.

First run on a new host needs `cass index --full` once; `cass triage --json`
reports `not_initialized` until then and names the exact command.

**Then run plain `cass index` once more.** `--full` defers the lexical index
into an authoritative DB rebuild (`lexical_strategy:
deferred_authoritative_db_rebuild`), and until a follow-up incremental pass
lands it, triage reports `status: unhealthy` on a freshly indexed host — with
`recommended_action: Run 'cass index' to refresh the index`. Nothing is wrong;
the first pass simply is not the whole job. Reading the `--full` completion as
"done" makes a healthy install look broken.

## The skill is fetched, never vendored

**This is the load-bearing decision.** Every other skill here is committed to
`skills/` and copied to `~/.claude/skills/` by `setup.sh`. cass is not.

cass is MIT **with an OpenAI/Anthropic rider**. The rider forbids providing,
hosting, or "making available" the software or any derivative work to
Restricted Parties — OpenAI, Anthropic, their affiliates, and anyone acting on
their behalf — and states that any breach _automatically terminates_ the
licence. This repo is public. Committing upstream's `SKILL.md` here would
publish their file to everyone, Restricted Parties included.

So `ensure_cass` fetches `SKILL.md` from upstream directly into
`~/.claude/skills/cass/` at install time, and `update.sh` re-fetches it each
run. The file lands on the host and never enters git. A failed fetch keeps the
existing copy rather than deleting it.

The 9router skills are vendored the usual way because they are plain MIT. The
distinction is the rider, not the fact of vendoring.

**Do not "fix the inconsistency" by moving cass into `skills/`.**

`setup.sh`'s skill loop removes only the skills it is about to copy
(`rm -rf ~/.claude/skills/<name>` per repo skill), so a fetched `cass` skill
survives setup runs untouched. That property is what makes fetch-at-install
viable; a loop that pruned unmanaged skills would break it.

## `unhealthy` is the steady state, not a fault

Once agent sessions land after the last index, triage reports `status:
unhealthy` with `recommended_action: Run 'cass index' to refresh the index`.
On any host where agents actually run — all of them — this happens
continuously. **Search keeps working while stale**; the results are simply
missing the newest sessions. Do not read it as a broken install.

`scripts/cass-cron-setup.sh` schedules the refresh, per-host and idempotent
(there is no shared index to fan out from a control node). Default every 2
hours at :25, which measured out as roughly a 2% duty cycle: an incremental
pass takes ~90s on a node holding ~93k conversations and is instant on a
worker holding a handful. It bakes the absolute path to cass into the entry,
since cron's PATH has neither `~/.local/bin` nor Homebrew, and refuses to
schedule a binary that will not run.

## Agent usage

Never run bare `cass` from an agent — it launches a blocking interactive TUI.
Use `--robot` or `--json`:

```bash
cass triage --json                          # one-shot orientation; follow next_command
cass search "auth error" --robot --limit 5  # hybrid search across all agents
cass sessions --current --json              # this workspace's session
cass capabilities --json                    # discover the machine API
```

The fetched skill carries the full command surface.
