# Fleet agent-CLI authentication

`scripts/herdr-auth.sh` reports and repairs the workers' agent-CLI login state.

    just auth-status          # read-only: what is logged in where
    just auth-login cursor    # one pass over the fleet, parallel
    just auth-login codex     # one host at a time, device codes
    just auth-test            # unit tests, fully stubbed

## What is implemented

`status` covers all three CLIs. `login` covers **cursor** (parallel) and
**codex** (serial device codes). `claude` exits 2 with
`unknown or unimplemented cli`, and will stay that way: its flow cannot be
driven per-host at all — see claude below, where the answer is distribution
rather than a login loop.

Both implemented paths were written from flows run live and watched on
2026-08-11, not from documentation.

## Three flows, observed

Probed on aorus8 (remote, no TTY) and on the Mac (local, interactive). Every
row below is something that was run, not read.

|                             | URL reaches a pipe? | Code?            | Completes via | Cross-machine |
| --------------------------- | ------------------- | ---------------- | ------------- | ------------- |
| `cursor-agent login`        | yes                 | none             | server poll   | ✅            |
| `codex login --device-auth` | yes                 | yes, **outward** | server poll   | ✅            |
| `claude setup-token`        | **no**              | none             | **loopback**  | ❌            |

The decisive property is **server-polled vs loopback callback**, not PTY. A
server-polled flow hands the browser a challenge that the vendor's own servers
correlate back to the waiting CLI, so it does not care which machine the browser
runs on. A loopback flow expects the browser to reach the CLI's own socket.

This corrects an earlier claim in this document that "codex and claude produce
nothing without a controlling terminal." That is true of `claude setup-token`
— nohup'd, and again under `script`, its log stayed empty — but false of
`codex login --device-auth`, which printed its URL and code to a plain pipe with
no TTY at all.

## cursor — per-host, parallel

Unchanged and working. `cursor-agent login` prints its URL over a plain pipe and
polls Cursor's servers (`redirectTarget=cli`). No PTY, no callback, no code. The
URL completes the login from **any** machine, including a phone. All six hosts
run in one pass. Confirmed on aorus8: no loopback listener is bound at any point.

## codex — per-host device code, serialised

`codex login --device-auth` works headless:

    https://auth.openai.com/codex/device      static, carries no per-run secret
    <one-time code>                           expires in 15 minutes

The code travels **outward** — the human reads it from the pane and types it into
the browser. Nothing is ever delivered back into the pane; the CLI polls and
finishes on its own.

Serial, one host at a time, for one reason: the human enters codes one at a time
at a single page, and a code lives 15 minutes. Minting six at once means the last
has been burning its TTL for ten-plus minutes before anyone reaches it.

Do **not** prefer plain `codex login`: it calls back to `localhost` on the
machine running codex, so a URL opened on your Mac hits the wrong localhost and
the flow dies silently. `--device-auth` is the supported way out of that, and a
test asserts the flag is the one actually sent — the stub answers both forms so
a regression names the defect instead of failing for a missing fixture.

`just auth-login codex` runs, per host and in this order: reachability check,
probe-and-skip if already authed, start the flow detached, read the code out,
open the static URL, print the code, wait for the CLI to report itself logged
in, then advance. The wait sits **inside** the loop — that is the serialisation,
and a test asserts host 2's flow does not start until host 1's has finished by
reading call sequence rather than call occurrence.

The printed code is the one credential this script deliberately puts on screen:
the flow cannot complete otherwise, so `redact()` does not govern that branch.
It reaches the terminal and nothing else — never a file, never a log, never argv.

### Why codex credentials are still not copied

`~/.codex/auth.json` (mode 0600) holds a live OAuth **session**:

    auth_mode · tokens.id_token · tokens.access_token
    tokens.refresh_token · tokens.account_id · last_refresh

The refresh token is the problem. Refresh-token rotation is common, and reuse
detection typically revokes the whole token family — so six hosts refreshing one
shared token could log all six out at once. `codex login --with-access-token`
avoids the file but takes only the access JWT with no refresh alongside it, so it
expires and needs re-injecting. Neither is worth it when `--device-auth` gives
every host its own token family for the cost of one code.

The no-copying rule below therefore holds for codex, on its own merits.

## claude — two clocks, and why the second one wins

Measured across the fleet on 2026-08-11. Four hosts had their credentials
rewritten within two seconds of each other — a pane rewire starting `claude` on
each — and every one came back with a fresh **access** token and an untouched
**refresh** token:

    aorus    written 07:21:29   access +7h   refresh +666h
    aorus5   written 07:21:30   access +7h   refresh +414h
    aorus7   written 07:21:31   access +7h   refresh +302h
    aorus8   written 07:59:15   access +7h   refresh   +8h

So the two tokens age on different clocks:

- the **access token** lives ~12h and is reissued whenever claude starts. It is
  free, automatic, and says nothing about whether a host is healthy.
- the **refresh token** runs from the original interactive login — roughly 30
  days — and is **not extended by use**. Same refresh event, four different
  windows.

The operational consequence is the important part: **a keepalive job does not
work.** The measurement above _is_ a keepalive, and it moved nothing. Every host
counts down to a full interactive login regardless of how heavily it is used,
and for claude that login cannot be driven remotely. aorus4 and aorus6 had
already fallen off that edge when this was written.

That is what turns distribution from a convenience into the only sustainable
answer.

### What an expired refresh token looks like on disk

When the refresh token lapses, the next `claude` start does not leave the file
alone and it does not delete it. It **blanks the block in place**, keeping the
metadata:

    "claudeAiOauth": {
      "accessToken": "",            <- emptied
      "refreshToken": "",           <- emptied
      "expiresAt": 0,               <- zeroed
      "scopes": [...],              <- preserved
      "subscriptionType": "max",    <- preserved
      "rateLimitTier": "...",       <- preserved
      "refreshTokenExpiresAt": 1786482121670   <- preserved, and in the PAST
    }

Preserved metadata beside an empty token reads like a half-finished write, which
is why this gets mistaken for a bad deploy. It is not. Confirm with
`refreshTokenExpiresAt`: if it is in the past, the credential expired on its own
and the timestamp names the hour. The host says so directly, too —
`claude -p` with the env var unset answers `Failed to authenticate: OAuth
session expired and could not be refreshed`.

The blanking happens on the first `claude` run **after** expiry, not at the
moment of expiry, so the file mtime can trail the real event by hours. On
aorus8: expired 2026-08-11 17:02, blanked 2026-08-12 00:48.

Note the shape differs from aorus4's, where the whole `claudeAiOauth` key is
absent and only `mcpOAuth` remains. Both mean "no usable login"; only the
blanked form carries a date you can reason about.

#### Do not blame the token push

On 2026-08-12 exactly the three hosts carrying `CLAUDE_CODE_OAUTH_TOKEN`
(aorus4, aorus6, aorus8) had broken stored credentials and the three without it
(aorus, aorus5, aorus7) were intact. A perfect correlation, and backwards: the
token had been pushed **to the hosts `auth-status` already reported as broken**,
so the two facts could not fail to coincide. aorus6 blanked on 2026-07-24,
eighteen days before the token was minted.

Setting the env var does not write to `.credentials.json`. Verified by
reproduction rather than by reading: dummy credentials in a throwaway `HOME`,
the real token exported, `claude -p` run — the dummy came back byte-identical.

Once a host is on the fleet token this blanking is expected and harmless.
`CLAUDE_CODE_OAUTH_TOKEN` is consulted **instead of** the stored block, not as a
fallback to it — verified on aorus8, which answers `ok` normally and returns
`401 OAuth access token is invalid` when a bogus value is exported. So claude
keeps working and the blanked block is dead state on disk. It is a symptom only
on a host with no env var to fall back on.

Expect it on schedule rather than as an incident: on 2026-08-12 the three hosts
that had just been given the token were still carrying live stored credentials
due to lapse 2026-08-23 (aorus7), 2026-08-28 (aorus5) and 2026-09-08 (aorus).

### The probe reports the refresh token, not the file

`probe_claude` used to be `[ -f ~/.claude/.credentials.json ]`. That file is a
**shared store** — the supabase MCP plugin writes `mcpOAuth` entries into it —
so it exists on hosts that have never logged into Claude. The old probe called
all six hosts authed while aorus4 had no `claudeAiOauth` block at all and
aorus6's had lapsed a fortnight earlier. A status table that reports the
opposite of the truth is worse than no status table.

It now sends a classifier to the host and reads back a verdict. The classifier
returns `missing` unless a `claudeAiOauth` block carries a refresh token whose
`refreshTokenExpiresAt` is still ahead, `expiring:<hours>` inside the warning
window (`HERDR_AUTH_WARN_HOURS`, default 72), and `authed:<hours>` outside it.
**Credentials never cross the ssh channel** — only the verdict does.

It is stdin-driven, so the logic is tested against real file shapes with no ssh
at all, including the two the fleet actually produced: an mcpOAuth-only file, and
a block whose refresh token is gone.

### The table reports both credentials, not just the winning one

`CLAUDE_CODE_OAUTH_TOKEN` decides who authenticates, so the probe checks for it
— but it does **not** skip reading the file. An earlier version did, returning a
bare `token`, on the reasoning that the stored credential no longer governs.
That was right about precedence and wrong about the table: once all six hosts
carried the token every row read `token`, and the status output could no longer
distinguish a host with a month of stored credential left from one that had
already blanked. A column with one value in it is not a status column.

The probe now returns `token/<verdict>` when the env var is set and `<verdict>`
when it is not, and `status` renders the countdown as a suffix:

    aorus      authed     authed     token/26d      fleet token; 26d of stored credential left
    aorus4     authed     authed     token/--       fleet token; nothing underneath
    aorus7     authed     authed     token/11d
    (a host not on the fleet token)
    aorus9     authed     authed     authed/26d     its own login, 26d left
    aorus9     authed     authed     exp/41h        its own login, inside the warning window

Days above 48h, hours below — `0d` on the last day before a credential dies is
exactly when the number has to be readable.

Two properties the tests pin, because both are easy to get backwards:

- `token/--` still tallies as **authed**. The host works; only the credential
  underneath is gone. Counting it missing would report a healthy fleet as broken.
- a `token/` host is **never** booked into the `expiring within Nh` line. The
  fleet token authenticates it, so a lapsing stored credential asks nothing of
  anyone — and the login it would send you to perform cannot be driven remotely
  anyway. Only a host on its own credential earns a place in that list.

## claude — mint once, distribute

The only flow where per-host login is not merely inconvenient but **impossible**:

- the callback binds a **random** loopback port on the host running it
  (observed: 62819 locally, 34137 and 40357 on aorus8), so a browser here cannot
  reach a listener there
- the URL never reaches a pipe, so it cannot be scraped and the port cannot be
  learned to tunnel it
- authorising displays no code — the browser talks straight to the CLI and the
  page says "you can now close this window"

`claude setup-token` is a **minting** command, not a per-host login: it prints a
long-lived token (one year) intended to be handed to headless consumers. Run it
once where loopback works, and every fleet host consumes the result:

    CLAUDE_CODE_OAUTH_TOKEN
    CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR

The second form takes the token on an inherited file descriptor, so it never
appears in `/proc/<pid>/environ`, a shell profile, or `ps`. Prefer it.

### Amendment to "credential files are not copied"

That rule was written assuming per-host login was always available. For claude it
is not, so the choice is not "copy to save a few clicks" — it is copy or have no
claude auth on the fleet at all. Two things narrow the exception:

- what is distributed is a **purpose-minted token**, not a session file. It has no
  refresh token to race and no rotation to trip.
- it applies to claude only. cursor and codex both log in per-host, and their
  credential files stay put.

The blast radius is real and accepted: one token on six hosts means revoking it
drops the whole fleet, and all six share one account's rate and concurrency
budget. Per-host claude logins would have shared that budget anyway.

**Unverified precondition.** Nothing in the authorize URL identifies the machine
— `client_id`, `scope=user:inference`, PKCE challenge, loopback `redirect_uri`,
`state`, and nothing else — so the token should be portable. Server-side device
binding cannot be ruled out from the client. Test on one host before fanning out:

    read -rs TOKEN
    ssh aorus8 'CLAUDE_CODE_OAUTH_TOKEN=$(cat) claude -p "reply with just: ok"' <<< "$TOKEN"
    unset TOKEN

The token crosses on stdin and never enters argv on either machine.

### How the token lands: `ansible-ai/deploy-claude-token.yml`

Distribution is **provisioning, not a login flow**, so it lives with the other
fleet playbooks and is imported by both `provision-ai.yml` (a new host arrives
authenticated) and `update.yml` (every `./update.sh --all` re-asserts it). That
second one is what retires the countdown instead of monitoring it.

The token is read on the control node from `~/.claude/.env` by name — the
convention this repo already uses, and the reason ansible-vault is wrong here:
**the repo is public**, and an encrypted live credential in a public repo buys a
passphrase to manage and little else. An exported `CLAUDE_CODE_OAUTH_TOKEN` wins
over the file, so a one-off run can override without editing anything. Every
task that touches the value sets `no_log`; this repo had no prior task that
_carried_ a secret (9router **generates** its own on the host), so that keyword
is the whole difference between distribution and publication.

Two mechanisms were rejected on evidence rather than taste.
`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` keeps the value out of the
environment, but needs a wrapper around every `claude` invocation — and herdr
wires remote panes as `ssh -t HOST 'bash -lc "claude; exec $SHELL -l"'`, so
adopting it means rewiring all six spaces. `apiKeyHelper` is an **API key** hook;
whether it accepts an OAuth token is unverified, and this was not the place to
find out.

So: an env var, from a **0600 file** at `~/.config/claude-fleet/env`, sourced by
one line in `~/.bashrc`. The token is not written into `.bashrc` itself because
`.bashrc` is mode 644 on these hosts — a one-year credential there is readable by
every user on the box.

### The placement inside `.bashrc` is load-bearing

herdr panes run `bash -lc`, a **login but non-interactive** shell. It reaches
`~/.bashrc` through `~/.profile`, and stock Ubuntu `.bashrc` returns immediately
for non-interactive shells:

    case $- in *i*) ;; *) return;; esac

Anything appended below that is never seen by a pane — while remaining perfectly
visible to an interactive `ssh`, so it looks installed and does nothing.
Demonstrated on aorus8 with `TEAM_DIR`, which is defined below the guard:

    bash -lc  →  TEAM_DIR=[]
    bash -ic  →  TEAM_DIR=[bulls]

The playbook therefore uses `insertbefore` to place its stanza **above** the
guard, where nvm already sits for exactly this reason, and then verifies by
running `bash -lc` on the host and comparing a hash prefix of the resolved value
against the control node's — never printing either. A host where the stanza
landed in the wrong place fails the run instead of passing quietly.

macOS needs `.zshenv`, not `.zshrc`, for the same reason: `.zshrc` is sourced
only for interactive zsh. It does not arise today because the playbook targets
`aorus_ai` — the control node is where the token is minted and where claude logs
in through its own working loopback flow, so pushing a copy there would shadow a
live credential with itself.

## What the paste-login design got wrong

`references/herdr-paste-login.md` (deleted) specified a serial loop that carried a
value **into** each pane, with a journal, an exclusive lock, an `ambiguous`
outcome, and a `--retry` flag. Its premise — "these flows hand a value to a human
who has to carry it back" — is false for all three flows. claude hands over
nothing; codex and cursor send their values outward. Nothing needs to be typed
into a pane, so none of that machinery has a job: no journal, no lock, no
`ambiguous`, no `--retry`, no scraping URLs out of scrollback.

What survives is much smaller: a serial `--device-auth` loop for codex, and a
distribution step for claude.

## Where `herdr-paste.py` fits now

Not in these flows. It delivers a credential **into** a waiting pane, and none of
the three logins needs that. It remains the right tool for stdin-reading
credential commands (`codex login --with-access-token`, `--with-api-key`) and for
any prompt where a human must hand a value to a terminal they are not sitting at.
See `herdr-paste.md`.

## Login URLs are credentials — with one correction

The rule stands, but the risk differs per flow, and the earlier blanket claim
overstated one case:

- **cursor**: the URL carries `challenge` + `uuid`, the pairing secret. Anyone who
  opens it can complete the login. Genuinely a bearer credential.
- **codex**: the URL is static and public; the **code** is the secret.
- **claude**: `code_challenge` is a PKCE _hash_. The verifier never leaves the
  originating process, so the URL alone cannot mint a token — the worst an
  attacker does is burn the single-use authorization. A denial, not a theft.

The script holds URLs in a shell variable and passes them straight to `open`,
never to disk, never logged; output says `opened login URL for host aorus`, never
the URL. `redact()` is the single choke point and every printed line goes through
it. It is an allowlist, failing closed on unknown parameters, because a denylist
silently leaks the one key nobody thought of. Two residual risks are documented in
the code: a secret in a URL _path_ (`/device/ABC-123`) is not `key=value` and
cannot be masked by this logic, and control bytes are stripped rather than treated
as separators. The primary control is that the script never prints a URL at all —
redaction is defence in depth, not the fence.

## Why `cancel_login`'s kill pattern looks strange

It reads `pkill -f "cursor-agent[ ]login"`, and the bracket is load-bearing.
`pkill -f` matches full command lines, and the remote shell's own argv contains
whatever pattern it was handed — so the obvious literal makes cancel signal
itself. Verified on aorus8 before the fix:

    $ pgrep -af "cursor-agent login"
    931550 bash -lc pgrep -af "cursor-agent login"; ...

The consequence was worse than a failed kill: the `rm -f $CURSOR_LOG` that
followed might never run, leaving `/tmp/herdr-auth-cursor-login.log` — which
holds a live login URL — on the host at exactly the moment the operator asked
to cancel. The cleanup now runs **first**, so it cannot be made contingent on
the kill succeeding.

`[ ]` encodes a space the argv text does not literally contain: the regex needs
a space between the words, and the command line carrying it has a bracket there.

Two tests hold this in place, and they are only meaningful as a pair — one
asserts the pattern does not match the command carrying it, the other that it
still matches `cursor-agent login`. Without the second, a pattern matching
nothing would pass.

## `python3 -c "$(cat <<'PY' … PY)"` brace-expands your program

The extractors embed a Python program in shell. The obvious form leaks **brace
expansion** onto the substituted text, so a regex quantifier is silently
rewritten:

    codes = re.findall(r"\b[A-Z0-9]{4,8}-[A-Z0-9]{4,8}\b", data)
    # what Python actually compiled:
    #        r"\b[A-Z0-9]4-[A-Z0-9]4\b"

`{4,8}` expands to the cross product, Python takes the first variant as the
program and the rest as `sys.argv`, and the pattern matches nothing. No error,
no stderr, just an empty result — which surfaced as "no device code, flow did
not start" and looked like a broken stub.

`extract_url` had carried this form since it was written and was never bitten,
because its regex contains no braces. Both extractors now build the program into
a variable first (`prog=$(cat <<'PY' … PY)`, then `python3 -c "$prog"`);
assignments undergo no brace expansion, so any program text is safe.

## Why this cannot live in herdr's agent panel

The obvious home for "this host's auth expires in 8h" is the agent panel, and it
is not available. Agent detection inspects the pane's **local** foreground
process; for a remote pane that process is `ssh`, which is why those panes
already report `agent_status: unknown`. The panel never sees the far end, and
`herdr agent` exposes no field or hook to add one.

The surface herdr does offer is `herdr notification show`. So the shape that
works is a scheduled `auth-status` that fires a notification when a host enters
the warning window — not a panel integration.

## Naming hazard

`aorus` is a host _and_ the prefix of the other five. Never glob `aorus*` to mean
"the workers" — it matches all six. Say `host aorus` when you mean the box.

## Testing

    just auth-test

Every external command is stubbed on `PATH` (`tests/auth-stubs/`), so the suite
never touches the fleet and never starts a real flow. Fixtures use a synthetic
challenge; a real one must never enter this repo.

Stubs must model the real thing's **process lifetime**, not just its output. The
first live `login --cli cursor` deadlocked for 5m32s because the stub modelled a
command that returns and `cursor-agent login` does not; the run never reached
hosts 2-6. A stub that exits where the real command blocks proves nothing.
