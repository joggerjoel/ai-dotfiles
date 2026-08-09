# Remote Control (`/rc`)

Remote Control registers a Claude Code session with your account so it can be reached from
your other Claude surfaces — the web app, another machine, a phone. Once connected, sessions
running elsewhere show up in `ListAgents` alongside local subagents and can be addressed with
`SendMessage`, which is what makes a multi-machine fleet feel like one workspace instead of
several disconnected terminals.

This repo has an opinion about it because **Remote Control and the telemetry opt-out are
mutually exclusive**, and the failure mode is silent. That trade-off, and the `/rc` badge you
see in the terminal, are what this page explains.

## The `/rc` badge

Claude Code paints a right-aligned badge next to the status line. It has four states:

| Badge              | Colour  | Meaning                                           |
| ------------------ | ------- | ------------------------------------------------- |
| `/rc connecting…`  | warning | Handshake in flight                               |
| `/rc active`       | success | Connected and healthy                             |
| `/rc reconnecting` | warning | Lost the link, retrying                           |
| `/rc failed`       | error   | Gave up — check auth and the telemetry vars below |

**A bare `/rc` is not a truncation.** Claude Code shows the full `/rc active` for your first
five sightings, then permanently collapses it to two characters. The counter lives in
`~/.claude.json`:

```jsonc
"seenNotifications": { "rc-active-badge": 5 }   // >= 5 → abbreviated forever
```

Set it back to `0` if you want the full label again. Only the healthy state abbreviates — the
other three always render in full, so **anything longer than `/rc` in that corner is the thing
worth reading.**

The badge is drawn by the TUI, not by `statusline.sh`. It cannot be moved, restyled, or
relocated to another line from this repo; the only way to remove it is to turn Remote Control
off.

## The telemetry trade-off

The desktop profile ships three privacy vars in `profiles/desktop/settings.json`:

```
DISABLE_TELEMETRY
DO_NOT_TRACK
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC
```

Claude Code gates **feature-flag reads** behind all three. Any one of them set means flags never
resolve, and Remote Control is flag-gated — so it silently stays unavailable even on an account
that's entitled to it. No error, no badge, no explanation. See
[#4](https://github.com/iamnolanhu/ai-dotfiles/issues/4) and
[anthropics/claude-code#76748](https://github.com/anthropics/claude-code/issues/76748).

You therefore pick one:

| Choice                         | What you get                           | What you give up                                  |
| ------------------------------ | -------------------------------------- | ------------------------------------------------- |
| Keep the opt-out (**default**) | No telemetry, no non-essential traffic | Remote Control, plus any other flag-gated feature |
| Strip the opt-out              | Remote Control works                   | The three vars above stop being set               |

Stripping affects only those three keys. `DISABLE_ERROR_REPORTING` and the non-Anthropic
telemetry vars (`CLAUDE_MEM_TELEMETRY`, `NEXT_TELEMETRY_DISABLED`, `TURBO_TELEMETRY_DISABLED`,
`VERCEL_TELEMETRY_DISABLED`) are left alone.

## Turning it on or off

`./setup.sh` asks during desktop-profile setup ("Do you use Remote Control?", default **n**).
The answer persists to `.local/.remote-control` and every `./setup.sh update` re-applies it.

```bash
echo yes > .local/.remote-control && ./setup.sh update   # enable
echo no  > .local/.remote-control && ./setup.sh update   # disable
```

The VPS profile doesn't prompt — it sets `remoteControlAtStartup: true` in its own
`settings.json` and isn't shipped with the telemetry gate vars.

## The symlink gotcha

This is the part that bites people editing the repo.

Normally `~/.claude/settings.json` is a **symlink** to `profiles/<profile>/settings.json`, so
profile edits apply immediately. With Remote Control enabled it's installed as a **stripped
copy** instead — `setup.sh` runs the source through `jq 'del(.env.DISABLE_TELEMETRY, …)'`, because
stripping through a symlink would dirty the repo.

**Consequence:** with Remote Control on, editing `profiles/<profile>/settings.json` changes
nothing until you run `./setup.sh update`. Check which mode you're in:

```bash
[ -L ~/.claude/settings.json ] && echo "symlink (RC off)" || echo "copy (RC on) — run ./setup.sh update after profile edits"
```

## Settings keys

| Key                      | Notes                                            |
| ------------------------ | ------------------------------------------------ |
| `remoteControlAtStartup` | Connect on launch. Set in both shipped profiles. |
| `remoteControlMachineId` | Per-machine identity; assigned, don't hand-edit. |
| `remoteControlSpawnMode` | How remotely-triggered sessions are spawned.     |
| `isolatePeerMachines`    | Keeps peer machines from addressing each other.  |
| `teammateMode`           | Governs cross-session/teammate addressing.       |

## Verifying

`ansible-ai/verify-config.yml` asserts the intended end state across the fleet: the live
`settings.json` is a stripped copy with **0** of the three gate vars present and
`remoteControlAtStartup` enabled.

```bash
cd ansible-ai && ansible-playbook verify-config.yml
```

Locally, the badge itself is the check — `/rc` or `/rc active` means connected. If it reads
`/rc failed`, confirm the gate vars are actually absent from the _live_ file, not just the
profile source:

```bash
jq '.env | with_entries(select(.key | test("DISABLE_TELEMETRY|DO_NOT_TRACK|NONESSENTIAL")))' ~/.claude/settings.json
# {} means the strip worked
```
