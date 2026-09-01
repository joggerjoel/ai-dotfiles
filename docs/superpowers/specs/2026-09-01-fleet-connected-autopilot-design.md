# Fleet-Connected Autopilot — Running pstack Work on the aorus Fleet

**Status:** Designed, not built.
**Date:** 2026-09-01
**Context:** pstack is installed as the `pstack@open-pstack` plugin (v1.2.0),
replacing a manual copy of upstream Cursor pstack that was retired to
`~/.claude/.backups/skills/retired-manual-pstack.20260901_153046`.

## Goal

pstack's autopilot playbooks assume Cursor cloud agents: `autopilot-full` step 2
gives each pull request "one Cursor cloud agent per PR" that carries build
through merge. Cursor cloud is not in use here. This design replaces that
execution tier with the seven-host aorus fleet, so autopilot keeps its
one-owner-per-PR shape while running on hardware we control.

Two units of work move to the fleet. A **lane** is one short, usually read-only
model call — a swarm worker or a panel reviewer. An **owner** is a whole PR
lifecycle: build, self-proof, triage, restack, babysit to green, merge. They
have different lifetimes and different needs, and the design serves both.

## What this design excludes

Routing fleet work through the 9Router gateway is explicitly out of scope. The
fleet hosts already hold their own authenticated `claude` and `codex` logins,
and `ANTHROPIC_BASE_URL` is unset on them, so lanes reach Anthropic and OpenAI
directly. That is also the policy-correct path: `skills/9router/SKILL.md` states
that frontier credentials stay out of the gateway and that frontier reasoning
runs in the orchestrating agent with its own governed credentials. A fleet
host's authenticated CLI is exactly that.

The gateway would only earn a place here if we wanted non-Anthropic model
families — qwen, glm, kimi, MiniMax, or macstudio's ollama models — reachable
through the same CLI dispatch path, since the `claude` CLI speaks only the
Anthropic protocol and something must translate. That is a separate project,
and it is currently blocked: every provider family on the gateway returns
`No active credentials`.

## Verified starting conditions

These were probed on 2026-09-01 and are load-bearing for the design.

Coverage differs by claim, and the difference matters — an implementation that
assumes fleet-wide uniformity from a two-host sample will be wrong.

Checked on all seven hosts (`aorus`, `aorus2`, `aorus4` through `aorus8`):
`codex-cli` 0.151.0–0.152.0 is present at `~/.local/bin/codex`.

Checked on aorus4 and aorus7 only: `codex` is authenticated through ChatGPT,
`grok` is present but reports "You are not authenticated," and both hosts carry
`git`, `gh`, and `tmux` with 32 CPUs and 125–187 GB of RAM. Claude Code
2.1.252–2.1.257 at `~/.local/bin/claude` reporting `"loggedIn": true` was
confirmed on aorus4, aorus7, and aorus8.

Everything else is unverified and must be probed by the host registry rather
than assumed. Two known gaps sit inside the sampled set: `gh` is authenticated
on aorus7 but not on aorus4, and git identity is inconsistent — aorus4 commits
as `Joel LaBelle`, aorus7 as `joggerjoel`. Both are likely to vary across the
five unaudited hosts too.

One environmental fact drives a requirement: `~/.local/bin` is **not** on the
non-interactive SSH `PATH`, and `PATH` contents differ between hosts. A bare
`ssh aorus4 codex …` fails while `ssh aorus4 /home/joggerjoel/.local/bin/codex
…` succeeds. Capability probes must therefore run the way dispatch will run, or
they report absence where there is only a path problem.

## Architecture

The local orchestrator owns every routing decision. The fleet only executes.

A lane keeps `pstack-runner` local. The runner composes its `CommandSpec` as it
does today, and a transport layer rewrites that spec into an `ssh` invocation
against an assigned host. The prompt travels on stdin and the response returns
on stdout, so no files are created on the remote host and nothing needs to be
collected afterward.

An owner is provisioned rather than piped. The orchestrator ensures a clone
exists under the host's `~/Documents/Projects/<repo>`, creates a git worktree
for the PR's branch, and launches `claude -p` inside a detached `tmux` session.
The orchestrator then disconnects. The owner works, commits, and pushes to
GitHub on its own; its real output is the side effects in git, not a returned
string.

### Staying update-safe

`open-pstack` is an installed plugin, so editing `commands.ts` in place would be
erased by the next plugin update. The dispatch contract avoids this for us: it
specifies that the parent "invokes the launcher directly," which means the
parent can invoke a fleet-aware wrapper that either shells to the local
`pstack-runner` or dispatches over SSH. The plugin is never modified.

Host placement must not be encoded in the model descriptor. `setup-pstack`
validates descriptors against its four-family matrix and refuses anything
unqualified or outside it, so a value like `fleet/aorus7:claude:claude-opus-5@xhigh`
would be rejected. Placement lives in a separate fleet-policy file instead,
which keeps model selection and host selection orthogonal — a role can change
provider without changing where it runs, and the reverse.

## Components

**Host registry.** The set of eligible hosts and, for each, the _resolved
absolute path_ of every provider CLI, whether that CLI is authenticated, whether
`gh` is authenticated, and current load. Absolute paths are the point: the
registry exists because bare command names do not survive SSH.

**Fleet policy.** Rules mapping lanes and owners to hosts. Read by the wrapper,
kept separate from `~/.claude/pstack-models.md`.

**Lane transport.** Rewrites a `CommandSpec` into an SSH invocation, replacing
`command` with the host-resolved absolute path and passing stdin, stdout, and
the exit code through unchanged. `preflightCommand()` needs the same rewrite; it
emits bare `claude`, `codex`, and `grok` names and would otherwise fail over SSH
in a way that looks like an authentication error rather than a missing binary.

**Owner provisioner.** Ensures the clone and worktree exist, normalizes git
identity, and launches the detached `tmux` session.

**Supervisor.** Serves `autopilot-full` step 6's thirty-minute audit tick by
collecting heartbeats and git side effects over SSH and identifying stuck
owners.

## Error handling

A host is eligible per capability, not as a binary up-or-down. aorus4 lacks `gh`
authentication, so it cannot own a PR — it cannot push — but it remains a
perfectly good target for read-only lanes. The allocator reasons about what a
host can do, not whether it is reachable.

An unauthenticated provider removes only its own family from that host. Grok is
unauthenticated on both sampled hosts, so panels dispatched to those hosts run
three families until someone logs in. This is the condition open-pstack's
`setup-pstack` already detects through live one-turn probes rather than trusting
a login check, so the configuration surface will report it without our help.

A stuck owner falls under the rule `autopilot-full` step 6 already defines:
anything that passes its expected runtime without producing a side effect is
stood down and replaced rather than waited on. Note that step 6 uses "lane" for
that unit where this document uses "owner" — the rule governs both, and progress
is counted only as commits, pushes, PR or check deltas. SSH failure marks a host
unhealthy and the work reallocates.

## Testing

The runner ships `commands.test.ts`, `cli.test.ts`, and `run.test.ts`, so the
transport wrapper gets unit tests in that style, asserting that a composed
`CommandSpec` becomes the expected `ssh` argument vector with an absolute remote
path. A `--dry-run` mode prints the composed command without executing it, which
is the cheapest guard against the quoting mistakes this kind of wrapper invites.

Beyond unit tests: one read-only smoke lane against aorus7, and one throwaway
owner against a scratch repository, driven end to end through provisioning,
detachment, and collection.

## Prerequisites

Authenticate `gh` on aorus4 and audit the other five hosts. Normalize git
identity across the fleet so commit attribution is consistent. Optionally log in
to `grok` to restore the fourth family.

The empty `firstmate_worker_ai` group in `ansible-ai/inventory.local.yml` is the
natural home for whichever hosts become the owner pool, and the existing
`ansible-ai` playbooks are the right vehicle for the identity and `gh`
remediation above.

## What this design deliberately does not build

A thicker tier — installing `bun` and the pstack plugin on every host so each
one can run pstack skills independently — was considered and rejected. Owners do
not need it. An owner is `claude -p` in a worktree with `git`, `gh`, and `tmux`,
all of which the fleet already has. The thick tier buys recursive orchestration,
where a remote agent itself invokes `/swarm`, and nothing in the current goals
requires that. Populating `firstmate_worker_ai` remains available if it ever
does.
