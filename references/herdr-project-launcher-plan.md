# herdr Project Launcher — Design Record

Companion to [herdr-project-launcher.md](herdr-project-launcher.md) (usage) and
[herdr-project-launcher-todo.md](herdr-project-launcher-todo.md) (open items).
This file records _why_ the thing is shaped the way it is, so the next change
does not relitigate settled ground — or repeat a solved mistake.

Built 2026-08-09.

## Goal

One keystroke from "I want to work on X" to a tab already `cd`'d into X with the
right agent CLI running. Replace the manual sequence: new tab → `cd ~/Developer/…`
→ type the CLI name.

## Constraints discovered

These were found by probing the live system, not from documentation. They drove
every subsequent decision.

| Constraint                                                                                 | Consequence                                                                           |
| ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| `tab.create` accepts only `cwd`/`env`/`label`/`focus` — no `command`                       | Launch must be two steps: create tab, then `herdr pane run` against the returned pane |
| `tab.create` returns `root_pane` inline                                                    | No second lookup needed to find the pane id                                           |
| Keybindings resolve **client-side**; `--remote-keybindings` defaults to `local`            | A remote client reads its _own_ `config.toml`; the Node's binding never fires         |
| `herdr config reset-keys` strips **all** key blocks                                        | Never use it as a rollback; use a targeted `sed` on the `[[keys.command]]` block      |
| The herdr server inherits a complete `PATH` (nvm, `.opencode/bin`, `.local/bin`, homebrew) | No login-shell wrapper needed around the launched command                             |

## Decisions

**Separate key, not a replacement.** `prefix+shift+c` rather than taking over
`prefix+c`. herdr's built-in `new_tab` stays as a dependency-free escape hatch —
if fzf breaks or the script has a bug, a plain shell is still one keystroke away.

**`type = "pane"`, not `"popup"`.** Both render fzf correctly. `pane` is
non-modal and self-closing, so it cannot contend with focusing the tab the picker
creates. `popup` is session-modal and was the prime suspect during a
mis-attributed "loop" report; `pane` removes the question entirely.

**fzf over a native menu.** herdr has no built-in list widget, and a static menu
does not scale or support type-to-filter. `brew install fzf` is the only new
dependency.

**Two pickers, not one combined list.** A pre-joined `repo → cli` list is one
keystroke shorter but N×7 entries long. Two stages keep both lists short and let
the CLI prompt name the chosen repo.

**`exec $SHELL -l` chained after the CLI.** Without it the pane sits at a dead
prompt when the CLI exits. Chaining a login shell leaves you in the project
directory. This is race-free, unlike `create` + `send-keys`, which can drop
characters if the shell has not finished starting. Mirrors the `fallback` policy
in [`bin/herdr-wire-space.sh`](../bin/herdr-wire-space.sh).

**Git repos only, `-name .git` not `-type d`.** Matching the name rather than the
type finds linked worktrees, where `.git` is a file. Repo-only filtering keeps
scratch directories out of the list.

**Menu filtered by `command -v` at runtime.** `CLI_MENU` can list optimistically;
anything not on `PATH` is dropped. `agent` is omitted because it is a symlink to
`cursor-agent`.

## Rejected (YAGNI)

Deliberately not built. Each is cheap to add later if a real need appears.

- Jump to an existing tab if the project is already open
- Recent / frecency ordering
- Session or workspace creation (tabs only)
- A config file for `CLI_MENU` — editing the array in the script is simpler

## What went wrong

Recorded because the failure mode is likely to recur across this fleet.

The `Ctrl-b c` prefix was assumed to be tmux and a full tmux implementation was
written, verified, and committed to the wrong target before anyone checked which
multiplexer was actually running. It was herdr. Then, after porting to herdr, the
binding still did nothing — because the Node's `config.toml` is not what a
remote-attached client reads.

Three layers, each hiding the next: wrong multiplexer → wrong config file →
wrong _machine_. The general lesson: **verify which process is actually
interpreting the keystroke before writing config for it.** `ps`, the client log,
and `--help` would each have caught this in under a minute.

A "loop" reported mid-session was also misattributed to the binding. It was test
tabs being created and driven via the API in the user's live session. Test
against a throwaway workspace, not the one someone is watching.

## Verification performed

- herdr popup/pane provides a real tty; fzf renders and filters inside it
- Both picker stages render; `Esc` at either stage cancels without creating a tab
- `tab create` → correct `cwd` and label; `pane run` executes; login shell survives
- Guards: missing `herdr`, missing `fzf`, non-existent roots, roots with zero repos
- Worktree detection (`.git` as a file)
- End-to-end through the real keybinding, by the user, after reattaching with
  `--remote-keybindings server`

Not verified by automation: the `--remote-keybindings server` flag itself, which
runs on the client machine. Confirmed working by the user.
