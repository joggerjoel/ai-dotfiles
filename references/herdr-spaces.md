# herdr Spaces — Layout and Wiring

Records _why_ spaces are managed by two scripts and a config file rather than by
versioning herdr's own state, so the next change does not relitigate settled
ground.

Designed 2026-08-09.

## Goal

Rebuild a fleet's herdr spaces — and the programs running in them — from
version control, on a machine whose session has been wiped.

## The constraint that shapes everything

herdr's socket API cannot launch a program with a tab. `workspace.create` and
`tab.create` accept exactly four fields:

```
cwd · env · label · focus
```

There is no `command`. Every new tab spawns a bare login shell, always. So
"a space with claude running in it" is not one operation, it is two:

1. **Structure** — create the space and its tabs (`herdr-layout.sh`)
2. **Behavior** — drive each program into the live pane (`herdr-wire-space.sh`)

Keeping these separate is not tidiness. Structure survives a restart; behavior
does not. Conflating them would imply a restart restores a working session,
which it does not.

## Why session.json is not the source of truth

herdr persists structure in `~/.config/herdr/session.json`. That file is
tempting and wrong to version:

- It is **runtime state** — pane ids, terminal ids, scroll offsets, focus — and
  churns as the session runs.
- It records **no commands**, so restoring it gives you correctly-labelled empty
  shells.
- It is **machine-specific**.

The config records intent instead: which spaces exist, which tabs each holds.
It lives at `~/.config/herdr/layout.conf`, **outside this repo**, because host
names are private and this repo is public — the same reason
`ansible-ai/inventory.local.yml` is gitignored. Template in
`examples/herdr-layout.example.conf`.

## A tab's label is its program

The one convention that keeps the config from needing a second column: the tab
label is the command run in it. `claude`, `codex`, `pi`, `tmux` are literal.
`cursor` is aliased to `agent` (both are the same cursor-agent binary).

## Remote commands must go through a login shell

The single most expensive gotcha here. A non-interactive ssh gets a truncated
PATH:

```bash
ssh worker1 'command -v codex'              # fails on every fleet host
ssh worker1 'bash -lc "command -v codex"'   # succeeds
```

Every remote pane is therefore wired as
`ssh -t HOST 'bash -lc "<program>; exec $SHELL -l"'`. Skipping the login shell
produces "command not found" in panes that are configured perfectly, which
reads as a broken host rather than a broken command.

## herdr cannot see agents through ssh

Agent detection inspects the pane's **local** foreground process. For a remote
space that process is `ssh`, so the agent panel reports `agent_status: unknown`
even while the program runs fine. This is structural, not a bug to chase.

Verify remote panes with `ps` on the host, not the panel. Likewise `pane read`
returns empty for full-screen TUIs (codex, cursor, pi) because they draw on the
alternate screen buffer.

## Guards

Wiring sends text to live terminals, so `herdr-wire-space.sh` refuses in three
cases:

- **Unreachable host** — aborts the whole space. Firing ssh at a dead host
  leaves every pane on a timeout, indistinguishable from a misconfigured space.
- **Occupied pane** — a pane with a detected agent is skipped unless `FORCE=1`,
  so a re-run does not type into a working agent.
- **Own pane** — the pane the script runs from is never wired. Without this, an
  agent running the script types into its own stdin.

`herdr-layout.sh` only ever adds. It never closes a space or tab, so a scratch
space is never swept up, and extra tabs are reported as "left alone" rather
than as drift — otherwise every space anyone had tinkered with would read as
broken forever.

## Known gaps

- **Tab order cannot be fixed.** `tab.move` exists in the socket API but is not
  exposed by the CLI (`herdr tab` offers list/create/get/focus/rename/close).
  Order is reported, never corrected. New spaces come out right because tabs are
  created in declaration order.
- **Restart loses all wiring.** Structure returns from session.json; programs do
  not. Re-run `just spaces-apply --wire`.
- **`herdr server stop` is unreliable** — the launchd agent respawns it. Use
  `scripts/herdr-node.sh restart`. For config-only changes prefer
  `herdr server reload-config`, which costs no panes.
