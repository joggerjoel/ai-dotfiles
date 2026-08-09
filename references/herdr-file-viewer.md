# herdr-file-viewer

Git-aware, read-only file viewer for herdr — a keyboard-driven TUI in a split
pane: directory tree on one side, content pane on the other, with diffs,
rendered markdown and syntax highlighting.

- **Source:** [smarzban/herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer)
- **Installed:** v1.15.0 @ `71d4c1c`, 2026-08-09
- **Requires:** herdr ≥ 0.7.0 (this host runs 0.8.0)

Companion doc: [herdr-file-viewer-prompts.md](herdr-file-viewer-prompts.md) —
how to summon it from a Claude session.

## Install

```bash
herdr plugin install smarzban/herdr-file-viewer
```

Three unrelated GitHub repos are named `herdr-file-viewer`. Always install by
full `OWNER/REPO` — a bare name is ambiguous and `herdr plugin install` requires
the owner anyway.

Install prints a preview manifest (actions, panes, build commands) before
running anything. That preview is the moment to inspect: `fetch-or-build.sh` is
third-party shell executing on your machine. It downloads a prebuilt binary
matching the version and platform, verifies its SHA-256, and falls back to a
`cargo` build on any miss.

## Where things live

| Path                                                           | What                                                        |
| -------------------------------------------------------------- | ----------------------------------------------------------- |
| `~/.config/herdr/config.toml`                                  | herdr's own config — **TOML**, holds the keybindings        |
| `~/.config/herdr/plugins/config/herdr-file-viewer/config.toml` | the plugin's config — separate file, not created by install |
| `~/.config/herdr/plugins/github/herdr-file-viewer-<hash>/`     | plugin root (content-addressed)                             |

The plugin root's hash suffix is neither the commit nor a sha256 of the source
slug. Its stability across upgrades is unverified — resolve it at runtime rather
than hard-coding it:

```bash
herdr plugin list --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["plugins"][0]["plugin_root"])'
```

## Keybindings

Applied to `~/.config/herdr/config.toml`. Note `type = "plugin_action"` — not
the `type = "pane"` form the project launcher uses.

```toml
[[keys.command]]
key = "prefix+f"
type = "plugin_action"
command = "herdr-file-viewer.open-file-viewer"
description = "open file viewer in split"

[[keys.command]]
key = "prefix+shift+f"
type = "plugin_action"
command = "herdr-file-viewer.open-file-viewer-tab"
description = "open file viewer in tab"
```

```bash
herdr server reload-config
```

A successful reload returns `"status":"applied"` with an **empty `diagnostics`
array**. herdr validates per-entry — unknown intent names, unbindable keys and
duplicate claims are reported individually rather than rejecting the file — so
an empty diagnostics list is stronger evidence than exit code 0 alone.

The tab action is idempotent: it switches to an existing viewer tab rather than
duplicating it, and toggles off when you are already on it.

## Content renderers (required for the good parts)

The viewer pipes file content **on stdin** to three external programs. When one
is absent that pane silently degrades to plain text with a notice — the plugin
"works" while losing most of its value.

| Package     | brew binary | apt binary                                                     |
| ----------- | ----------- | -------------------------------------------------------------- |
| `bat`       | `bat`       | **`batcat`** — Debian renamed it over a `bacula-console` clash |
| `git-delta` | `delta`     | `delta` (universe)                                             |
| `glow`      | `glow`      | `glow` — **not in Ubuntu's archives**, needs Charm's apt repo  |

```bash
brew install bat git-delta glow
```

`setup.sh` (`ensure_herdr_renderers`) and `update.sh` (§3c) handle both package
managers, add Charm's repo on apt, and symlink `batcat` → `~/.local/bin/bat` so
the viewer's default `syntax` command resolves on Debian.

## Plugin config

Optional. Create `~/.config/herdr/plugins/config/herdr-file-viewer/config.toml`;
a missing file is normal, and a malformed one is ignored whole (every key falls
back to its default, flagged in the `?` overlay's Settings tab). Read-only
input, picked up on relaunch — there is no in-app settings editor.

**External programs.** Split like a shell would (whitespace, double-quotes group
paths) but **no shell is invoked**. Two different I/O contracts:

- `editor` / `open` / `reveal` receive the target **path** as the final argument
- `markdown` / `diff` / `syntax` receive file **content on stdin**

For the stdin three, your value **replaces the whole default command** — flags
are not merged — so it must read stdin (`bat` and `glow` need a trailing `-`)
and set its own color flags. `{name}` substitutes the file name.

```toml
editor = "code --wait"
markdown = "glow -s dark -w 0 -"
diff = "delta"
syntax = "bat --color=always --style=numbers --paging=never --file-name={name} -"
```

Theming lives here, not in a `theme` key — there isn't one. Pass
`--theme='Monokai Extended'` to `bat` and equivalents to the others.

**Startup toggles:** `hide_dotfiles` (false), `show_ignored` (false),
`compact_dirs` (false), `update_check` (true), `confirm_discard` (true),
`scroll_lines` (3, scale 1–10).

**Layout:** `tree_width` (30, percent 20–80), `tree_max_cols` (30, hard cap in
columns), `tree_position` (`"left"`/`"right"`).

> Gotcha: the **smaller** of `tree_width` and `tree_max_cols` wins. Raising
> `tree_width` alone usually does nothing because the 30-column cap governs.
> Tune both.

**Preview caps:** `preview_max_lines` (10000, range 100–100000) and
`preview_max_kib` (1024, range 64–65536). Whichever trips first truncates. The
line cap usually bites on source; the size cap guards minified/generated files
and bounds how much is ever read from disk.

**Keybindings:** a `[keys]` table remaps any of 39 global actions by stable
snake_case intent name (`refresh`, `nav_up`, `switch_worktree`). An entry
replaces that action's defaults, so list every key you want.

## In-viewer keys

`?` help (Settings + Keybindings tabs show what is actually in effect) · `/`
search · `.` toggle dotfiles · `i` show gitignored · `e` `$EDITOR` · `O` open
externally · `R` reveal in file manager · `a`/`A` annotate · `W` switch worktree
· `q` quit · `Esc` close

**No `Ctrl` / `Alt` chords.** A chord never fires a viewer action, so `Ctrl+C`
and friends pass straight through the terminal. `Esc` always closes and cannot
be rebound away, so a remap can never lock you out.

Annotations (`a`/`A`) are session-only — both `q` and `W` destroy them, with a
confirm offering to copy them to the clipboard on the way out.

## Managing panes from the CLI

```bash
# find it — the viewer pane carries label "Files"
herdr pane list | python3 -c 'import json,sys; print([p["pane_id"] for p in json.load(sys.stdin)["result"]["panes"] if p.get("label")=="Files"])'

herdr plugin pane close <pane_id>
herdr plugin pane focus <pane_id>
```

`herdr plugin pane` has `open`, `focus` and `close` — **no `list`**. Use
`herdr pane list` and filter on `label == "Files"`.

## The bundled skill

The plugin ships `skills/herdr-file-viewer/SKILL.md`, an **agent-facing** skill
teaching an assistant to open a resolved file/line/range in a Files pane.

A herdr plugin's `skills/` directory and Claude Code's `~/.claude/skills` are
two unconnected conventions that happen to share a filename — **there is no
auto-discovery**, so the skill is inert until something bridges them. Here it is
vendored to `skills/herdr-file-viewer/` in this repo, which deploys via
`setup.sh` (`cp -R`, line ~521) and reaches the fleet.

Re-vendor after a plugin upgrade; the copy carries a provenance header with the
command.

## Gotchas

- **Never pass `--cwd`** to `herdr plugin pane open`. herdr resolves the
  relative pane command against it, so the launch fails everywhere except inside
  a built plugin checkout — where it silently runs _that_ checkout's binary
  instead of the installed one. A failure that looks like success.
- **Never inject `HERDR_PLUGIN_CONTEXT_JSON`** — herdr regenerates and discards it.
- **The viewed root comes from the focused herdr pane's cwd**, resolved to that
  repository's worktree top level. `cd`-ing in another process does not move it.
  To target a different repo, split a helper pane with `--cwd "$repo"`, launch,
  then close the helper — the root is captured at launch.
- **The opened pane's reported `cwd` is the plugin's own directory.** That looks
  wrong and is expected. Confirm the target from the rendered tree's root row and
  the branch in the tree border instead.
- **Open targets apply only when a new viewer starts.** Don't retarget an
  existing Files pane — it may hold the user's annotations or navigation state.
- **Don't key-script the TUI.**
- **`herdr --remote` does not forward local `plugin_action` bindings.** Put the
  binding in the remote server's `config.toml` and attach with
  `--remote-keybindings server`.

## Things that are not true

Circulating AI-generated setup instructions for this plugin are wrong in every
particular. For the record:

| Claim                                                  | Reality                                                                                                                        |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `~/.herdr/config.json`                                 | Does not exist. It is `~/.config/herdr/config.toml`, TOML                                                                      |
| a `"plugins": [...]` array enables it                  | No such array. Install enables it; toggle with `herdr plugin enable/disable`                                                   |
| per-agent `agents.claude-code` / `agents.codex` blocks | No per-agent config exists; the viewer is agent-agnostic                                                                       |
| a `"theme"` key                                        | There is none. Theming goes through `bat`/`delta`/`glow`                                                                       |
| `Ctrl+P` toggles the tree                              | No Ctrl/Alt chords fire viewer actions at all                                                                                  |
| it follows an agent's edits in real time               | The manifest states it "appears ONLY in response to an explicit action — there are no event hooks and no automatic invocation" |
