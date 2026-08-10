# Fleet auth bootstrap — logging the agent CLIs in across six workers

**Date:** 2026-08-10
**Status:** approved, not yet implemented
**Relation:** phase 3 of the herdr spaces work. Independent of
`2026-08-10-herdr-layout-json-design.md` — neither blocks the other.

## Problem

After re-wiring the fleet, every `codex` and `cursor` pane sat at a first-run
sign-in prompt. The reboot did not break authentication; it restarted each CLI
at its login screen and exposed a gap that predates it.

Measured state on 2026-08-10:

| Host | claude | codex | cursor |
| --- | --- | --- | --- |
| aorus | ✗ | ✗ | ✗ |
| aorus4 | ✓ | ✗ | ✗ |
| aorus5 | ✓ | ✗ | ✗ |
| aorus6 | ✓ | ✗ | ✗ |
| aorus7 | ✓ | ✓ | ✗ |
| aorus8 | ✓ | ✓ | ✗ |

Eleven logins are needed: **cursor on all six**, **codex on four**, **claude on
one**. `cursor-agent` has never been logged in anywhere, including the two hosts
that have run claude and codex for weeks — so this is a standing gap, not
reboot fallout.

Doing this by hand means eleven interactive ssh sessions. The goal is not to
eliminate the human — OAuth requires a browser — but to reduce eleven sessions
to roughly three rounds of attention.

## Constraints discovered

**API keys are not an option.** `~/.claude/.env` holds no `OPENAI_API_KEY` or
`CURSOR_API_KEY`, and the sign-in prompts route to subscription plans ("usage
included with Plus, Pro, Business") which cost less than per-use API billing.
The OAuth flows are the intended path, not a fallback.

**Two CLIs need a PTY.** `claude setup-token` and codex's sign-in menu produce
no output over a plain ssh pipe. `cursor-agent login` does not — it prints its
URL over a pipe quite happily.

**Nothing outside a herdr pane can supply that PTY here.** An automation
context without a controlling terminal cannot allocate one over ssh
(`Pseudo-terminal will not be allocated because stdin is not a terminal`).
herdr panes are PTYs, which is what makes pane automation the mechanism rather
than a convenience.

**cursor's flow is poll-based, not callback-based.** With `NO_OPEN_BROWSER` set
it prints:

```
Open a browser and navigate to this link:
https://cursor.com/loginDeepControl?challenge=…&uuid=…&mode=login&redirectTarget=cli
```

`redirectTarget=cli` means the CLI polls Cursor's servers using the
challenge/uuid pair. The URL therefore completes the login **when opened on any
machine** — no localhost callback, no ssh port forwarding. This is what makes
the six cursor logins cheap.

By contrast, an OAuth flow that calls back to `localhost` would fail silently
when its URL is opened elsewhere: the callback would hit the *browser's*
localhost, not the remote's. Codex's "Sign in with ChatGPT" is such a flow,
which is why the design uses its "Sign in with Device Code" option instead.

## Design

A new `scripts/herdr-auth.sh` with two verbs:

```
herdr-auth.sh status            # what is logged in where
herdr-auth.sh login [--cli cursor|codex|claude] [--host H]...
```

`status` is read-only and safe to run any time. `login` drives the flows.

### Class 1 — cursor (six hosts, no PTY)

Runs over plain ssh, in parallel across hosts:

```bash
ssh "$host" 'bash -lc "NO_OPEN_BROWSER=1 cursor-agent login"'
```

Each invocation prints its URL. The script collects all six, opens them
together with `open` on the node, and leaves the remote processes polling.
Because it is the same Cursor account for every host, the first browser login
carries the session and the remaining five are near-instant confirmations.

### Class 2 — codex (four hosts) and claude (one), PTY required

Driven inside the space's existing herdr pane:

```bash
herdr pane send-keys  "$pane" Down Enter          # select "Sign in with Device Code"
herdr pane wait-output --regex '<code-or-url>' "$pane"
herdr pane read "$pane"                            # extract
open "$url"                                        # on the node
```

The exact key sequence and match pattern per CLI must be confirmed against a
live pane during implementation; they are the one part of this design that
cannot be settled without a PTY.

The existing wiring guards apply unchanged: never drive the pane running the
script, and never send keys to a pane herdr reports as having a live agent
unless `FORCE=1`.

### Completion detection

Each CLI reports its own state, so the script polls rather than guessing:

| CLI | Probe | Success |
| --- | --- | --- |
| cursor | `cursor-agent status` | not `Not logged in` |
| codex | `codex login status` | `Logged in using ChatGPT` |
| claude | `~/.claude/.credentials.json` exists | file present |

Poll every 5s to a 5-minute ceiling per host, then report the failure and move
on. One stalled login must not block the other ten.

### Security

Auth URLs carry a PKCE `challenge` and are effectively bearer credentials for
that login attempt. They are therefore:

- **never written to disk** — held in shell variables only, passed straight to
  `open`;
- **never logged** — the script prints `opened login URL for <host>`, not the URL;
- **never committed** — no fixture in this repo may contain a real challenge.

This follows the existing secret-handling rule: reference credentials, never
persist them.

Credential files are **not copied between hosts.** It would be faster — five
hosts already hold claude credentials — but the tokens may be device-bound, and
duplicating live secrets across six machines to save a few clicks is a poor
trade.

### Orchestration

Batched by CLI, parallel within a batch:

1. **cursor ×6** — parallel over plain ssh, six URLs opened together
2. **codex ×4** — via panes
3. **claude ×1** — via pane

Roughly three rounds of user attention instead of eleven. Each batch verifies
before the next begins, so a failure surfaces against a small set of hosts.

## Testing

`status` is the natural test harness: it reads live state across the fleet and
is safe to run repeatedly. Verification is the before/after table at the top of
this document, regenerated.

Unit-testable pieces, none of which need a live host:

| Case | Asserts |
| --- | --- |
| URL extraction from captured pane text | correct URL from surrounding noise |
| Redaction | log lines never contain `challenge=` |
| Completion probes | each CLI's logged-in and not-logged-in output parsed correctly |
| Poll timeout | gives up at the ceiling, reports, continues to the next host |

Fixtures use synthetic URLs with a placeholder challenge, never a real one.

## Open items

- **Codex device-code key sequence.** The TUI menu offers "Sign in with Device
  Code" as option 2; the exact keys and the code's output format need
  confirming against a live pane.
- **`claude setup-token` flow shape.** Unobservable without a PTY; needs the
  same live-pane confirmation.
- **Whether cursor's six logins can share one browser session.** Expected, since
  it is one account, but unverified.

## Out of scope

- Keeping sessions authenticated over time. This is a one-time bootstrap; token
  refresh and expiry are a separate concern.
- API-key-based auth. Revisit only if subscription sign-in proves unworkable.
- Copying credentials between hosts, for the reasons above.
- The `pi` CLI, which was not part of the observed gap.
