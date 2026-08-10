# Fleet Auth Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `scripts/herdr-auth.sh` so eleven outstanding agent-CLI logins across six worker hosts cost roughly three rounds of user attention instead of eleven interactive ssh sessions.

**Architecture:** One bash script with two verbs. `status` probes every host read-only and prints a table. `login` drives the OAuth flows in two classes: `cursor-agent` needs no PTY, so it runs over plain ssh in parallel across all six hosts; `codex` and `claude` need a controlling terminal, so they are driven inside existing herdr panes via `pane send-keys` / `pane wait-output`. Every external command (`ssh`, `herdr`, `open`) is invoked through a single indirection point so the whole script is testable against stub executables on `PATH`, with no live fleet.

**Tech Stack:** bash (macOS `/bin/bash` 3.2-compatible — no `mapfile`, no associative arrays), `ssh`, the `herdr` CLI, macOS `open`. Tests are plain bash following `hooks/cache-guard.test.sh`; stubs follow `tests/preflight/stubs/`.

## Global Constraints

- **Auth URLs are bearer credentials.** Never write one to disk, never log one, never commit one. Held in shell variables only and passed directly to `open`. Log lines say `opened login URL for <host>`, never the URL.
- **Test fixtures use synthetic challenges only.** No real `challenge=` or `uuid=` value may enter this repo.
- **Never copy credential files between hosts.** Tokens may be device-bound; duplicating live secrets to save clicks is out of scope by decision.
- **`aorus` is a host, not a prefix.** Never glob `aorus*` to mean "the workers" — it matches all six. Address hosts explicitly; log `host aorus`, never a bare `aorus`.
- **bash 3.2 compatible.** The node is macOS; `/bin/bash` is 3.2. No `mapfile`/`readarray`, no `declare -A`.
- **Existing herdr guards hold.** Never drive the pane running the script (`$HERDR_PANE_ID`); never send keys to a pane herdr reports as having a live agent unless `FORCE=1`.
- **Fleet hosts:** `aorus aorus4 aorus5 aorus6 aorus7 aorus8`, overridable via `HERDR_AUTH_HOSTS`.

## File Structure

| Path | Responsibility |
| --- | --- |
| `scripts/herdr-auth.sh` | The whole CLI: arg parsing, probes, both login classes |
| `scripts/herdr-auth.test.sh` | Unit tests; dotted stem so hook-linking never picks it up |
| `tests/auth-stubs/ssh` | Stub `ssh`, serves fixtures from `$HERDR_AUTH_FIXTURE` |
| `tests/auth-stubs/herdr` | Stub `herdr`, serves pane output fixtures |
| `tests/auth-stubs/open` | Stub `open`, records the URLs it was handed |
| `justfile` | `auth-status` and `auth-test` recipes |
| `references/herdr-auth.md` | Why the two classes exist; the constraints behind them |

---

### Task 1: Script scaffold, host config, and the `status` verb

**Files:**
- Create: `scripts/herdr-auth.sh`
- Create: `scripts/herdr-auth.test.sh`
- Create: `tests/auth-stubs/ssh`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `remote <host> <command>` — runs a command on a host, echoes stdout. `probe_cursor <host>`, `probe_codex <host>`, `probe_claude <host>` — each echoes exactly `authed` or `missing`. `HOSTS` array. `main` dispatching on `$1`.

- [ ] **Step 1: Write the failing test**

Create `scripts/herdr-auth.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for herdr-auth.sh. Dotted stem on purpose: link_claude_hooks()
# excludes *.*.* files, so this never installs as a live hook.
#
# Every external command (ssh, herdr, open) is served by a stub on PATH, so
# nothing here touches the real fleet and no auth flow is ever started.

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
A="$HERE/herdr-auth.sh"
pass=0 fail=0

TMP=$(mktemp -d -t herdrauth-test) || exit 1
trap 'rm -rf "$TMP"' EXIT

export PATH="$ROOT/tests/auth-stubs:$PATH"
export HERDR_AUTH_FIXTURE="$TMP/fixture"
export HERDR_AUTH_OPENED="$TMP/opened"
mkdir -p "$HERDR_AUTH_FIXTURE"

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail + 1)); }

# Each fixture file is named <host>.<probe> and holds that probe's stdout.
fixture() { printf '%s\n' "$2" > "$HERDR_AUTH_FIXTURE/$1"; }

# --- probes -----------------------------------------------------------------

fixture aorus.cursor 'Not logged in'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe cursor aorus)
[ "$got" = missing ] && ok "cursor: 'Not logged in' -> missing" \
                     || ko "cursor: 'Not logged in' -> missing" "got '$got'"

fixture aorus.cursor 'Logged in as joel@example.com'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe cursor aorus)
[ "$got" = authed ] && ok "cursor: logged-in line -> authed" \
                    || ko "cursor: logged-in line -> authed" "got '$got'"

fixture aorus.codex 'Not logged in'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe codex aorus)
[ "$got" = missing ] && ok "codex: 'Not logged in' -> missing" \
                     || ko "codex: 'Not logged in' -> missing" "got '$got'"

fixture aorus.codex 'Logged in using ChatGPT'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe codex aorus)
[ "$got" = authed ] && ok "codex: 'Logged in using ChatGPT' -> authed" \
                    || ko "codex: 'Logged in using ChatGPT' -> authed" "got '$got'"

fixture aorus.claude 'missing'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe claude aorus)
[ "$got" = missing ] && ok "claude: no credentials file -> missing" \
                     || ko "claude: no credentials file -> missing" "got '$got'"

fixture aorus.claude 'authed'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _probe claude aorus)
[ "$got" = authed ] && ok "claude: credentials file -> authed" \
                    || ko "claude: credentials file -> authed" "got '$got'"

# --- status table -----------------------------------------------------------

fixture aorus.cursor 'Not logged in'
fixture aorus.codex  'Not logged in'
fixture aorus.claude 'missing'
fixture aorus4.cursor 'Not logged in'
fixture aorus4.codex  'Not logged in'
fixture aorus4.claude 'authed'

out=$(HERDR_AUTH_HOSTS="aorus aorus4" bash "$A" status)
printf '%s' "$out" | grep -q 'aorus4' \
  && ok "status: lists every host" \
  || ko "status: lists every host" "missing aorus4"
printf '%s' "$out" | grep -qE 'aorus4 +[^ ]+ +[^ ]+ +authed|aorus4.*authed' \
  && ok "status: reports aorus4 claude as authed" \
  || ko "status: reports aorus4 claude as authed"
# aorus contributes 0 authed / 3 missing; aorus4 contributes 1 authed (claude)
# / 2 missing. Six probes across two hosts: 1 authed, 5 missing.
printf '%s' "$out" | grep -q '1 authed, 5 missing' \
  && ok "status: prints a totals line" \
  || ko "status: prints a totals line" "$(printf '%s' "$out" | tail -1)"

printf '\n  %d passed, %d failed\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Create the ssh stub**

Create `tests/auth-stubs/ssh` and make it executable:

```bash
#!/usr/bin/env bash
# Stub for `ssh`. Serves recorded probe output from $HERDR_AUTH_FIXTURE.
# Invoked as: ssh [opts] <host> <command...>
# Picks the fixture by host plus which CLI the command mentions.
#
# The host scan must skip an option's VALUE as well as the option: SSH_OPTS
# word-splits to `-o BatchMode=yes -o ConnectTimeout=8`, and a naive scan takes
# `BatchMode=yes` for the host.
host=""
skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -o) skip=1 ;;
    -*) ;;
    *) host="$a"; break ;;
  esac
done
cmd="$*"

case "$cmd" in
  *cursor-agent*) probe=cursor ;;
  *"codex login status"*) probe=codex ;;
  *credentials.json*) probe=claude ;;
  *) exit 0 ;;
esac

f="$HERDR_AUTH_FIXTURE/$host.$probe"
[ -f "$f" ] || { echo "no fixture: $f" >&2; exit 1; }

# Model the real CLIs' stream behaviour. `codex login status` writes to STDERR
# (verified: 0 bytes on stdout), so a caller that does not merge the streams
# inside the remote command sees nothing. Serving the codex fixture on stderr
# unless the command contains 2>&1 is what makes the probe tests a real
# regression guard rather than a tautology.
if [ "$probe" = codex ] && [ "${cmd#*2>&1}" = "$cmd" ]; then
  cat "$f" >&2
else
  cat "$f"
fi
exit 0
```

The two existing codex probe assertions become the regression guard: with the
stub modelling stderr, `probe_codex` only returns `authed` if the script merges
the streams. No extra test is needed.

Run: `chmod +x tests/auth-stubs/ssh`

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash scripts/herdr-auth.test.sh`
Expected: FAIL — `scripts/herdr-auth.sh: No such file or directory`

- [ ] **Step 4: Write the minimal implementation**

Create `scripts/herdr-auth.sh`:

```bash
#!/usr/bin/env bash
# herdr-auth.sh — bring the fleet's agent CLIs to a logged-in state.
#
# Two verbs:
#   status   read-only probe of every host; safe to run any time
#   login    drive the OAuth flows (see Task 3 and Task 5)
#
# The CLIs split into two classes. cursor-agent prints its login URL over a
# plain pipe and polls Cursor's servers, so it needs no PTY and the URL can be
# opened on any machine. codex and claude produce nothing without a controlling
# terminal, so they are driven inside herdr panes, which are PTYs.
#
# SECURITY: login URLs carry a PKCE challenge and are bearer credentials for
# that login attempt. They are held in shell variables, passed straight to
# `open`, and never written to disk or logged. See references/herdr-auth.md.
#
# bash 3.2 compatible (the node is macOS): no mapfile, no associative arrays.

set -uo pipefail

HOSTS_DEFAULT="aorus aorus4 aorus5 aorus6 aorus7 aorus8"
HOSTS_STR="${HERDR_AUTH_HOSTS:-$HOSTS_DEFAULT}"

SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=8"

# Single indirection point for every remote call, so tests can stub `ssh`.
remote() {
  local host="$1"; shift
  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$host" "$@" 2>/dev/null
}

probe_cursor() {
  local out; out="$(remote "$1" 'bash -lc "cursor-agent status"')"
  case "$out" in
    *"Not logged in"*|"") echo missing ;;
    *) echo authed ;;
  esac
}

# codex writes its status line to STDERR, not stdout — verified on aorus7:
# stdout is 0 bytes, and `2>&1` is what surfaces "Logged in using ChatGPT".
# The 2>&1 must live INSIDE the remote command so the remote's stderr merges
# into the remote's stdout; remote()'s own 2>/dev/null still discards local ssh
# noise. Without this the probe reports every host as missing, and cmd_login
# then drives a fresh login on hosts that are already authenticated.
probe_codex() {
  local out; out="$(remote "$1" 'bash -lc "codex login status 2>&1"')"
  case "$out" in
    *"Logged in"*) echo authed ;;
    *) echo missing ;;
  esac
}

probe_claude() {
  local out
  out="$(remote "$1" '[ -f ~/.claude/.credentials.json ] && echo authed || echo missing')"
  case "$out" in
    *authed*) echo authed ;;
    *) echo missing ;;
  esac
}

probe() {  # <cli> <host>
  case "$1" in
    cursor) probe_cursor "$2" ;;
    codex)  probe_codex  "$2" ;;
    claude) probe_claude "$2" ;;
    *) echo "unknown cli: $1" >&2; return 2 ;;
  esac
}

cmd_status() {
  local host cli state a=0 m=0
  printf '%-10s %-10s %-10s %-10s\n' HOST CURSOR CODEX CLAUDE
  for host in $HOSTS_STR; do
    printf '%-10s' "$host"
    for cli in cursor codex claude; do
      state="$(probe "$cli" "$host")"
      printf ' %-10s' "$state"
      if [ "$state" = authed ]; then a=$((a + 1)); else m=$((m + 1)); fi
    done
    printf '\n'
  done
  printf '\n%d authed, %d missing\n' "$a" "$m"
}

main() {
  case "${1:-status}" in
    status) cmd_status ;;
    _probe) shift; probe "$@" ;;   # test seam
    *) echo "usage: herdr-auth.sh status" >&2; exit 2 ;;
  esac
}

main "$@"
```

Run: `chmod +x scripts/herdr-auth.sh`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash scripts/herdr-auth.test.sh`
Expected: `9 passed, 0 failed`

- [ ] **Step 6: Verify against the real fleet**

Run: `bash scripts/herdr-auth.sh status`
Expected: the six real hosts, matching the spec's table — cursor missing on all six, codex missing on aorus/aorus4/aorus5/aorus6, claude missing on host aorus only. Totals line reads `7 authed, 11 missing`.

- [ ] **Step 7: Commit**

```bash
git add scripts/herdr-auth.sh scripts/herdr-auth.test.sh tests/auth-stubs/ssh
git commit -m "herdr/auth: probe fleet login state read-only

status walks every host and reports each CLI as authed or missing. Every
remote call goes through one remote() indirection so the tests drive stub
executables on PATH and never touch the fleet."
```

---

### Task 2: URL extraction and redaction

**Files:**
- Modify: `scripts/herdr-auth.sh` (add two functions above `cmd_status`)
- Modify: `scripts/herdr-auth.test.sh` (add a test block before the totals line)

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `extract_url` — reads text on stdin, echoes the last `https://` URL, empty if none. `redact` — reads text on stdin, echoes it with the values of `challenge`, `code`, `token`, `uuid`, and `access_token` query params replaced by `REDACTED`.

This is the security boundary for the whole feature: everything downstream
prints through `redact`. Fixtures use a synthetic challenge only.

- [ ] **Step 1: Write the failing test**

Insert into `scripts/herdr-auth.test.sh`, immediately before the final `printf '\n  %d passed'` line:

```bash
# --- url extraction and redaction -------------------------------------------
# SYNTHETIC challenge/uuid only. A real one must never enter this repo.
SAMPLE='Starting login process...
Waiting for browser authentication...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_CHALLENGE_VALUE&uuid=00000000-0000-0000-0000-000000000000&mode=login&redirectTarget=cli'

got=$(printf '%s\n' "$SAMPLE" | bash "$A" _extract_url)
[ "$got" = 'https://cursor.com/loginDeepControl?challenge=SYNTHETIC_CHALLENGE_VALUE&uuid=00000000-0000-0000-0000-000000000000&mode=login&redirectTarget=cli' ] \
  && ok "extract_url: pulls the URL out of surrounding noise" \
  || ko "extract_url: pulls the URL out of surrounding noise" "got '$got'"

got=$(printf 'no link here at all\n' | bash "$A" _extract_url)
[ -z "$got" ] && ok "extract_url: empty when no URL present" \
              || ko "extract_url: empty when no URL present" "got '$got'"

got=$(printf '%s\n' "$SAMPLE" | bash "$A" _redact)
printf '%s' "$got" | grep -q 'SYNTHETIC_CHALLENGE_VALUE' \
  && ko "redact: strips the challenge value" "challenge survived" \
  || ok "redact: strips the challenge value"
printf '%s' "$got" | grep -q '00000000-0000' \
  && ko "redact: strips the uuid value" "uuid survived" \
  || ok "redact: strips the uuid value"
printf '%s' "$got" | grep -q 'challenge=REDACTED' \
  && ok "redact: keeps the parameter name" \
  || ko "redact: keeps the parameter name" "$got"
printf '%s' "$got" | grep -q 'redirectTarget=cli' \
  && ok "redact: leaves non-secret params alone" \
  || ko "redact: leaves non-secret params alone"

got=$(printf 'token=abc123&access_token=def456&code=ghi789\n' | bash "$A" _redact)
printf '%s' "$got" | grep -qE 'abc123|def456|ghi789' \
  && ko "redact: covers token, access_token, code" "a value survived: $got" \
  || ok "redact: covers token, access_token, code"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/herdr-auth.test.sh`
Expected: FAIL — `usage: herdr-auth.sh status` for each new case, because `_extract_url` and `_redact` are not dispatched yet.

- [ ] **Step 3: Write the implementation**

In `scripts/herdr-auth.sh`, insert these two functions immediately above `cmd_status`:

```bash
# Pull the login URL out of captured CLI output. Last match wins: a retry
# prints a fresh URL below the stale one.
extract_url() {
  grep -oE 'https://[^[:space:]]+' | tail -1
}

# Strip credential-bearing query parameter values. Everything this script
# prints goes through here — the URL itself is a bearer credential for the
# login attempt, so only the parameter names may appear in output.
redact() {
  sed -E 's/(challenge|access_token|token|code|uuid)=[^&[:space:]]*/\1=REDACTED/g'
}
```

Then extend the `main` dispatch — replace the `_probe` line with:

```bash
    _probe) shift; probe "$@" ;;          # test seam
    _extract_url) extract_url ;;          # test seam
    _redact) redact ;;                    # test seam
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/herdr-auth.test.sh`
Expected: `16 passed, 0 failed`

- [ ] **Step 5: Verify no real secret can reach the repo**

Run: `grep -rnE 'challenge=[A-Za-z0-9_-]{16,}' scripts/ tests/ docs/`
Expected: no output. The only `challenge=` in the tree is `SYNTHETIC_CHALLENGE_VALUE`.

- [ ] **Step 6: Commit**

```bash
git add scripts/herdr-auth.sh scripts/herdr-auth.test.sh
git commit -m "herdr/auth: extract login URLs and redact their secrets

A login URL carries a PKCE challenge and is a bearer credential for that
attempt, so everything the script prints goes through redact(): parameter
names survive, values do not. Test fixtures use a synthetic challenge; a
real one must never enter the repo."
```

---

### Task 3: `login --cli cursor` — the no-PTY batch

**Files:**
- Modify: `scripts/herdr-auth.sh`
- Modify: `scripts/herdr-auth.test.sh`
- Create: `tests/auth-stubs/open`

**Interfaces:**
- Consumes: `remote`, `probe_cursor` (Task 1); `extract_url`, `redact` (Task 2)
- Produces: `login_cursor <host>` — starts the flow, echoes the URL on stdout, empty on failure. `open_url <url>` — hands a URL to the browser via `$HERDR_AUTH_OPEN` (default `open`). `cmd_login <cli>` dispatching per CLI.

**Deliberate divergence from the spec.** The spec says "parallel within a
batch"; this loops over hosts sequentially. The benefit the user actually chose
was *one browser session for all six*, and a sequential loop delivers that — the
six URLs open within a few seconds of each other, before any waiting begins, and
each remote polls independently once started. True backgrounding costs job
control and output interleaving in bash 3.2 for a saving of a few seconds. If
the sequential pass ever proves slow, background `login_cursor` per host and
collect URLs into a temp dir; do not attempt it before that.

- [ ] **Step 1: Create the open stub**

Create `tests/auth-stubs/open` and make it executable:

```bash
#!/usr/bin/env bash
# Stub for macOS `open`. Records each URL it is handed, one per line, so tests
# can assert which URLs were opened without launching a browser.
printf '%s\n' "$1" >> "$HERDR_AUTH_OPENED"
exit 0
```

Run: `chmod +x tests/auth-stubs/open`

- [ ] **Step 2: Write the failing test**

Insert into `scripts/herdr-auth.test.sh`, before the final totals `printf`:

```bash
# --- cursor login batch -----------------------------------------------------
: > "$HERDR_AUTH_OPENED"
fixture aorus.cursorlogin 'Starting login process...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_A&uuid=00000000-0000-0000-0000-00000000000a&mode=login&redirectTarget=cli'
fixture aorus4.cursorlogin 'Starting login process...
Open a browser and navigate to this link: https://cursor.com/loginDeepControl?challenge=SYNTHETIC_B&uuid=00000000-0000-0000-0000-00000000000b&mode=login&redirectTarget=cli'

out=$(HERDR_AUTH_HOSTS="aorus aorus4" bash "$A" login --cli cursor --no-wait)

[ "$(grep -c . "$HERDR_AUTH_OPENED")" = 2 ] \
  && ok "cursor login: opens one URL per host" \
  || ko "cursor login: opens one URL per host" "opened $(grep -c . "$HERDR_AUTH_OPENED")"
grep -q 'SYNTHETIC_A' "$HERDR_AUTH_OPENED" && grep -q 'SYNTHETIC_B' "$HERDR_AUTH_OPENED" \
  && ok "cursor login: opens the real URL for each host" \
  || ko "cursor login: opens the real URL for each host"
printf '%s' "$out" | grep -qE 'SYNTHETIC_A|SYNTHETIC_B' \
  && ko "cursor login: never prints a challenge" "leaked: $out" \
  || ok "cursor login: never prints a challenge"
printf '%s' "$out" | grep -q 'opened login URL for host aorus4' \
  && ok "cursor login: logs per host without the URL" \
  || ko "cursor login: logs per host without the URL" "$out"

fixture aorus.cursorlogin 'some error, no link'
: > "$HERDR_AUTH_OPENED"
out=$(HERDR_AUTH_HOSTS="aorus" bash "$A" login --cli cursor --no-wait)
[ "$(grep -c . "$HERDR_AUTH_OPENED")" = 0 ] \
  && ok "cursor login: opens nothing when no URL is printed" \
  || ko "cursor login: opens nothing when no URL is printed"
printf '%s' "$out" | grep -q 'no login URL' \
  && ok "cursor login: reports a missing URL loudly" \
  || ko "cursor login: reports a missing URL loudly" "$out"
```

Extend `tests/auth-stubs/ssh` — add this case **above** the existing `*cursor-agent*` case, since `cursor-agent login` also matches that pattern:

```bash
  *"cursor-agent login"*) probe=cursorlogin ;;
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash scripts/herdr-auth.test.sh`
Expected: FAIL — `usage: herdr-auth.sh status`, because `login` is not dispatched yet.

- [ ] **Step 4: Write the implementation**

In `scripts/herdr-auth.sh`, add above `main`:

```bash
open_url() {
  "${HERDR_AUTH_OPEN:-open}" "$1" >/dev/null 2>&1
}

# cursor prints its URL over a plain pipe and then polls Cursor's servers, so
# no PTY is needed and the URL completes the login opened from any machine.
# NO_OPEN_BROWSER stops the remote from trying to launch a browser it has not
# got. The remote process is left running: it polls until the human half of
# the flow completes.
login_cursor() {
  local host="$1" out url
  out="$(remote "$host" 'bash -lc "NO_OPEN_BROWSER=1 cursor-agent login"')"
  url="$(printf '%s\n' "$out" | extract_url)"
  printf '%s' "$url"
}

cmd_login() {
  local cli="$1" host url opened=0
  case "$cli" in
    cursor)
      for host in $HOSTS_STR; do
        url="$(login_cursor "$host")"
        if [ -z "$url" ]; then
          echo "  host $host: no login URL — flow did not start" >&2
          continue
        fi
        open_url "$url"
        opened=$((opened + 1))
        echo "  opened login URL for host $host"
      done
      echo "$opened URL(s) opened. Complete them in the browser; each remote polls until done."
      ;;
    *)
      echo "unknown or unimplemented cli: $cli" >&2; exit 2 ;;
  esac
}
```

Replace the `main` function with:

```bash
main() {
  local verb="${1:-status}"; shift 2>/dev/null || true
  case "$verb" in
    status) cmd_status ;;
    login)
      local cli="" 
      while [ $# -gt 0 ]; do
        case "$1" in
          --cli)  cli="$2"; shift 2 ;;
          --host) HOSTS_STR="$2"; shift 2 ;;
          --no-wait) shift ;;   # consumed in Task 4
          *) echo "unknown flag: $1" >&2; exit 2 ;;
        esac
      done
      [ -n "$cli" ] || { echo "login needs --cli cursor|codex|claude" >&2; exit 2; }
      cmd_login "$cli"
      ;;
    _probe) probe "$@" ;;
    _extract_url) extract_url ;;
    _redact) redact ;;
    *) echo "usage: herdr-auth.sh status | login --cli <cli> [--host H]" >&2; exit 2 ;;
  esac
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash scripts/herdr-auth.test.sh`
Expected: `22 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add scripts/herdr-auth.sh scripts/herdr-auth.test.sh tests/auth-stubs/ssh tests/auth-stubs/open
git commit -m "herdr/auth: batch the cursor logins over plain ssh

cursor needs no PTY: it prints its URL over a pipe and polls Cursor's
servers, so the URL completes the login opened from any machine. Six hosts
in one pass, six URLs opened together, one browser session. The URL is
passed straight to open and never printed."
```

---

### Task 4: Completion polling

**Files:**
- Modify: `scripts/herdr-auth.sh`
- Modify: `scripts/herdr-auth.test.sh`

**Interfaces:**
- Consumes: `probe` (Task 1), `cmd_login` (Task 3)
- Produces: `wait_for_login <cli> <host>` — polls until the probe reports `authed`, echoing `ok` on success and `timeout` on expiry. Honours `HERDR_AUTH_POLL_INTERVAL` (default 5) and `HERDR_AUTH_POLL_CEILING` (default 300).

One stalled login must never block the other ten: `wait_for_login` always
returns, and `cmd_login` continues to the next host regardless.

- [ ] **Step 1: Write the failing test**

Insert before the final totals `printf`:

```bash
# --- completion polling -----------------------------------------------------
export HERDR_AUTH_POLL_INTERVAL=0
export HERDR_AUTH_POLL_CEILING=1

fixture aorus.cursor 'Logged in as joel@example.com'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _wait cursor aorus)
[ "$got" = ok ] && ok "wait: returns ok once the probe reports authed" \
                || ko "wait: returns ok once the probe reports authed" "got '$got'"

fixture aorus.cursor 'Not logged in'
got=$(HERDR_AUTH_HOSTS="aorus" bash "$A" _wait cursor aorus)
[ "$got" = timeout ] && ok "wait: returns timeout at the ceiling" \
                     || ko "wait: returns timeout at the ceiling" "got '$got'"

unset HERDR_AUTH_POLL_INTERVAL HERDR_AUTH_POLL_CEILING
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/herdr-auth.test.sh`
Expected: FAIL — `usage:` line, because `_wait` is not dispatched.

- [ ] **Step 3: Write the implementation**

Add above `cmd_login`:

```bash
# Poll until the CLI reports itself logged in, or give up at the ceiling.
# Always returns — a stalled login must not block the remaining hosts.
wait_for_login() {
  local cli="$1" host="$2"
  local interval="${HERDR_AUTH_POLL_INTERVAL:-5}"
  local ceiling="${HERDR_AUTH_POLL_CEILING:-300}"
  local waited=0
  while [ "$waited" -lt "$ceiling" ]; do
    if [ "$(probe "$cli" "$host")" = authed ]; then echo ok; return 0; fi
    sleep "$interval"
    waited=$((waited + interval))
    [ "$interval" -eq 0 ] && break   # test mode: one pass, no spin
  done
  [ "$(probe "$cli" "$host")" = authed ] && { echo ok; return 0; }
  echo timeout
  return 1
}
```

Add the seam to the `main` dispatch, immediately after the `_probe` line:

```bash
    _probe) probe "$@" ;;
    _wait) wait_for_login "$@" ;;
```

In `cmd_login`, replace the closing `echo "$opened URL(s) opened…"` line with:

```bash
      echo "$opened URL(s) opened. Complete them in the browser."
      if [ "${HERDR_AUTH_NO_WAIT:-0}" = 0 ]; then
        for host in $HOSTS_STR; do
          case "$(wait_for_login cursor "$host")" in
            ok) echo "  host $host: logged in" ;;
            *)  echo "  host $host: still not logged in after ${HERDR_AUTH_POLL_CEILING:-300}s" >&2 ;;
          esac
        done
      fi
```

And in `main`, make `--no-wait` set the flag: replace `--no-wait) shift ;;` with

```bash
          --no-wait) HERDR_AUTH_NO_WAIT=1; shift ;;
```

adding `HERDR_AUTH_NO_WAIT="${HERDR_AUTH_NO_WAIT:-0}"` near the top of the script beside `SSH_OPTS`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/herdr-auth.test.sh`
Expected: `25 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/herdr-auth.sh scripts/herdr-auth.test.sh
git commit -m "herdr/auth: poll each host until its login lands

Each CLI reports its own state, so completion is observed rather than
assumed. wait_for_login always returns — a stalled host is reported and the
run continues, so one bad login cannot block the other ten."
```

---

### Task 5: `login --cli codex|claude` — the PTY class

**Files:**
- Modify: `scripts/herdr-auth.sh`
- Modify: `scripts/herdr-auth.test.sh`
- Create: `tests/auth-stubs/herdr`

**Interfaces:**
- Consumes: `extract_url`, `redact` (Task 2); `open_url`, `cmd_login` (Task 3); `wait_for_login` (Task 4)
- Produces: `pane_for <space-label> <tab-label>` — echoes the pane id, empty if absent. `pane_is_busy <pane-id>` — echoes `busy` or `free`. `login_via_pane <pane-id> <keys> <regex>` — drives a TUI flow and echoes the captured URL.

**Before implementing, confirm the two live unknowns** the spec records — the
codex device-code key sequence and `claude setup-token`'s flow shape. Neither is
observable without a PTY. Run against one pane by hand, record what appears,
then set `CODEX_KEYS` / `CLAUDE_KEYS` and the match patterns from what you saw.
Do not guess them.

- [ ] **Step 1: Create the herdr stub**

Create `tests/auth-stubs/herdr` and make it executable:

```bash
#!/usr/bin/env bash
# Stub for the `herdr` CLI. Serves pane listings and pane output from
# $HERDR_AUTH_FIXTURE. send-keys and wait-output are recorded, not executed.
case "$1 $2" in
  "workspace list")
    cat "$HERDR_AUTH_FIXTURE/workspace-list.json"
    ;;
  "pane list")
    cat "$HERDR_AUTH_FIXTURE/pane-list.json"
    ;;
  "tab list")
    cat "$HERDR_AUTH_FIXTURE/tab-list.json"
    ;;
  "pane send-keys")
    printf 'send-keys %s\n' "$*" >> "$HERDR_AUTH_FIXTURE/keys.log"
    ;;
  "pane wait-output")
    exit 0
    ;;
  "pane read")
    cat "$HERDR_AUTH_FIXTURE/pane-read.txt"
    ;;
  *) exit 0 ;;
esac
exit 0
```

Run: `chmod +x tests/auth-stubs/herdr`

- [ ] **Step 2: Write the failing test**

Insert before the final totals `printf`:

```bash
# --- pane-driven login (codex / claude) -------------------------------------
# Two workspaces, BOTH with a 'codex' tab — this is the real fleet shape and
# the case a global tab-label match gets wrong.
cat > "$HERDR_AUTH_FIXTURE/workspace-list.json" <<'JSON'
{"result":{"workspaces":[
 {"workspace_id":"wE","label":"aorus"},
 {"workspace_id":"wF","label":"aorus4"}]}}
JSON
cat > "$HERDR_AUTH_FIXTURE/tab-list.json" <<'JSON'
{"result":{"tabs":[
 {"tab_id":"wE:t1","workspace_id":"wE","label":"claude"},
 {"tab_id":"wE:t2","workspace_id":"wE","label":"codex"},
 {"tab_id":"wF:t1","workspace_id":"wF","label":"claude"},
 {"tab_id":"wF:t2","workspace_id":"wF","label":"codex"}]}}
JSON
cat > "$HERDR_AUTH_FIXTURE/pane-list.json" <<'JSON'
{"result":{"panes":[
 {"pane_id":"wE:p1","tab_id":"wE:t1","workspace_id":"wE","agent_status":"unknown"},
 {"pane_id":"wE:p2","tab_id":"wE:t2","workspace_id":"wE","agent_status":"working"},
 {"pane_id":"wF:p1","tab_id":"wF:t1","workspace_id":"wF","agent_status":"unknown"},
 {"pane_id":"wF:p2","tab_id":"wF:t2","workspace_id":"wF","agent_status":"unknown"}]}}
JSON

got=$(bash "$A" _pane_for aorus codex)
[ "$got" = "wE:p2" ] && ok "pane_for: resolves space+tab to a pane id" \
                     || ko "pane_for: resolves space+tab to a pane id" "got '$got'"

# The regression guard: aorus4's codex tab must not resolve to aorus's pane.
got=$(bash "$A" _pane_for aorus4 codex)
[ "$got" = "wF:p2" ] && ok "pane_for: scopes the tab to its own workspace" \
                     || ko "pane_for: scopes the tab to its own workspace" "got '$got'"

got=$(bash "$A" _pane_for aorus nosuchtab)
[ -z "$got" ] && ok "pane_for: empty for an unknown tab" \
              || ko "pane_for: empty for an unknown tab" "got '$got'"

got=$(bash "$A" _pane_for nosuchspace codex)
[ -z "$got" ] && ok "pane_for: empty for an unknown space" \
              || ko "pane_for: empty for an unknown space" "got '$got'"

got=$(bash "$A" _pane_busy wE:p2)
[ "$got" = busy ] && ok "pane_busy: a live agent reads as busy" \
                  || ko "pane_busy: a live agent reads as busy" "got '$got'"

got=$(bash "$A" _pane_busy wE:p1)
[ "$got" = free ] && ok "pane_busy: agent_status unknown reads as free" \
                  || ko "pane_busy: agent_status unknown reads as free" "got '$got'"

: > "$HERDR_AUTH_OPENED"
printf 'Open this URL: https://auth.example.com/device?code=SYNTHETIC_C\n' \
  > "$HERDR_AUTH_FIXTURE/pane-read.txt"
out=$(HERDR_PANE_ID=wE:p9 bash "$A" _pane_login wE:p1 'Down Enter' 'https://')
grep -q 'SYNTHETIC_C' "$HERDR_AUTH_OPENED" \
  && ok "pane_login: opens the captured URL" \
  || ko "pane_login: opens the captured URL"
printf '%s' "$out" | grep -q 'SYNTHETIC_C' \
  && ko "pane_login: never prints the code" "leaked: $out" \
  || ok "pane_login: never prints the code"

out=$(HERDR_PANE_ID=wE:p1 bash "$A" _pane_login wE:p1 'Down Enter' 'https://' 2>&1)
printf '%s' "$out" | grep -q 'own pane' \
  && ok "pane_login: refuses to drive the pane it runs in" \
  || ko "pane_login: refuses to drive the pane it runs in" "$out"
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash scripts/herdr-auth.test.sh`
Expected: FAIL — `usage:` line for each new seam.

- [ ] **Step 4: Write the implementation**

Add above `cmd_login`:

```bash
# Resolve a space label + tab label to a pane id, via the herdr socket API.
#
# The tab must be matched INSIDE the space's workspace. Every space has a
# 'codex' tab, so a global match by tab label alone silently returns some other
# host's pane — and this script types into whatever it returns.
pane_for() {
  local space="$1" tab="$2"
  herdr pane list 2>/dev/null | python3 -c "
import json,subprocess,sys
space,tab=sys.argv[1],sys.argv[2]

def call(*args):
    return json.loads(subprocess.run(['herdr',*args],capture_output=True,text=True).stdout)

# 1. space label -> workspace id
wsid=None
for w in call('workspace','list')['result']['workspaces']:
    if w['label']==space:
        wsid=w['workspace_id']; break
if wsid is None:
    sys.exit(0)

# 2. tab label, scoped to THAT workspace -> tab ids
want={t['tab_id'] for t in call('tab','list')['result']['tabs']
      if t['label']==tab and t['workspace_id']==wsid}
if not want:
    sys.exit(0)

# 3. first pane in those tabs
for p in json.load(sys.stdin)['result']['panes']:
    if p['tab_id'] in want and p['workspace_id']==wsid:
        print(p['pane_id']); break
" "$space" "$tab" 2>/dev/null
}

pane_is_busy() {
  herdr pane list 2>/dev/null | python3 -c "
import json,sys
pid=sys.argv[1]
for p in json.load(sys.stdin)['result']['panes']:
    if p['pane_id']==pid:
        st=p.get('agent_status')
        print('busy' if (p.get('agent') or st not in (None,'unknown')) else 'free')
        break
else:
    print('free')
" "$1" 2>/dev/null
}

# Drive a TUI login inside a herdr pane. codex and claude produce no output
# without a controlling terminal, and a herdr pane is a PTY — that is the whole
# reason this path exists.
login_via_pane() {
  local pane="$1" keys="$2" pattern="$3" out url k

  if [ "$pane" = "${HERDR_PANE_ID:-}" ]; then
    echo "  refusing to drive our own pane ($pane)" >&2
    return 1
  fi
  if [ "$(pane_is_busy "$pane")" = busy ] && [ -z "${FORCE:-}" ]; then
    echo "  pane $pane has a live agent — skipping (FORCE=1 to override)" >&2
    return 1
  fi

  for k in $keys; do herdr pane send-keys "$pane" "$k" >/dev/null 2>&1; done
  herdr pane wait-output --regex "$pattern" "$pane" >/dev/null 2>&1
  out="$(herdr pane read "$pane" 2>/dev/null)"
  url="$(printf '%s\n' "$out" | extract_url)"
  printf '%s' "$url"
}
```

Extend `cmd_login` — replace `*) echo "unknown or unimplemented cli: $cli"…` with:

```bash
    codex|claude)
      # Set from the live confirmation described at the top of this task.
      local keys pattern tab
      case "$cli" in
        codex)  keys="${CODEX_KEYS:-Down Enter}";  pattern='https://'; tab=codex ;;
        claude) keys="${CLAUDE_KEYS:-Enter}";      pattern='https://'; tab=claude ;;
      esac
      for host in $HOSTS_STR; do
        [ "$(probe "$cli" "$host")" = authed ] && { echo "  host $host: already authed"; continue; }
        pane="$(pane_for "$host" "$tab")"
        if [ -z "$pane" ]; then
          echo "  host $host: no '$tab' tab in space $host — skipping" >&2; continue
        fi
        url="$(login_via_pane "$pane" "$keys" "$pattern")" || continue
        if [ -z "$url" ]; then
          echo "  host $host: no login URL captured from pane $pane" >&2; continue
        fi
        open_url "$url"
        opened=$((opened + 1))
        echo "  opened login URL for host $host (pane $pane)"
      done
      echo "$opened URL(s) opened."
      ;;
    *)
      echo "unknown cli: $cli" >&2; exit 2 ;;
```

Declare `pane` alongside the other locals at the top of `cmd_login`:

```bash
  local cli="$1" host url pane opened=0
```

Add the three seams to `main`, beside `_probe`:

```bash
    _pane_for) pane_for "$@" ;;
    _pane_busy) pane_is_busy "$@" ;;
    _pane_login) login_via_pane "$@" ;;
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash scripts/herdr-auth.test.sh`
Expected: `34 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add scripts/herdr-auth.sh scripts/herdr-auth.test.sh tests/auth-stubs/herdr
git commit -m "herdr/auth: drive the codex and claude logins through panes

Neither CLI emits anything without a controlling terminal, and a herdr pane
is a PTY, so the flow is send-keys, wait-output, read, open. The wiring
guards carry over: never drive our own pane, never type into a pane with a
live agent unless FORCE=1."
```

---

### Task 6: `just` recipes and reference doc

**Files:**
- Modify: `justfile`
- Create: `references/herdr-auth.md`

**Interfaces:**
- Consumes: the finished `scripts/herdr-auth.sh`
- Produces: `just auth-status`, `just auth-test`, `just auth-login <cli>`

- [ ] **Step 1: Add the recipes**

In `justfile`, directly after the `cache-test` recipe, add:

```just
# [herdr] fleet agent-CLI login state (read-only)
auth-status:
    @bash {{dotfiles}}/scripts/herdr-auth.sh status

# [herdr] log a CLI in across the fleet: `just auth-login cursor`
auth-login CLI:
    @bash {{dotfiles}}/scripts/herdr-auth.sh login --cli {{CLI}}

# [local] herdr-auth: unit tests (scripts/herdr-auth.test.sh)
auth-test:
    @bash {{dotfiles}}/scripts/herdr-auth.test.sh
```

- [ ] **Step 2: Verify the recipes resolve**

Run: `just --list | grep auth`
Expected: three lines — `auth-login`, `auth-status`, `auth-test`.

Run: `just auth-test`
Expected: `34 passed, 0 failed`

- [ ] **Step 3: Write the reference doc**

Create `references/herdr-auth.md`:

```markdown
# Fleet agent-CLI authentication

`scripts/herdr-auth.sh` brings the workers' agent CLIs to a logged-in state.

    just auth-status          # read-only: what is logged in where
    just auth-login cursor    # drive one CLI's flow across the fleet

## Two classes, and why

`cursor-agent` prints its login URL over a plain pipe and then polls Cursor's
servers (`redirectTarget=cli`). No PTY, no localhost callback — the URL
completes the login opened from **any** machine, including a phone. All six
hosts run in one pass.

`codex` and `claude` produce nothing without a controlling terminal. An
automation context with no TTY cannot allocate one over ssh at all
(`Pseudo-terminal will not be allocated because stdin is not a terminal`).
herdr panes *are* PTYs, so those flows are driven with `pane send-keys` /
`pane wait-output` / `pane read`.

Prefer codex's **Sign in with Device Code** over **Sign in with ChatGPT**: the
latter calls back to `localhost` on the machine running codex, so a URL opened
on your Mac hits the wrong localhost and the flow dies silently.

## Login URLs are credentials

A login URL carries a PKCE `challenge` — a bearer credential for that attempt.
The script holds it in a shell variable and passes it straight to `open`. It is
never written to disk, never logged, never committed; output says
`opened login URL for host aorus`, never the URL. `redact()` is the single
choke point, and every printed line goes through it.

Credential files are **not** copied between hosts. Tokens may be device-bound,
and spreading live secrets across six machines to save a few clicks is a bad
trade.

## Naming hazard

`aorus` is a host *and* the prefix of the other five. Never glob `aorus*` to
mean "the workers" — it matches all six. Say `host aorus` when you mean the box.

## Testing

    just auth-test

Every external command is stubbed on `PATH` (`tests/auth-stubs/`), so the suite
never touches the fleet and never starts a real flow. Fixtures use a synthetic
challenge; a real one must never enter this repo.
```

- [ ] **Step 4: Confirm no secret leaked**

Run: `grep -rnE 'challenge=[A-Za-z0-9_-]{16,}|uuid=[0-9a-f]{8}-[0-9a-f]{4}' scripts/ tests/ references/ | grep -v SYNTHETIC | grep -v '0000'`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add justfile references/herdr-auth.md
git commit -m "herdr/auth: expose auth recipes and record the design

just auth-status, auth-login, and auth-test put the script beside its herdr
siblings instead of leaving it reachable only by path. The reference records
why the CLIs split into a no-PTY class and a pane-driven one, why device code
beats the ChatGPT flow, and why login URLs are treated as credentials."
```

---

## Verification

After Task 6, the end-to-end check is the spec's own table, regenerated:

```
just auth-status
```

Expected before any login: `7 authed, 11 missing`. After `just auth-login cursor`
completes: `13 authed, 5 missing`. After codex and claude: `18 authed, 0 missing`.

## Notes for the implementer

- **Task 5 has two live unknowns** — the codex key sequence and `claude
  setup-token`'s flow shape. Both are unobservable without a PTY. Confirm them
  against one pane by hand before writing `CODEX_KEYS` / `CLAUDE_KEYS`; do not
  guess.
- **Device codes expire**, typically in 10–15 minutes. The 300s poll ceiling is
  a starting value — reconcile it with the real lifetime once observed.
- **`aorus5`, `aorus7`, `aorus8` rewrote their claude credentials on 2026-08-10**
  when the panes were wired. That is normal refresh-on-launch, not a problem.
