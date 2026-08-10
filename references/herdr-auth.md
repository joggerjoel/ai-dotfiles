# Fleet agent-CLI authentication

`scripts/herdr-auth.sh` reports and repairs the workers' agent-CLI login state.

    just auth-status          # read-only: what is logged in where
    just auth-login cursor    # drive one CLI's flow across the fleet
    just auth-test            # unit tests, fully stubbed

## What is implemented

`status` covers all three CLIs. `login` covers **cursor only**. `codex` and
`claude` exit 2 with `unknown or unimplemented cli` — see Two classes below for
why they are harder, and Not built yet for what finishing them requires.

## Two classes, and why

`cursor-agent` prints its login URL over a plain pipe and then polls Cursor's
servers (`redirectTarget=cli`). No PTY, no localhost callback — the URL
completes the login opened from **any** machine, including a phone. All six
hosts run in one pass.

`codex` and `claude` produce nothing without a controlling terminal. An
automation context with no TTY cannot allocate one over ssh at all
(`Pseudo-terminal will not be allocated because stdin is not a terminal`).
herdr panes _are_ PTYs, so those flows would be driven with `pane send-keys` /
`pane wait-output` / `pane read`.

Prefer codex's **Sign in with Device Code** over **Sign in with ChatGPT**: the
latter calls back to `localhost` on the machine running codex, so a URL opened
on your Mac hits the wrong localhost and the flow dies silently.

## Not built yet

The PTY path is deliberately unimplemented rather than guessed. Driving it needs
two things that cannot be read out of any documentation:

- the exact key sequence codex's device-code menu expects
- the shape of `claude setup-token`'s flow — what it prints, and when

Both are observable only by running the real flow in a real pane and watching.
Writing them from assumption produces automation that types the wrong keys into
a live login prompt, which is worse than not automating at all. Record what a
live pane actually does, then implement.

## Login URLs are credentials

A login URL carries a PKCE `challenge` — a bearer credential for that attempt.
The script holds it in a shell variable and passes it straight to `open`. It is
never written to disk, never logged, never committed; output says
`opened login URL for host aorus`, never the URL. `redact()` is the single
choke point, and every printed line goes through it.

`redact` is an allowlist: every parameter value is masked except a few known-safe
keys. It fails closed on parameters it has not seen before, because a denylist
silently leaks the one key nobody thought of. Two residual risks are documented
in the code: a secret embedded in a URL _path_ (`/device/ABC-123`) is not
key=value and cannot be masked by this logic, and control bytes are stripped
rather than treated as separators. The primary control is that the script never
prints a URL at all — redaction is defence in depth, not the fence.

Credential files are **not** copied between hosts. Tokens may be device-bound,
and spreading live secrets across six machines to save a few clicks is a bad
trade.

## Naming hazard

`aorus` is a host _and_ the prefix of the other five. Never glob `aorus*` to
mean "the workers" — it matches all six. Say `host aorus` when you mean the box.

## Testing

    just auth-test

Every external command is stubbed on `PATH` (`tests/auth-stubs/`), so the suite
never touches the fleet and never starts a real flow. Fixtures use a synthetic
challenge; a real one must never enter this repo.
