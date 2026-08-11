# herdr-paste — getting a token from your hand into a pane

Designed 2026-08-10. Revised twice under adversarial review; the decisions
below carry their reasoning, not the review history.

## The problem

Some login flows cannot be automated end to end, because a value has to travel
through a human. `claude setup-token` prints a URL, you authenticate in a
browser, and it hands you a token that must be **pasted back** into the waiting
prompt. codex's device flow has the same shape with a code.

`cursor-agent` does not have this problem — it polls Cursor's servers itself,
so the machine finds out on its own (see `herdr-auth.md`). That is what makes
`login --cli cursor` fully automatable and the other two not.

The gap is small and specific: the token is in your hand, or on your phone, and
the prompt waiting for it is inside a herdr pane on a machine you are not
typing at.

## Why a relay, not a login driver

This does one thing: put text into a pane. It does not start flows, know what
a token is for, or track auth state. The orchestration can be built on top
later; extracting a primitive back out of a flow driver is the harder
direction.

It is small. That is not the same as easy to get right.

## One program, three verbs — `scripts/herdr-paste.py`

    herdr-paste.py list            # panes, numbered — read-only
    herdr-paste.py send            # pick, paste, confirm, deliver — one process
    herdr-paste.py serve           # the page; runs until send or timeout

**`send` is self-contained on purpose.** It lists, lets you pick, captures the
target's identity at that moment, prompts for the value, confirms, re-verifies
and writes — all in one process.

An earlier design had `send <pane-id>` take the id from a previous `list`. That
is not *impossible* — `--expect-tab` below hands identity over argv, so the channel
plainly exists. It is wrong for a different reason: it makes the unverified path
the default and the verified one opt-in. A bare pane id is all most people would
ever type, and a bare pane id can only support "is this id still present?",
which is the check this document rejects below. The picker inverts that: you get
identity capture for free and have to go out of your way to skip it.

`list` remains as a read-only view for eyeballing the fleet; it is not a step in
`send`. `list --json` emits the full records — `tab_id` included — which is
where a scripted caller gets the value `--expect-tab` needs; the human-readable
form deliberately omits it as noise.

For scripted use, `send --pane w3:p1 --expect-tab w3:t2 --stdin --yes` supplies
the identity explicitly and skips both the picker and the prompt; a mismatch
still aborts. `--yes` is not enforced there — omitting it simply blocks on a
confirmation no script will answer, which is a hang rather than an error. It is
listed because scripted callers need it, not because anything checks.

**`--pane` without `--expect-tab` is a usage error (exit 2), not a shortcut.**
Otherwise the unverified path this design rejects would reappear as the easiest
thing to type, which is exactly how it got rejected.

**Python, not bash, and one file.** The credential must be JSON-encoded by
`json.dumps`, read without echo and without whitespace trimming, and handed to a
socket without ever touching argv, the environment, or a temp file. Bash can do each of
those — `IFS= read -rs` does not trim, and `printf '%s' "$v" | python3` reaches
stdin without argv or a temp file — but every one of them is the careful form of
a construct whose obvious form is wrong (`read -rs` trims; `<<<` and heredocs
can materialise a temp file). A shell wrapper calling a Python
helper would also make "the CLI and the page share one implementation"
unimplementable: an HTTP handler cannot call a shell function by name.

So both front-ends are entry points in the same module, calling the same two
functions:

- `list_panes()` → `[{n, workspace, tab_id, pane_id, label}]` — `tab_id` and
  `pane_id` are the daemon-assigned identity; `workspace` and `label` are
  display only, and there is no separate `workspace_id` because the pane id
  already encodes it
- `validate(value)` → the payload rules, raising with a named reason. Called at
  input time by both front-ends, so an invalid value is refused before a human
  is asked to confirm anything
- `send_input(identity, value)` → the protocol re-check, the identity re-verify
  against a fresh listing, the encode and the socket write — the bracketed tail,
  in one place — plus a re-assert of `validate()` as a cheap invariant, so the
  socket write is unreachable with an unvalidated value no matter who calls it.
  `identity` is the `(tab_id, pane_id)` pair; the re-verify lives here rather
  than in each front-end because it is the check most worth not duplicating

`list` output looks like:

    1  aorus4      / claude              w3:p1
    2  aorus8-tmux / 07-dice-broadcast   w9:p2

The leading number is what you type at `send`'s picker; `--pane` takes the
`pane_id` for scripted use.

## Panes are chosen from a live list, and re-verified by identity

Convention-based targeting (`aorus4` → that space's `claude` tab) was dropped:
it assumes space=host and tab=CLI, which breaks for `-tmux` spaces, whose tabs
are session names, and for scratch splits, which have no convention.

**A pane id is not an identity.** It is stable until that pane closes, ids are
reused as panes come and go, and moving a pane between workspaces reassigns it.
The window here is long by construction — it spans a human authenticating in a
browser.

Re-listing and checking the id is still present does **not** close this: a
recycled id _is_ present, attached to a different pane. So identity is the
`(tab_id, pane_id)` **pair**, captured when you pick and required to match a
fresh listing before the write.

A pane id is workspace-qualified (`w3:p1`) and is reassigned when a pane moves
between workspaces, so the workspace is already encoded in it — carrying a
separate `workspace_id` would be redundant, not stronger. `tab_id` is the part
that adds information.

**The label is not part of the identity match.** All three ids are assigned by
the daemon; the label is a tab title or tmux session name, which this document
classifies as attacker-controlled two sections down. Matching on it would let
whoever controls a pane's title forge a match or force a spurious mismatch. The
label is shown to you and compared for nothing.

**Confirmation blocks, and re-verification comes after it**, in both
front-ends. Confirmation waits on a human, which can take arbitrary time — so
verifying first and then confirming would reopen the very window the check
exists to close. The full gate order is given once, under "The response is read,
not assumed" below; this section only fixes the part that matters here —
confirmation happens **before** re-verification, never after.

- **CLI:** prints the target label and requires `y` (`--yes` skips it for
  scripted use, where `--expect-tab` supplies the identity instead).
- **Page:** a distinct confirm step, not a label beside a field. Submitting the
  form renders a confirmation view naming the target; delivery happens only on
  a second, explicit action. A label next to an input is informational, and this
  document's own rule is that confirmation blocks.

  Between those two POSTs the value is held **in server memory**, keyed by the
  capability, and is discarded on delivery, on an explicit Cancel action, or at
  the timeout. Not "on abandonment": HTTP cannot observe a closed tab or a
  operator who walked away, so the watchdog is the only backstop for that case
  and saying otherwise would promise a mechanism that does not exist.
  It is explicitly NOT round-tripped through the confirmation form as a hidden
  field: that would put the credential in a response body, which the section
  below forbids. The obvious implementation and a stated rule collide here, and
  the rule wins.

A mismatch aborts, showing the label recorded at pick time and the one now
holding that id. It never falls through to a write.

**This narrows the window; it does not close it.** The wire call carries only
`pane_id` — the socket API has no compare-and-send that would let the daemon
reject a write whose `tab_id` no longer matches — so a recycle occurring between
the re-verify and the write still lands the value in the wrong pane. What the
re-verify removes is the human-scale window (the minutes spent authenticating in
a browser); what remains is a few milliseconds of machine time. Saying it
"prevents" delivery to a recycled pane would be overclaiming, and closing it
properly needs a daemon-side feature that does not exist.

## Labels are untrusted input

Tab titles and tmux session names are set by whatever runs inside those panes —
remote ssh peers, CI output. `list` renders them into two hostile sinks:

- **Terminal:** on every path that prints a label — `list`, `send`'s
  confirmation line, and the mismatch-abort message, which prints two of them
  precisely when something is already wrong — strip both C0/C1 control
  codepoints (`U+0000`–`U+001F`, `U+007F`–`U+009F`) **and every Unicode format
  character** (category `Cf`: bidi overrides such as `U+202E`, zero-width
  characters, and the rest). By codepoint, not byte: stripping raw `0x80`–`0x9F`
  would mangle multibyte characters containing those bytes.

  Control codes alone are not enough where it matters most. A label is
  attacker-controlled, and `Cf` characters let it visually reorder or forge
  itself at exactly the moment a human is asked to approve a credential
  delivery — or make the two labels in a mismatch message look identical. That
  reopens this document's threat model at the display layer, after closing it
  for matching. For the same reason the confirmation line prints the
  daemon-assigned `pane_id` beside the label, as an anchor no pane can rewrite;
  homoglyphs can still make two labels look alike, and the id is what you
  actually compare.
- **Page:** HTML-escape every label. Unescaped, a session name is stored XSS on
  the exact origin holding the credential field.

## The wire call

`pane.send_input` submits the text and Enter atomically, so it cannot interleave
with another writer and leave a TUI reading a truncated paste-bracketed region.
`send-text` + `send-keys enter` can.

`herdr pane run` is **not** usable here: its signature is
`herdr pane run <PANE_ID> <COMMAND>...`, so the value would be an argv element,
world-readable via `ps` for the life of the process.

The request is one JSON object per line on `$HERDR_SOCKET_PATH`
(`~/.config/herdr/herdr.sock` here), of this shape:

    {"id":"paste-1","method":"pane.send_input",
     "params":{"pane_id":"w3:p1","text":"…","keys":["enter"]}}

**That illustrates the shape; it is not a template to fill in.** The request is
built by `json.dumps` on a dict. Interpolating the value into that string is the
injection, by two routes that are equally bad:

- a **newline** terminates the line and starts a second request the daemon
  executes — a `pane.run` with an attacker-chosen command;
- a **quote** closes the string and lets the payload append further keys. A
  duplicate `method` or `params` arriving after the originals is accepted
  last-wins by common JSON parsers, yielding a **well-formed** object with an
  attacker-chosen method. Calling this the lesser case, as an earlier draft did,
  was wrong.

Encoding closes both, which is why the mitigation was right even while the
analysis behind it was not. The payload is attacker-supplied by construction; whoever hands you the
"token" chooses those bytes.

**Protocol pin with a producer.** `pane.send_input` and its atomicity are pinned
to herdr **protocol 19**. At startup every verb reads `herdr api schema` and
**refuses to run** if the protocol differs, naming the expected and actual
values. A prose note to "re-verify on a bump" is not a gate; this is.

**Both** front-ends re-check immediately before each write, not only at startup.
`serve` can sit for ten minutes; `send` blocks on a human confirming, which by
this document's own argument takes arbitrary time. A daemon restart onto a new
protocol inside either window would otherwise reach the socket with a stale
gate, so the rule cannot apply to one and not the other.

## What the relay refuses to send

Validation is `validate()`, called by both front-ends at input time and
re-asserted inside `send_input()` — so the page is not a second path with its
own rules, and the check cannot be skipped by a caller that reaches the write
another way. It **rejects** rather than sanitises — silently altering a credential produces a login failure nobody can
explain.

**Accepted:** the value is non-empty and every **codepoint** is in `U+0020`–
`U+007E`. Codepoints, not bytes: the value arrives from `getpass()` or a decoded
request body as a `str`, so a byte-level rule would have to re-encode to be
checked, and the two only coincide inside ASCII anyway. Anything in that range
is trivially valid UTF-8, so no separate encoding clause is needed. The length floor is explicit
because an empty value satisfies a byte-range rule vacuously. Nothing else — no C0 or C1 control codepoints, no newline
anywhere including trailing, no non-ASCII. Bearer tokens, device codes and OAuth
codes are ASCII by construction; a value outside that set is a sign something
other than a credential is being relayed.

Rejection is explicit and names the offending class. `"printable"` is pinned to
a codepoint range rather than to `str.isprintable()` — not because that predicate is
permissive about separators (it correctly rejects U+2028 and U+2029), but
because it accepts the whole printable Unicode range, and a bearer token has no
business containing it. An explicit range is checkable by eye; a Unicode predicate is
a dependency on someone else's category tables.

Newlines fall outside that byte range already; the point worth stating is that
a trailing one is refused too rather than stripped. `keys:["enter"]` already
supplies the submission, so accepting one would send two, and stripping it would
be the sanitisation this section forbids.

This is not redundancy on top of `json.dumps` — it closes a hole encoding does
not touch:

- **Bracketed paste is not a protection this relay provides.** It is a mode of
  the _receiving_ application. A scratch split at a plain shell prompt is not in
  it, so an embedded newline becomes a submitted command line.
- **Escape sequences reach the terminal whatever the JSON validity.** OSC 52
  writes the operator's clipboard; title-set and status-report sequences can make
  a terminal echo attacker-chosen bytes back onto the input stream of whatever
  runs in that pane.

## The response is read, not assumed

`send` reads the reply and branches on it:

- **Success** → report delivered, naming the pane.
- **Error** (unknown or closed `pane_id`, malformed request) → report it; the
  value was not delivered.
- **No reply within 5s** → **ambiguous**, not failure. The write may have
  landed. `send` says so, exits **3**, and does not retry.

Exit codes, so a scripted caller can branch. `send`: **0** delivered · **1**
error reply · **2** usage · **3** ambiguous (may have landed) · **4** identity
mismatch · **5** protocol mismatch · **6** socket preflight failed. `serve`:
**0** a send landed · **7** timed out with no send · plus 2, 5 and 6 from the
same table for usage, protocol and preflight. Preflight gets its own code rather
than sharing 1, since "the daemon is not there" and "the daemon refused" call
for different reactions.

"The paste lands", used as an exit condition below, means a success reply was
read — never that a write returned.

**Retry is the human's call.** A device or OAuth code is typically single-use:
resending one that did land can submit it twice and invalidate the login
server-side while the terminal looks fine. Nothing here retries automatically,
and the web form is single-flight — a second submission while one is in flight
is refused rather than queued, so a double-click cannot double-submit.

**Preflight.** At startup — first of all the gates below — every verb checks
`$HERDR_SOCKET_PATH` exists and accepts a connection, failing fast and
explicitly if not. A stale socket
otherwise hangs or fails opaquely.

Gate order for a delivery, complete and stated once. `list` runs only the first
two; the scripted path skips pick and confirm (identity comes from
`--expect-tab`, approval from `--yes`):

    socket preflight
      → protocol check
      → pick (identity captured)
      → value read
      → payload validation
      → confirm
      → [ protocol re-check → identity re-verify → write ]
      → read reply

Preflight is first because the protocol check itself talks to the daemon
(`herdr api schema`): ahead of the fail-fast check, a stale socket would hang at
step one and the preflight would never run.

The bracketed tail is one uninterrupted block, entered only after the human
answers. Both of its checks re-run gates already passed, because confirmation
waits on a human and the world moves while it waits. Nothing else goes between
them and the write.

## The value is a credential — in both front-ends

- Never written to disk, never logged, never placed in argv or the environment,
  never included in an error message, never echoed back in any output.
- The no-leak property is tested against **both streams** — "never reaches the
  terminal" means stdout and stderr — and against every file and log line the
  run produces.

**CLI:** the value arrives on stdin only. Interactively `send` reads it from the
TTY with `getpass.getpass()`, which does not echo and does not trim; piping
requires an explicit `--stdin` flag.

The reason is narrower than it first appears, and worth stating correctly: with
`echo $TOKEN | …` the shell records the literal `$TOKEN` in history, and `echo`
is a builtin, so the expanded value never reaches another process's argv. Both
of the leaks originally claimed for that pipeline are false. What is real is
`echo sk-abc123… | …` — a token typed literally into a pipeline lands verbatim
in `.zsh_history`. The flag does not prevent that either; it makes the
non-interactive path a deliberate choice rather than the obvious one, and gives
the interactive `getpass` path primacy.

**Page:** POST body only, never a query parameter — a URL lands in the server's
request line and the phone's history. The form field is `type="password"` so the value is not
echoed on a phone screen in a cafe, with `autocomplete="off"` as a hint rather
than a control — modern browsers widely ignore it, so it is not load-bearing.
Responses carry `Cache-Control: no-store`, and the submitted value never appears
in a response body.

`BaseHTTPRequestHandler.log_message` is **overridden to a no-op**. Its default
logs the full request line to stderr, and the request line contains the
capability path — a bearer secret. The default would defeat the rule above.

## Exposure: the tailnet, a capability URL, and only while you need it

**Binding.** An HTTP server binds an _address_, not a named interface. At
startup `serve` runs `tailscale ip -4` and binds that literal address on port
**8778**. If the command fails, or returns anything other than exactly one
address, `serve` **refuses to start** rather than guessing — the fallback would
be `0.0.0.0`, silently publishing a terminal-injection endpoint to every network
this machine is on. If 8778 is already bound, `serve` reports the conflict and
exits; it does not pick another port, because the port is what an ACL names.

**Authorization.** `dev.herdr.bridge` already exposes the whole herdr socket on
`:7070` with no auth, and that does **not** license skipping auth here.

An earlier draft argued the bridge was safer because it is "a raw socket, not a
form target". That is wrong, and worth correcting rather than quietly deleting:
a cross-origin form POST with `enctype="text/plain"` writes attacker-chosen
lines into a newline-delimited JSON endpoint on a port browsers do not block.
The header lines fail to parse; the body lines are executed. The bridge is
browser-reachable too.

So the conclusion holds for a stronger reason than the one first given: **both**
surfaces are drivable by any site the operator's browser loads, without the
attacker ever joining the tailnet, and plain HTTP without a Host check adds DNS
rebinding on top. Inheriting that posture would be inheriting a defect.

So the page defends itself:

- A capability path minted per `serve` from `secrets.token_urlsafe(32)` and
  printed in the URL. Every other path 404s.
- `Host` allow-listed to exactly `<bound-ip>:8778`, on GET and POST alike.
- `Origin` absent **or** foreign → reject the POST. Absent is rejected too: a
  legitimate same-origin form post from this page carries one. Some mobile
  browsers and privacy extensions strip it, so the rejection says exactly that,
  naming the header — otherwise this reads as an inexplicable failure at the
  worst moment. The remedy is a different browser, not a weaker check.
- One-shot on **success**. A failed send leaves it alive so the human can retry
  within the window.
- An **ambiguous** send also leaves it alive, but the page then says the send
  may have landed and that resending a single-use code can invalidate the login
  — the same warning the CLI gives. Keeping the capability alive preserves the
  choice; it does not recommend retrying. Closing it instead would force a fresh
  `serve` for a case where retrying is sometimes right.

`dev.herdr.bridge` is recorded here as a known hole this document does not lean
on — and, per the correction above, a **browser-reachable** one rather than a
tailnet-only one, which makes restricting it more urgent than it first looked.
That belongs in a Tailscale ACL, tracked separately.

**Plain HTTP** is deliberate: Tailscale encrypts the transport, and a
self-signed certificate would train the wrong reflex.

**The page's flow, in order:** GET the capability URL → a `<select>` of panes
from `list_panes()`, each option carrying its `(tab_id, pane_id)` pair → paste
the value → POST → confirmation view naming the target → second explicit action
→ delivery. Identity is captured when the page is rendered, exactly as the
picker captures it in the CLI.

**The phone must be on the tailnet.** The server binds only the tailnet
address, so a phone that is not running Tailscale and joined to this tailnet
cannot reach the URL at all — the page's entire premise fails. `serve` states
this precondition in the text it prints beside the URL, so the failure reads as
a missing prerequisite rather than a broken link.

**Getting the URL to the phone.** The page exists because the token is on your
phone, so printing a 60-character URL into a terminal on the Mac would not
finish the job. If `qrencode` is on `PATH`, `serve` renders the URL as a QR
code in the terminal — `subprocess.run(["qrencode","-t","ANSIUTF8"],
input=url.encode())`, the URL on **stdin** and never as an argument, since the
capability path is a bearer secret and argv is world-readable. Written as a
Python call, not a shell pipeline: this document rejects shell precisely because
its careful forms are traps, and a pipeline in the spec invites one. Otherwise
it prints the URL alone and says why. The Python stdlib has no QR encoder, and
neither vendoring one nor adding a dependency is worth it for a convenience —
but the fallback has to be stated rather than implied, or the promise has no
producer.

**On-demand.** `serve` exits when the paste lands or after **10 minutes**,
whichever comes first — enforced by a watchdog timer, since the stdlib server's
`serve_forever()` will not stop on its own. Ten minutes is chosen against a 15-minute device-code TTL, the shortest of the
flows this relays. If a provider ever ships a shorter one, this number moves
with it — the relationship is the requirement, not the constant: long enough to authenticate on a
phone, short enough to close well before the credential does. A surface that
injects text into live terminals should exist while you are using it and not
otherwise. If that is ever traded for a launchd agent, the trade belongs here in
writing.

## Testing

`herdr`, `tailscale` and the socket are stubbed on `PATH`, as in
`tests/auth-stubs/`. Stubs model what the real thing does, not what is
convenient to assert: a stub that returns where the real one blocks is how a
deadlock shipped under 46 green tests in `herdr-auth.sh`.

**Encoding and validation** (the encoder is tested directly, not through the
validator, which would reject these inputs before they reach it)

- `json.dumps` encoding survives `"`, `\`, and a newline in the value: exactly
  one JSON object is produced, and it round-trips to the original string
- validation rejects, with a named reason and no write: interior newline,
  trailing newline, C0 codepoint, C1 codepoint, ANSI/OSC sequence, non-ASCII, empty value

**Target integrity**

- a `(tab_id, pane_id)` pair that no longer matches a fresh listing aborts the
  send with exit **4** — including the recycled-id case, where the pane_id is
  present but now sits under a different `tab_id`
- `--pane` without `--expect-tab` exits **2** and writes nothing
- a changed label alone does NOT abort: identity is the ids, not the title
- a `pane_id` absent from a fresh listing aborts the send
- confirmation is blocking: declining writes nothing
- re-verification happens AFTER confirmation: a pane whose identity changes
  while the confirmation prompt is waiting still aborts

**Protocol and transport**

- a stubbed protocol other than 19 refuses to run at startup, exit **5**
- a protocol that CHANGES between startup and the write aborts before writing,
  in both front-ends — the mid-run re-check, which the startup test cannot cover
- a missing socket fails fast at preflight rather than hanging, exit **6**
- an error reply reports failure; a silent daemon yields the ambiguous outcome
  and its distinct exit code at 5s
- no automatic retry follows an error or ambiguous outcome

**Credential**

- a sentinel value appears in no stdout, stderr, file, log line, **or HTTP
  response body** the run produces — the response body matters because the
  two-step confirm flow is where a hidden-field implementation would leak it
- responses carry `Cache-Control: no-store`
- the **capability path** appears in no log line, file, or argv. Its rule is
  narrower than the value's on purpose: `serve` must print it to the operator's
  own stdout and render it as a QR code — that is the whole point of it — so
  "the same treatment as the value" would be false by design. What it must never
  reach is anything persistent or world-readable, which is why `log_message` is
  a no-op and why the QR URL goes to `qrencode` on stdin
- the `qrencode` invocation's argv contains no URL — asserted by inspecting the
  recorded command line of the stub, not by reading the prose
- the value is never in argv: the stubs record their own full command line, and
  a sentinel value appears in none of them — flag gating is tested separately
  and does not stand in for this
- both front-ends' `list` and `send` paths run through the same stubs. This
  demonstrates equivalent behavior, not shared code — two copies would also
  pass. The single implementation is enforced by review of the module, and the
  test exists to catch behavioral drift if that ever fails.

**Page**

- binds only the resolved tailnet address; refuses to start on resolution
  failure, on multiple addresses, and on a bound port
- rejects a foreign `Host`, a foreign `Origin`, an **absent** `Origin`, and a
  wrong capability path
- the capability survives a failed send AND an ambiguous one, and dies only on
  a successful one
- a second submission while one is in flight is refused
- the page's delivery requires the second explicit action; posting the form once
  renders the confirmation view and writes nothing
- labels containing `\x1b]0;` and `<script>` are stripped on the CLI and escaped
  on the page

**Lifecycle**

- `serve` exits after a successful send, and at the timeout with no send
- with `qrencode` absent from `PATH`, `serve` still starts, prints the URL, and
  says why there is no QR code — the fallback this document insists on having
