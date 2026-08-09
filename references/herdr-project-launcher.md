# herdr Project Launcher

Press one key, pick a repo, pick a CLI, get a new herdr tab already `cd`'d into
the project and running that agent.

```
Ctrl-b  Shift+C
   ↓
┌─ project> ───────────────┐     ┌─ cli for ai-dotfiles> ───┐
│ > dotf                   │     │ ▶ claude                 │
│ ▶ ~/Developer/ai-dotfiles│  →  │   codex                  │  →  new tab
└──────────────────────────┘     │   cursor-agent           │
                                 │   shell                  │
                                 └──────────────────────────┘
```

herdr's built-in `new_tab` (`Ctrl-b c`) is deliberately left alone, so there is
always a dependency-free way to get a plain shell.

## Components

| Piece      | Path                             | Role                                       |
| ---------- | -------------------------------- | ------------------------------------------ |
| Keybinding | `~/.config/herdr/config.toml`    | `[[keys.command]]` block, `prefix+shift+c` |
| Picker     | `bin/herdr-new-project`          | fzf twice, then two herdr API calls        |
| PATH entry | `~/.local/bin/herdr-new-project` | symlink to the above                       |
| Dependency | `fzf`                            | `brew install fzf`                         |

```toml
[[keys.command]]
key = "prefix+shift+c"
type = "pane"
command = "/Users/joggerjoel/.local/bin/herdr-new-project"
```

`type` accepts `shell` (detached, no UI), `pane` (temporary pane, closes when the
command exits), or `popup` (session-modal terminal; also accepts `width` and
`height` as cells or percentages). `pane` is used here because it is non-modal,
so it cannot conflict with focusing the tab the picker creates.

Apply config changes without restarting: `herdr server reload-config`.

## The remote-attach gotcha

**This is the one that will waste your afternoon.** herdr resolves keybindings
**client-side**, and `--remote-keybindings` defaults to `local`. If you attach
from another machine the normal way:

```bash
herdr --remote macstudio            # keybindings come from THIS machine
```

your client reads the _laptop's_ `config.toml`, not the Node's. The binding
appears to do nothing — the prefix menu opens, then the key falls through to
whatever app owns the pane. Attach like this instead:

```bash
herdr --remote macstudio --remote-keybindings server
```

Now the Node supplies the keymap, the binding fires, and the picker runs on the
Node where the repos and CLIs actually live.

Do **not** fix this by copying the binding to the client machine. A
`[[keys.command]]` executes on whichever machine owns the keymap, so a local copy
would scan the _laptop's_ `~/Developer` and create tabs against the _laptop's_
herdr server — the wrong session entirely.

## Why the launch is two steps

herdr's `tab.create` API accepts only `cwd`, `env`, `label`, and `focus`. There
is no `command` field, so a new tab always spawns a plain login shell. Running
something in it is a separate call against the live pane:

```bash
created=$(herdr tab create --cwd "$dir" --label "$name" --focus)
pane=$(printf '%s' "$created" | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p')
herdr pane run "$pane" "claude; exec $SHELL -l"
```

`tab create` returns the new tab's `root_pane` inline, so no second lookup is
needed.

The trailing `exec $SHELL -l` matters: without it the pane sits at a dead prompt
once the CLI exits. Chaining a login shell leaves you in the project directory
instead. This mirrors the `fallback` policy in
[`bin/herdr-wire-space.sh`](../bin/herdr-wire-space.sh), which solves the same
constraint for whole workspaces.

## Customizing

**Which roots to scan** — colon-separated, defaults to `~/Developer`. Only
directories containing `.git` are listed. Set it in the binding itself:

```toml
command = "HERDR_PROJECT_ROOTS=$HOME/Developer:$HOME/Documents/Projects /Users/joggerjoel/.local/bin/herdr-new-project"
```

`HERDR_PROJECT_DEPTH` (default `3`) controls how deep the scan goes.

Discovery matches `-name .git` rather than `-type d`, so linked worktrees — where
`.git` is a file, not a directory — are found too.

**Which CLIs to offer** — edit `CLI_MENU` in `bin/herdr-new-project`. Format is
`"label|command"`, ordered by frequency since fzf pre-selects the top entry.
Entries whose command is not on `PATH` are dropped automatically, so listing
optimistically is safe. An empty command means "just a shell".

## Free keys

herdr's built-in v2 bindings, for picking a non-conflicting key:

```
prefix+?  prefix+1  prefix+alt+1  prefix+alt+g  prefix+b  prefix+c  prefix+e
prefix+g  prefix+h  prefix+j  prefix+k  prefix+l  prefix+minus  prefix+n
prefix+o  prefix+p  prefix+q  prefix+r  prefix+s  prefix+shift+1  prefix+shift+d
prefix+shift+g  prefix+shift+n  prefix+shift+p  prefix+shift+r  prefix+shift+t
prefix+shift+tab  prefix+shift+w  prefix+shift+x  prefix+tab  prefix+v
prefix+w  prefix+x  prefix+z
```

Note `prefix+alt+g` is taken despite being the example in herdr's own config
comments. `prefix+1` is `switch_tab` (`prefix+1..9`), so binding it breaks tab
switching.

## Troubleshooting

| Symptom                                    | Cause                                                                                              |
| ------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| Key does nothing, falls through to the app | Remote-attached without `--remote-keybindings server`                                              |
| Key does nothing, nothing in config        | `herdr config reset-keys` strips **all** `[keys]`, `[keys.indexed]`, and `[[keys.command]]` blocks |
| `fzf not found`                            | `brew install fzf`                                                                                 |
| Picker lists one project                   | `~/Developer` genuinely has one repo — add roots                                                   |
| Labels render as `claude\|`                | `--with-nth=1` includes the delimiter; the template form `--with-nth='{1}'` does not               |

## Rollback

Removes only this block, unlike `herdr config reset-keys` which strips every
keybinding you have:

```bash
sed -i '' '/^\[\[keys.command\]\]/,$d' ~/.config/herdr/config.toml
herdr server reload-config
```

## See also

- [herdr-project-launcher-plan.md](herdr-project-launcher-plan.md) — design
  record: constraints discovered, decisions and their rationale, what was
  deliberately not built, and what went wrong along the way
- [herdr-project-launcher-todo.md](herdr-project-launcher-todo.md) — open items,
  deferred ideas, and herdr bugs worth reporting upstream
