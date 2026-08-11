# Serialised paste-login — driving the flows a human has to carry

`herdr-auth.sh login --cli claude|codex` walks the fleet one host at a time,
because these flows hand a value to a human who has to carry it back. The relay
that does the carrying is `herdr-paste.py`; this document is the loop around it.

Designed 2026-08-11, after a cold review overturned two of its arguments and one
of its answers.

## Why serial, stated correctly

An earlier draft justified this with "the human is the serial resource" and
"parallel minting starts every TTL clock at t=0". Both are true of
`login --cli cursor` as well, which is correctly parallel — so neither can be
the reason. The review caught it; the honest reason is **duration**:

- cursor: the human clicks through, nothing comes back, seconds per host. Six
  codes minted at once are all consumed well inside their TTL.
- claude/codex: the human reads a value, moves it to another device, pastes it.
  Minutes per host. Six codes minted at once means the last has been alive for
  ten-plus minutes against a ~15-minute TTL before anyone reaches it, and an
  interruption expires the tail of the queue.

Serial minting gives every host a full TTL. That is the argument. The
correlation benefit — one browser tab, one pending pane, nothing to mix up —
is real but secondary; it would not on its own justify the wall-clock.

## The loop

Per host, in this order:

    probe  →  skip if already authed
           →  serve the paste page, pinned to this host's pane
           →  start the flow in that pane
           →  read the login URL from the pane
           →  open the URL locally
           →  wait for the paste to be delivered
           →  probe again to verify
           →  tear down the page, advance

**The page comes up before the URL opens.** An earlier draft had it the other
way, which loses to a fast human: complete the login quickly and the value
exists before the thing meant to receive it does.

**The probe is `herdr-auth.sh`'s existing `probe <cli> <host>`** — the same
check `status` prints, so "authed" means one thing everywhere.

## Outcomes, and where they come from

Every per-host result is exactly one of these. Each has a producer; none is a
judgement call.

| Outcome          | Produced by                                                       |
| ---------------- | ----------------------------------------------------------------- |
| `authed-already` | the opening probe                                                 |
| `delivered`      | paste succeeded **and** the verifying probe reports authed        |
| `unreachable`    | ssh to the host fails                                             |
| `no-url`         | the pane produced no login URL within 60s                         |
| `refused`        | the paste was rejected, or the verifying probe still says missing |
| `ambiguous`      | `herdr-paste.py` exited **3**                                     |
| `abandoned`      | no paste arrived before the page's 10-minute timeout              |

`ambiguous` is not a judgement: it is `send_input()` raising `Ambiguous`, which
happens on a socket timeout or an EOF with no reply — the write may have landed.
`herdr-paste.py` surfaces it as exit 3 precisely so a caller can tell it apart
from a refusal, and this loop is that caller.

`abandoned` is distinct from `refused`. Nothing was delivered, but nothing was
rejected either — the operator walked away, and the device code may still be
usable if they come back inside its TTL.

## Question 1 — a host fails mid-loop

**Continue, record, summarise at the end — with one prompt on the first
failure.**

Stopping at host 2 of 6 re-runs the rest later and mints fresh codes, which is
the waste serialisation exists to avoid. An unreachable host should not decide
the fate of five healthy ones.

But a first failure may be systemic — the daemon is gone, the network dropped,
the vendor is refusing everything — and grinding through four more hosts to
produce four more failures wastes both codes and the operator's evening. So the
**first** non-`delivered` outcome prompts:

    host aorus4: unreachable. continue with the remaining 4 hosts? [Y/n]

Once answered, the answer holds for the rest of the run. That is one question,
not the per-failure interrogation an earlier draft rejected the option for —
which was an unfair dismissal, since the prompt only fires when something is
already wrong.

`ambiguous` does **not** trigger the prompt. It is not a failure; the loop
records it and moves on.

## Question 2 — resumability

**Stateless where state can be re-derived; journalled only where it cannot.**

The first draft proposed no state file at all: probe each host, skip the authed
ones, and let re-running the command be the resume mechanism. The review killed
it, and the reason is worth keeping:

> A host that went ambiguous probes as **not authed**. So a plain re-run
> restarts its flow — which is an automatic resend of a possibly-landed code,
> with no human deciding anything about that host. The absolute rule below
> forbids exactly that.

The two answers were incompatible in the same document. So:

- **Auth state stays stateless.** It comes from the probe. The fleet is the
  source of truth, re-running is idempotent for every ordinary host, and there
  is no file to go stale.
- **`ambiguous` is journalled**, because it is the one outcome the fleet cannot
  tell you about later. `~/.config/herdr/paste-login.json` records host, CLI and
  timestamp — no URLs, no codes, no values.

A journalled host is **skipped** on the next run with a line saying why, and
clearing it is an explicit act:

    just auth-login claude                    # skips aorus6, says it is pending
    just auth-login claude --retry aorus6     # clears the mark, runs the host

That is where the human decision the rule demands actually lives. Without the
journal the rule has no enforcement point at all.

Entries older than 24h are dropped on read: a device code cannot still be in
flight, and a stale mark that blocks a host forever is its own failure mode.

## What this must not do

**No automatic resend of a value that may have landed. Ever.** A device or
OAuth code is single-use in every flow this drives; resending one that did land
invalidates the login server-side while every terminal involved looks fine. The
loop may re-probe as often as it likes. It may not re-deliver without a human
clearing the journal entry by name.

## The URL comes from the pane, and is checked

`pane read` returns scrollback, which can hold a stale URL from a previous
attempt, and pane content is attacker-influenceable in general. So the URL is
taken from output produced **after** the flow was started in that pane, must
match the CLI's expected host (`claude.ai` / `chatgpt.com` respectively), and is
opened with `open` as a URL argument — never through a shell.

A URL that does not match, or does not appear within 60s, is `no-url`. The loop
does not open something it cannot account for.

## Concurrency

Two runs against one fleet would race for the same panes and double-consume
codes. The loop takes an exclusive lock (`~/.config/herdr/paste-login.lock`,
`flock`) for its whole duration and exits 2 if another run holds it, naming the
pid.

## Teardown

Skipping a host does not leave litter: the pinned page is shut down, the
capability dies with it, and the held value never outlives the process. The pane
is left as-is — a flow waiting for a paste is the operator's to abandon or
finish, and killing it would destroy a usable device code.

## Exit codes

`0` every host authed · `1` at least one `refused`/`unreachable`/`no-url` ·
`2` usage, or another run holds the lock · `3` at least one `ambiguous`, nothing
worse · `7` at least one `abandoned`, nothing worse.

Worst outcome wins, so `0` means the fleet is genuinely done. A caller that
branches only on zero is correct by default.

## Security

The paste page is the credential-receiving component and its rules live in
`herdr-paste.md` — tailnet-only binding, per-run capability path, Host and
Origin checks, no logging of the value or the capability, single-flight, value
held in memory and never in a response body. This loop adds one requirement:
**one page per host, pinned to that host's pane**, so a page cannot deliver
somewhere the operator did not intend.

## Testing

Everything is stubbed: `ssh`, `herdr`, `open`, and `herdr-paste.py` itself
(exiting 0/1/3/7 on demand). The suite must cover: an already-authed host is
skipped without starting a flow; the page is up before the URL opens; a stale
scrollback URL is not opened; the first failure prompts and the answer sticks;
`ambiguous` is journalled and skipped next run; `--retry` clears exactly one
host; a stale entry is dropped after 24h; a second run refuses on the lock; and
worst-outcome-wins exit codes.
