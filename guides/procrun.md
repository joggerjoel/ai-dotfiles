# Run and watch a machine's processes with procrun

`procrun` wraps cron jobs and checks every process named in the machine's
registry for three signals: **run** (did it start and end, with what exit),
**progress** (did its log or output file move within `max_silence`) and
**presence** (is the long-running thing there). Design authority:
`process-sentinel-plan.md` in toodoo-herdr, sections 3.2, 3.3, 3.5 and 3.6.

## Install

`./setup.sh` (or `./update.sh`) links `bin/procrun` to `~/.local/bin/procrun`
through `link_bin_tools`, like every other `bin/` tool. It needs `uv`; the
first run fetches Python 3.12 and `croniter` into uv's cache, later runs
start from the cache.

Cron's `PATH` does not include `~/.local/bin`, so `procrun` looks for `uv` in
this order: `$PROCRUN_UV`, `~/.local/bin/uv`, then `uv` on `PATH`. Cron lines
call `procrun` by absolute path.

## Registry

Copy [`examples/processes.example.toml`](../examples/processes.example.toml)
to `~/.config/procrun/processes.toml` (or set `PROCRUN_REGISTRY`), replace its
entries with the machine's own, and run:

```sh
procrun validate
```

Generate the first registry from `crontab -l`, `~/.tmuxp/*.yaml`,
`systemctl` and `docker ps`. Mark every cron entry `migration = "pending"`
with a `match` substring of its crontab line, and set every `timeout = 0`.
Set a timeout only after two weeks of records show the job's normal duration
(for example three times its longest normal run).

| Kind        | Identity                | Signals                                    |
| ----------- | ----------------------- | ------------------------------------------ |
| `cron`      | its crontab line        | run records (once wrapped) and progress    |
| `daemon`    | `pid_file` or `pattern` | presence and progress                      |
| `tmux-pane` | `target` and `pattern`  | a matching program under the pane's shell  |
| `container` | `container`             | `docker inspect` running and restart count |
| `systemd`   | `unit` (`user_unit`)    | `ActiveState` and `NRestarts`              |
| `sentinel`  | `sentinel = "proj:id"`  | progress of its `checks-<id>.jsonl`        |

The mailer named in `[machine] mailer` is called as `<mailer> <subject>` with
the body on stdin. If the machine's sender takes other arguments, point
`mailer` at a two-line wrapper.

## Wrap a cron job

```
# before
*/15 * * * * cd $DICE && ./run-notify.sh >> logs/notify.log 2>&1
# after
*/15 * * * * cd $DICE && /home/<user>/.local/bin/procrun dice-onsale-notify -- ./run-notify.sh
```

The registry's `log` replaces the redirection: `procrun` opens it in append
mode and gives that one descriptor to the command as stdout and stderr, so
the file reads exactly as `>> file 2>&1` wrote it, and output continues if
`procrun` dies. The command runs in its own session with `PROCRUN_RUN_ID`
and `PROCRUN_PROC` set. Replace a `flock -n <lock>` prefix with
`overlap = "skip"` and the same `lock` path; the two are compatible while
some jobs are still unwrapped. Back up the crontab before each batch, and
set the entry's `migration = "done"`.

A name with no registry entry still runs, unmanaged, and `procrun validate`
reports it.

Records go to `~/.local/state/procrun/<name>.jsonl` (`PROCRUN_STATE_DIR`):
one `start` (pid, pid start time, boot ID) and one `end` (`exit`,
`duration_ms`, `log_bytes`, `reason` of `exit`, `timeout` or `signal`) per
run, or one `skipped`. On timeout the command's process group gets `SIGTERM`,
then `SIGKILL` 10 s later, and `procrun` exits 124.

## Cron lines

Add these three lines, with the machine's absolute path:

```
*/5 * * * * /home/<user>/.local/bin/procrun check
*/5 * * * * /home/<user>/.local/bin/procrun watch-check
17 6 * * * /home/<user>/.local/bin/procrun validate --mail
```

- `procrun check` computes each status, in precedence order `down`,
  `orphaned`, `failed`, `missed`, `blocked`, `stalled`, `ok`. It touches
  `check-state.json` every run and appends to `status.jsonl` only on a
  transition. Its first run is a silent baseline; after that every transition
  into a non-`ok` status mails, with reminders every 1 h (`high`), 6 h
  (`medium`) or 24 h (`low`). It rotates record files over 10 MB to `.1`
  and runs `validate` first whenever the registry changed. Validation reports;
  it never stops a check.
- `procrun watch-check` mails `checker down` (at most hourly) when
  `check-state.json` is older than 15 min (`--max-age` overrides).
- `procrun validate --mail` mails failures daily: a `procrun <name>` with no
  entry, an identity that is not found, a schedule that differs from the
  crontab line, a sentinel `progress` that is not `checks-<id>.jsonl` in its
  project, a `dice-health-alert.sh checklog` line whose file is not a
  sentinel's `doc`, and a model sentinel (one with `model`) whose `sandbox`
  lacks `bwrap = true`, `read_only = true` or a non-empty `tools` list. It warns on a
  cron line neither wrapped nor pending and on an entry pending for more than
  30 days.

Keep every existing `stale` and `checklog` alert line until the P2 fleet view
has proved the same cases. `procrun` adds checks beside them; it does not
replace them yet.

## Export to a collector

`procrun export` is the only command Herdr's collector can run on a machine.
It reads a JSON request on stdin, answers one JSON object on stdout, and
writes nothing: no state directory, no rotation, no record.

### The restricted key

Create a key pair used only by the collector and add its public key to the
machine's `~/.ssh/authorized_keys` as one line:

```
restrict,from="<herdr host>",command="/home/<user>/.local/bin/procrun export" ssh-ed25519 AAAA... herdr-collector
```

`restrict` disables port, agent and X11 forwarding, PTY allocation and
`~/.ssh/rc`; `from=` limits the key to the Herdr host; `command=` replaces
whatever command the client asks for (it arrives only as
`SSH_ORIGINAL_COMMAND`, which `procrun` ignores). The collector calls:

```sh
ssh -i ~/.ssh/herdr-collector <user>@<machine> < request.json > response.json
```

Herdr's existing key and its other uses are unchanged. Installing the key and
proving it cannot open a shell, forward a port or run another command is done
on the machine itself (row 3.3 of the ledger).

### Request

A JSON list of `{stream, key, offset, inode}`; `[]` returns the summary only.

| `stream`     | `key`                    | File, resolved from the registry                  |
| ------------ | ------------------------ | ------------------------------------------------- |
| `runs`       | a process name           | `<state>/<name>.jsonl`                            |
| `status`     | a process name           | `<state>/status.jsonl`, that process's lines only |
| `checks`     | `project:id` (`dice:02`) | the sentinel entry's `progress` file              |
| `proposals`  | `project:id`             | `proposals-<id>.jsonl` beside it                  |
| `agent_runs` | `project:id`             | `agent-runs-<id>.jsonl` beside it                 |

A key is a registry name, never a path: a key with `/`, `\`, or a leading
`.` or `~` is rejected, and so is a name that is not in the registry (a
`project:id` must belong to a `kind = "sentinel"` entry). A rejected item gets
an `error` and no lines, the rest of the request is still answered, and the
exit status is 1. A malformed request (not a list, an unknown stream or
field, a negative offset) gets `{"v": 1, "error": ...}` and exit 2.

Send `offset`, `inode` (and `prev`, when present) back exactly as the last
response returned them; omit them on the first poll.

### Response

- `check`: `check-state.json`'s `last_run` and its age in seconds; Herdr
  shows `checker down` when it stops advancing.
- `processes`: each entry's kind, criticality, status, detail and `since`,
  and for a process not `ok` the last 50 lines of its `log` as `log_tail`.
- `sentinels`: `id`, `status` and `title` of each named sentinel's issues,
  from the project's `sentinel-issues.json`.
- `disk`: total, used and free bytes for each `[machine] mounts` path.
- `streams`: per request item, whole lines after the position, the next
  `inode` and `offset`, `more` when the 1 MB response cap stopped it (poll
  again), and `gap` when lines may be missing.

Lines come from the rotated generation (`.1`) first, then the current file,
so a rotation between polls loses no line. A run that was open across the
rotation writes its `end` line to `.1` after the collector has moved on;
`prev` remembers where `.1` ended, so that line comes with the next poll.
Two rotations between polls, or a file replaced in place, set `gap`, and
reading restarts at the oldest file. A line still being written is held back
until it ends, and a single line larger than the cap is skipped and counted
in `oversize_lines`.

### Redaction

All text passes through one filter before it leaves the machine: tokens and
API keys, private key blocks, passwords and other secret assignments,
`Authorization` and cookie headers, URL credentials, and email addresses.
The rules are
[`lib/procrun/redaction-rules.json`](../lib/procrun/redaction-rules.json), a
byte-identical copy of `toodoo_herdr/redaction-rules.json` in toodoo-herdr
(copied at toodoo-herdr commit `a9dff8d`). Change the rules there and copy
the file again; the test suite compares the two when toodoo-herdr is checked
out beside ai-dotfiles (or at `$TOODOO_HERDR_DIR`). Without the rules file
`procrun export` exports nothing.
||||||| parent of 2bfccc9 (feat: add procrun-retain to enforce retain on rotated and dated logs)

## Retention

`procrun-retain` enforces each entry's `retain` (a duration such as `30d`)
and replaces per-project prune scripts. It is linked to
`~/.local/bin/procrun-retain` like `procrun`. Run it daily:

```
23 4 * * * /home/<user>/.local/bin/procrun-retain
```

`procrun-retain --dry-run` prints what it would delete. For every entry with
`retain` it deletes, by modification time:

- **rotated generations** of the entry's `log` (else its `progress`):
  `<log>.1`, `<log>.2.gz`, `<log>-20261101`, `<log>.2026-11-01`;
- **dated logs** matched by the entry's `log_glob`, such as
  `"~/Documents/Projects/clubs/dice/logs/dice-link-tag-sync-2*.log"`, when
  both the date in the file name and the modification time are older than
  `retain`. The newest match is never deleted, since it may be the live file.

It never deletes, truncates or moves the `log` itself. A `log` with no
rotated generations is a single continuously appended legacy log: `procrun`
and `sentinel-check.js` depend on its fixed path and byte offsets, so it is
reported with its size and left alone. A `log_glob` match with no date in its
name is reported too. Converting a legacy log is a per-project change.

## Platforms

Linux reads pid start times from `/proc/<pid>/stat` and the boot ID from
`/proc/sys/kernel/random/boot_id`. macOS uses `ps -o lstart=` (whole
seconds) and `sysctl kern.bootsessionuuid`. Elsewhere both are omitted and
an orphan is detected by pid alone.

Tests: `bash scripts/procrun.test.sh` and `bash scripts/procrun-retain.test.sh`,
also run by `just test-all`. The model sentinel runner is in
[sentinel-agent.md](sentinel-agent.md).
