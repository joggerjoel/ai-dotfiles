# herdr layout.json — declarative spaces, directories, and models

**Date:** 2026-08-10
**Status:** approved, not yet implemented

## Problem

After a Mac Studio reboot, every herdr pane came back as a plain local login
shell. The workspaces, tabs, and panes were all restored — seven spaces, 44
panes — but nothing was connected to anything. Even panes in the `aorus8` space
showed `joggerjoel@JoggerJoels-Mac-Studio`, and the one pane herdr reported as
having a live agent was running that agent locally.

herdr persists *structure*, not *execution*. `session.json` records workspaces,
tabs, panes, and each pane's `cwd`; it does not record what was running. The API
makes this unavoidable: `tab.create` and `workspace.create` accept only
`cwd`/`env`/`label`/`focus`, with no command field, so a restored pane always
respawns a login shell. Wiring is necessarily a second step, and a reboot
performs only the first.

Re-running `herdr-wire-space.sh` restores the ssh connections, but three gaps
remain:

1. **A tab's label is its command.** `herdr-wire-space.sh` derives the program
   from the tab label, so a tab named after a project (`dice`, `crowdvolt`,
   `liveproxies`) tries to run that name as a binary.
2. **No directory survives.** `session.json` stores each pane's `cwd`, but a
   reboot resets every one to the local home. The remote working directory is
   lost and must be re-entered by hand.
3. **Nothing triggers the wiring.** It is a manual command after every reboot.

A fourth problem surfaced during design: a `tmux` tab wired with a bare `tmux`
creates a *new* session instead of reattaching to the one that survived. Two
wiring runs left 11 single-pane idle sessions across the fleet, and `aorus7` and
`aorus8` already carry two dozen more going back to July.

## Root cause

Three concerns are conflated into one field. A tab's label is simultaneously its
display name, its command, and — implicitly — the only hint about where it
should run. Any tab that is not literally named after a binary breaks, and no
tab can carry a directory at all.

## Design

`~/.config/herdr/layout.json` replaces `~/.config/herdr/layout.conf` as the
single declaration of the fleet's spaces. It stays outside this repo because
host names are private; the repo ships `examples/herdr-layout.example.json`.

### Schema

```json
{
  "defaults": {
    "cmd": "claude",
    "tabs": ["claude", "codex", "cursor", "pi", "tmux"],
    "model": {
      "claude": "opus",
      "codex":  "gpt-5-codex",
      "pi":     "openai/gpt-4o",
      "agent":  "sonnet-4-thinking"
    }
  },
  "spaces": [
    { "label": "macstudio", "host": "macstudio" },
    { "label": "aorus",  "host": "aorus"  },
    { "label": "aorus4", "host": "aorus4" },
    { "label": "aorus5", "host": "aorus5" },
    { "label": "aorus6", "host": "aorus6" },
    { "label": "aorus7", "host": "aorus7" },
    {
      "label": "aorus8",
      "host": "aorus8",
      "tabs": [
        { "label": "dice",        "dir": "~/Documents/Projects/go-events-dice" },
        "codex", "cursor", "pi", "tmux",
        { "label": "crowdvolt",   "dir": "~/Documents/Projects/go-events-crowdvolt" },
        { "label": "liveproxies", "dir": "~/Documents/Projects/go-events-lib/config",
                                  "model": "sonnet" }
      ]
    }
  ]
}
```

Array order is creation order, matching current behaviour. `aorus8`'s
agent tabs sit mid-array to preserve its on-screen order.

### Resolution rules

All owned by `scripts/lib/layout.py`.

| Input | Resolves to |
| --- | --- |
| Tab as string | `label` = `cmd` = the string; no `dir`, no `model` |
| Tab as object | `cmd` ← `defaults.cmd`; `dir` optional; `model` ← `defaults.model[cmd]` |
| `model` value | Appended as `--model <value>`; absent from both map and tab means no flag |
| `defaults.model` keys | Keyed by the **resolved command**, not the tab label. The `cursor` tab resolves to `agent`, so its entry is `"agent"`. Recipes are applied before the model lookup. |
| `host` | Local when `host == $FLEET_NODE` **and** `$FLEET_ROLE == node`; otherwise ssh |
| `tabs` omitted | Space uses `defaults.tabs` |

Two label-specific recipes live in one table rather than scattered conditionals:

| Label | Command | Notes |
| --- | --- | --- |
| `cursor` | `agent` | Existing alias; `agent` and `cursor-agent` are the same binary |
| `tmux` | `tmux new-session -A -s <space-label>` | Attach-or-create; ignores `dir` and `model` |

**Why `model` is a map, not a string.** Each CLI takes a different value shape:
`claude` wants `opus`, `pi` wants `openai/gpt-4o`, and `tmux` has no model at
all. A single global string would need overriding on nearly every tab. Because
`claude`, `codex`, and `pi` all accept `--model`, presence in the map is itself
the opt-in and no separate command→flag table is needed. `cursor-agent`'s
support was not verifiable during design (the local login keychain was locked);
it gains a map entry once confirmed.

**Why local detection uses `FLEET_ROLE`.** `hostname -s` returns
`JoggerJoels-Mac-Studio` while the ssh alias is `macstudio`, so a string compare
never matches and the space would silently ssh to itself. `.env` already
declares `FLEET_ROLE=node` and `FLEET_NODE=macstudio`, and every role-aware
`just` recipe keys off exactly that. Reusing it avoids IP probing and keeps one
canonical definition of "am I the node?".

**Why directories are explicit paths.** A label cannot be derived into a
directory. On `aorus8`, `liveproxies` resolves to `go-events-lib/config`, `dice`
matches more than eight directories across three roots, and
`dice-summary-nosync` matches nothing anywhere on the fleet. Projects span
`~/Documents`, `~/Developer`, and `~/Documents/Projects`, so no single root
prefix applies either. Each tab states its own `~`-relative path.

### Command construction

Four parts compose in order: **cd → guard → command → policy tail.**

Remote tab with a directory (`aorus8` / `dice`):

```bash
ssh -t aorus8 'bash -lc '\''
  cd ~/Documents/Projects/go-events-dice 2>/dev/null || {
    echo "herdr: dir missing: ~/Documents/Projects/go-events-dice" >&2
    exec $SHELL -l
  }
  claude --model opus
  exec $SHELL -l
'\'''
```

Local tab under `FLEET_ROLE=node` — identical without the ssh wrapper:

```bash
cd ~/Developer/ai-dotfiles 2>/dev/null || {
  echo "herdr: dir missing: ~/Developer/ai-dotfiles" >&2
  exec $SHELL -l
}
claude --model opus
exec $SHELL -l
```

Recipe tab:

```bash
ssh -t aorus8 'bash -lc '\''tmux new-session -A -s aorus8; exec $SHELL -l'\'''
```

Properties:

- **`~` expands on the target.** It sits inside the single-quoted payload that
  `bash -lc` evaluates remotely, so one string works whether home is
  `/Users/joggerjoel` or `/home/joggerjoel`.
- **`bash -lc` stays.** A non-interactive `ssh host cmd` gets a truncated PATH
  and `codex` is not found; the login shell is load-bearing.
- **A missing directory fails loudly in the pane** and drops to a shell rather
  than launching an agent in the wrong place. Chosen over a preflight check to
  avoid an extra ssh round-trip per space.
- **Existing guards are untouched:** skip the pane running the script, skip
  panes with a live agent (`FORCE=1` overrides), refuse an unreachable host.
- **`--policy` is unchanged.** `bare` drops the `exec $SHELL -l` tail;
  `reconnect` wraps the whole payload in `until … done`.

### Code structure

| Path | Role |
| --- | --- |
| `scripts/lib/layout.py` | **New.** Parses `layout.json`, applies defaults and recipes, resolves local-vs-ssh, emits a flat `space\|host\|local\|tab\|dir\|cmd\|model` table |
| `scripts/herdr-layout.sh` | Structure: `status`, `apply`, plus new `migrate` and `autowire` |
| `scripts/herdr-wire-space.sh` | Execution: gains `dir`, `model`, and recipe support; still runnable standalone |

The parser is the only place resolution decisions are made, and it is a pure
function — JSON in, table out, no ssh and no herdr — which is what makes those
decisions testable in isolation.

### Restart automation

The launchd agent runs `herdr server --session <s>` directly, not
`herdr-node.sh up`, so hooking `cmd_up` alone would never fire at boot. The
server plist also sets `KeepAlive` to `SuccessfulExit=false` specifically so
launchd does not respawn the server during herdr's own restart/update handoff;
wrapping its `ProgramArguments` would make launchd monitor the wrapper instead
and break that. The wiring therefore gets its own agent.

A second one-shot agent, `com.joggerjoel.herdr-wire`, with `RunAtLoad=true` and
no `KeepAlive`, runs `herdr-layout.sh autowire`, which:

1. Polls for the herdr socket, bounded by `START_TIMEOUT`.
2. Applies structure, then wires each space.
3. Retries hosts that are unreachable — 5 attempts, 30s apart — because the LAN
   is often not up when launchd fires at login. Spaces that are ready are wired
   immediately rather than waiting on the slowest host.
4. Logs a final `n/m spaces wired` summary.

`cmd_up` also calls the wiring after its wait loop, so `just node-up` and
`just node-restart` wire too. The cold-start guard is free: `cmd_up` already
early-returns when the server is running, so code after the loop runs only on a
genuine start.

### Migration

`herdr-layout.sh migrate` reads `layout.conf` and emits a `layout.json`
skeleton: each space gets its `host` (the alias column, with `local` rewritten
to `macstudio`), and each tab lands as a bare string. Project tabs need their
`dir` filled in by hand, since a label cannot be derived into a path.

`layout.conf` is backed up to `~/.claude/.backups/` first, per the
config-backup policy. `examples/herdr-layout.example.conf` is replaced by a
`.json` twin.

No dual-format support. If `layout.json` is absent and `layout.conf` present,
the script errors and names the migrate command — failing fast beats two
silently diverging sources of truth.

### Testing

`scripts/lib/layout.test.py`, wired to a `just layout-test` recipe, matching the
colocated-test convention of `hooks/injection-guard.test.sh`.

| Case | Asserts |
| --- | --- |
| Bare string vs object tab | label/cmd/dir resolution |
| `cmd` omitted | falls back to `defaults.cmd` |
| Model in map / per-tab override / absent | flag present, overridden, omitted |
| `cursor`, `tmux` recipes | correct command; tmux ignores `dir` and `model` |
| `host == FLEET_NODE`, `FLEET_ROLE=node` | no ssh wrapper |
| Same host, `FLEET_ROLE=worker` | ssh wrapper present |
| Directory containing a space or a quote | payload stays correctly escaped |
| `--policy bare\|fallback\|reconnect` | tail differs as specified |
| Missing-dir guard | `cd … \|\| { echo …; exec $SHELL -l; }` present |

`herdr-layout.sh apply --wire --dry-run` remains the end-to-end check, printing
every command without executing it.

## Open data items

Needed before implementation, not before this spec:

- **`dice-summary-nosync`** — no matching directory exists anywhere on the
  fleet under `~/Documents`, `~/Developer`, or `~/Documents/Projects`. Needs a
  path, or the tab is dropped.
- **`liveproxies`** — currently specified as `go-events-lib/config`, where its
  files actually live. Confirm this rather than the repo root.
- ~~**`cursor-agent --model`**~~ — **confirmed** on `aorus8`:
  `--model <model>` exists, taking values like `gpt-5` or `sonnet-4-thinking`,
  and also reads `CURSOR_API_KEY`. Add a `defaults.model` entry for `cursor`;
  note the key is the tab label `cursor`, while the command is `agent`, so the
  model map must be keyed by the **resolved command**, not the label.

## Follow-up

**Done.** The eleven idle tmux sessions left by the two wiring runs (Aug 9 11:58
and Aug 10 09:26) were killed on 2026-08-10: `aorus` 5 and 6, `aorus4` 0 and 1,
`aorus5` 0 and 1, `aorus6` 36 and 37, `aorus7` 19 and 20, `aorus8` 89. Each was
re-verified immediately before deletion — one pane, `bash`, zero children — and
every session holding work survived. The `tmux` recipe is what stops the count
from growing again.

Older numeric sessions predating the wiring leak remain untouched: 14 on
`aorus7` and 21 on `aorus8`, going back to July. They were not attributable to a
wiring run and are likelier to hold something wanted.

### Findings for the implementer

- **`tab.move` exists in the socket API**, though not in the CLI (`herdr tab`
  offers only list/create/get/focus/rename/close). The comment in
  `herdr-layout.sh` — "herdr's CLI exposes no tab.move, so this reports rather
  than pretends to fix" — is true of the CLI but not the API. Tab-order drift is
  fixable via a direct socket call, not merely reportable. Correct that comment
  when touching the file.
- **`layout.export` and `layout.apply` exist** in the API (103 methods total).
  Worth investigating before assuming `session.json` is the only route to
  structure.
- **herdr has no tmux awareness.** Neither `tmux` nor `multiplexer` appears
  anywhere in the API schema. tmux is opaque to herdr — just a program in a
  pane. Any tmux integration must go through `ssh <host> tmux …`.

## Phase 2 — tmux session discovery (separate spec)

Agreed in principle, deferred to its own spec so this one stays a single
implementation plan. On reload, discover live tmux sessions per host and add a
tab for each, wired with `tmux attach -t '=<name>'`.

**Filter: named sessions only** — skip purely-numeric names. Across the fleet
that is 13 tabs rather than 45, and it matches actual habit: a session gets a
name when it means something. Current named sessions are `06-go-events-dice`,
`07-dice-broadcast`, `07-reachpro-prevent-cancel-rebroadcast`,
`07-sell-eventid-stubhub-scrape`, `07-stubhub-cancelled-orders-watch`, `dice`,
`dice-price-sync`, `mem`, `stubhub-pipeline`, `venue-match` on `aorus8`, and
`stubhub-01/02/03` on `aorus6`. `aorus7`'s 14 sessions are all numeric and would
yield nothing.

Open questions for that spec: how discovered tabs reconcile with declared ones,
what happens to a tab whose session later dies (the "only ever adds" rule
suggests it stays), and whether discovery runs on every reload or only at boot.

## Out of scope

- Reviving the pre-reboot `cwd` of existing panes. It is unrecoverable —
  `session.json` reset every pane to the local home.
- Changing how herdr itself persists state.
- Resolving a tab label to a directory by scanning roots. Established as
  unreliable: ambiguous for `dice`, wrong for `liveproxies`, empty for
  `dice-summary-nosync`.
