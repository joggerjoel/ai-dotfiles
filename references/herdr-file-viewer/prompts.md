# Summoning the file viewer from a Claude session

What to say to get a location opened in a Files pane. Requires the vendored
skill (`skills/herdr-file-viewer/`) to be deployed — see [README.md](README.md).

## Direct targeting

Three target shapes resolve: `file`, `file:line`, `file:line-line`.

```
open setup.sh in the file viewer
show me setup.sh:273
open setup.sh:273-320 in Files
pull up skills/herdr-file-viewer/SKILL.md
```

## By symbol

No line number needed — it resolves the **definition**, not a call site.

```
show me ensure_herdr_renderers
open add_charm_apt_repo in the viewer
where's the batcat shim? open it
show me section 3c in update.sh
```

## Mid-conversation

Where it earns its keep — a location gets shown instead of pasted as a path you
then have to go find.

```
show me where that would break
open the line you just described
where would I change the tree width? show me
walk me through the diff — open each file as you go
review my hook config and open anything suspicious
```

The assistant will also _offer_ ("want me to show you where to change that?")
once it has identified a location while explaining something.

## What to expect

- **Ambiguous symbols get a question, not a guess.** Materially different
  matches with no disambiguating context produce a short question instead.
- **Hypotheses are labelled.** A suspected bug line is distinguished from an
  observed failure location rather than presented as certain.
- **Read-only.** Press `e` inside to hand off to `$EDITOR`.
- **An existing Files pane is left alone.** Open targets apply only when a new
  viewer starts, and a pane already there may hold your annotations or
  navigation state — so a fresh one is opened rather than the old one hijacked.
- **The root follows the focused pane.** If the target lives in a different
  repository than the focused pane's cwd, say which — the launch then goes
  through a throwaway helper pane so it roots correctly.
- **The exact target opened is stated afterward.** If it cannot be resolved to a
  real file under the viewer root, that is explained instead of opening an
  arbitrary or outside-root path.

## Under the hood

```bash
herdr plugin pane open --plugin herdr-file-viewer --entrypoint file-viewer \
  --placement split --direction right --focus \
  --env "HERDR_FILE_VIEWER_OPEN=src/app.rs:42"
```

The target is data, never shell source — shell-escape on assignment, expand only
inside double quotes, and prefer a structured argv that passes
`HERDR_FILE_VIEWER_OPEN=<target>` as one argument.

No `--cwd`, no injected `HERDR_PLUGIN_CONTEXT_JSON`. See the gotchas in
[README.md](README.md) for why both break in ways that look like success.
