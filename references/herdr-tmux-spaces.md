# herdr tmux Spaces — Attaching to Live Fleet Sessions

Extends `herdr-spaces.md` to the sessions that already exist on the fleet.
Records why these spaces are discovered rather than declared, so the next change
does not relitigate settled ground.

Designed 2026-08-10.

## Goal

Reach a long-running tmux session on a fleet host — `07-dice-broadcast`,
`stubhub-01` — from a herdr tab, without hunting for it by hand.

## The bug that prompted this

The `tmux` tab in every main space was wired to bare `tmux`, which **creates a
new session on every run**. Two wiring passes on 2026-08-10 left two fresh
numeric sessions on each of six hosts. Repeated over weeks this produced 16
sessions on aorus7 and 20+ on aorus8, nearly all unattached debris, burying the
handful that matter.

The decided fix — not yet implemented as of this writing — is to wire the tab to
`tmux new-session -A -s herdr` instead: attach if `herdr` exists, create it
otherwise. One stable scratch session per host, no accumulation.

## Why these spaces are discovered, not declared

`layout.conf` is static — a fixed list of spaces and tabs, rebuildable from
version control. Live tmux sessions are not: `07-dice-broadcast` exists today,
and next week there are three more. A static list would drift from the fleet
silently, and the drift would be invisible precisely when it mattered.

So `herdr-tmux.sh` queries `tmux ls` on each host at apply time and builds tabs
from what is actually running.

**The cost, stated plainly:** these spaces are not rebuildable from version
control. `layout.conf` does not mention them. After a restart, re-run
`herdr-tmux.sh apply`. Because `herdr-layout.sh` is add-only and never closes a
space, a stale `aorus8-tmux` from an earlier run survives with tabs pointing at
dead sessions until re-applied.

## What earns a tab

```
qualifying = name does not match ^[0-9]+$
           AND name != "herdr"
```

The numeric rule is what separates real work from the debris the old wiring
manufactured. Excluding `herdr` keeps the scratch session from appearing twice —
it is already the main space's `tmux` tab.

A host with no qualifying session gets **no space at all**, and is reported as
skipped. On 2026-08-10 that means aorus4 and aorus5 are skipped; aorus, aorus6,
aorus7 and aorus8 get spaces.

## The label convention still holds

`herdr-spaces.md` establishes that a tab's label is the command run in it. That
survives here with one substitution: in a tmux space the label is the _session
name_, and the program is `tmux attach -t <label>`. One rule, one lookup, no
second column in any config.

## Structure and behavior stay separate

The split from `herdr-spaces.md` is preserved rather than forked:

- `herdr-tmux.sh` — discovery and structure (query hosts, create spaces/tabs)
- `herdr-wire-space.sh` — behavior, gaining an `--attach-tmux` flag that swaps
  the label→program mapping to `tmux attach -t <label>`

Delegating the wiring keeps the ssh login-shell quoting, the reachability gate,
the busy-pane skip and the own-pane guard in exactly one place. Duplicating
those into a second script is how one of them quietly stops matching the other.

## Attach only, never create

`tmux attach -t NAME` fails if the session vanished between discovery and
attach. That is correct: the `fallback` policy's `exec $SHELL -l` then leaves a
usable login shell rather than silently creating an empty session that looks
like the real one.

## The existing backlog is reported, not pruned

`status` counts named and numeric sessions per host and flags unattached ones.
Nothing is killed. Numeric sessions are debris _by default_, not _by proof_ —
several show as attached, and a kill rule keyed on a name pattern would
eventually take real work with it. Pruning stays a human decision.

## Known gaps

- **Not rebuildable from version control.** See above; inherent to discovery.
- **Stale spaces persist.** `herdr-layout.sh` never closes a space, so tabs for
  ended sessions linger until re-apply.
- **Agent detection still blind through ssh.** As with every remote space, the
  local foreground process is `ssh`, so the agent panel reports `unknown`.
  Verify with `tmux ls` on the host.
- **Structure is idempotent; wiring is not.** Re-running `apply` is safe for
  the spaces/tabs it builds — a tab that already exists is left alone. But
  the busy-pane guard in `herdr-wire-space.sh` depends on herdr's agent
  detection, and that detection cannot see through ssh: the pane's local
  foreground process is always `ssh`, never whatever the remote session is
  actually running. Every remote pane in a tmux space therefore classifies
  as `free`, and the guard is structurally inert here. Re-applying an
  already-wired space re-sends `ssh -t … tmux attach -t X` as **keystrokes**
  into a pane that is already attached — the text lands in whatever is
  foregrounded inside that live session, possibly a running agent's prompt.
  Detach the session first, or run `apply --dry-run` to see what would be
  sent, before re-applying a space you already wired.
