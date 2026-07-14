---
name: verify-tui
description: Terminal-UI verification using tmux as a headless screen buffer (Bubble Tea, Ratatui, Ink, ncurses, etc.)
disable-model-invocation: true
allowed-tools: Bash(tmux:*), Bash(asciinema:*)
---

# Verify TUI

Test terminal-UI changes by actually running the application inside a tmux
session and reading back the rendered screen. This is the terminal-native
sibling of `verify-ui`: tmux gives you the same two primitives a browser does —
send input, capture what's drawn — for apps a browser can't see.

| verify-ui (browser)          | verify-tui (terminal)                  |
| ---------------------------- | -------------------------------------- |
| `agent-browser navigate URL` | `tmux new-session -d -s ui './app'`    |
| `agent-browser screenshot`   | `tmux capture-pane -p -t ui`           |
| `agent-browser click/fill`   | `tmux send-keys -t ui 'j' Enter`       |
| resize viewport              | `tmux resize-window -t ui -x 80 -y 24` |
| Chrome GIF recording         | `asciinema rec demo.cast`              |

## Process

### 1. Launch the app in a detached session

Pick an explicit size — TUIs reflow, so the size is part of the test.

```bash
tmux kill-session -t ui 2>/dev/null || true          # clean slate
tmux new-session -d -s ui -x 120 -y 40 './my-tui'    # cols x rows
```

### 2. Wait for first render (see `is_ready` below)

Never `capture-pane` immediately — a TUI paints asynchronously and you'll snapshot
a blank or half-drawn frame. Wait for a known marker to appear first.

### 3. Capture the rendered screen

```bash
tmux capture-pane -p -t ui        # visible screen as plain text
tmux capture-pane -p -e -t ui     # -e keeps color/escape codes
tmux capture-pane -p -S -100 -t ui  # include 100 lines of scrollback
```

`capture-pane -p` is your screenshot: it prints exactly what a human sees.

### 4. Drive interactions

```bash
tmux send-keys -t ui 'j' 'j' 'k'      # navigate (literal keys)
tmux send-keys -t ui Enter            # named keys: Enter, Escape, Tab, Space
tmux send-keys -t ui C-c              # Ctrl-C  (M-x for Alt-x)
tmux send-keys -t ui 'hello@test.com' # type a string into an input
```

After each interaction, wait for render (step 2) then capture (step 3).

### 5. Test reflow at a hostile size

The classic TUI bug is a layout that breaks in a narrow terminal.

```bash
tmux resize-window -t ui -x 80 -y 24
# wait for render, then capture and eyeball the layout
```

### 6. (Optional) Record a session for documentation

Requires `asciinema` (not installed by default: `brew install asciinema` /
`uv tool install asciinema`). This is the GIF-recording analog.

```bash
asciinema rec demo.cast -c './my-tui'   # records a real interactive run
```

### 7. Tear down

```bash
tmux kill-session -t ui
```

## Readiness helper

<!--
  DESIGN DECISION — owner input requested.

  Everything above assumes an `is_ready` step: after launching or sending input,
  block until the screen is actually painted before capturing. There is no
  built-in "load complete" event for a TUI, so how we decide "it's ready" is a
  real correctness/flakiness trade-off:

    - Fixed sleep         -> simple, but flaky (too short = blank frame,
                             too long = slow suite). Not recommended as the default.
    - Poll for a marker   -> capture-pane in a loop until an expected string
                             appears (or timeout). Robust, but needs a marker
                             and a sane timeout/backoff.
    - Screen-stable poll   -> capture twice with a small gap; consider ready when
                             two consecutive frames are identical (no marker needed,
                             good for animations settling).

  Implement is_ready() below with your preferred strategy. Keep it ~5-10 lines,
  pure bash, and make the failure mode loud (exit non-zero on timeout — Fail Fast).
-->

Strategy: **marker poll** — screens carry stable, greppable text, so we loop on
`capture-pane` until an expected string shows up, and fail loudly on timeout.

```bash
# is_ready <session> <marker> [timeout_secs]
# Block until <marker> appears on <session>'s screen. 0 = ready, 1 = timed out.
is_ready() {
  local session="$1" marker="$2" timeout="${3:-5}"
  local deadline=$(( SECONDS + timeout ))
  until tmux capture-pane -p -t "$session" 2>/dev/null | grep -qF -- "$marker"; do
    if (( SECONDS >= deadline )); then
      echo "is_ready: '$marker' not found on '$session' within ${timeout}s" >&2
      tmux capture-pane -p -t "$session" >&2   # dump the frame we gave up on
      return 1
    fi
    sleep 0.1
  done
}
```

Use it after every launch or interaction, and let a failure abort the run:

```bash
tmux new-session -d -s ui -x 120 -y 40 './my-tui'
is_ready ui 'Main Menu' || exit 1      # Fail Fast — no blank-frame captures
tmux capture-pane -p -t ui

tmux send-keys -t ui Enter
is_ready ui 'Settings' || exit 1
tmux capture-pane -p -t ui
```

## Verification checklist

For each TUI change, verify:

- [ ] **Visual**: Does the rendered screen look correct? (`capture-pane -p`)
- [ ] **Interactive**: Do keybindings do the right thing?
- [ ] **Reflow**: Does it survive a narrow/short terminal (80x24, 40x20)?
- [ ] **States**: Loading, error, empty, and "no data" screens.
- [ ] **Exit**: Does `q` / `Ctrl-C` quit cleanly without leaving a broken terminal?

## Guidelines

- Always launch detached (`-d`) and target by session name (`-t ui`) — never
  attach interactively, or you can't script it.
- Size is a test input, not a detail. Verify at least one hostile size.
- Prefer `is_ready` polling over `sleep`; a fixed sleep is the #1 source of
  flaky TUI checks.
- Capture the failing frame to a file before killing the session, so the
  evidence survives (`tmux capture-pane -p -t ui > /tmp/tui-fail.txt`).
- Iterate until the UX feels right at real sizes, not just "renders".
