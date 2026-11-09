# Run and watch a machine's processes with procrun

`procrun` wraps cron jobs and checks every process named in the machine's
registry for three signals: **run** (did it start and end, with what exit),
**progress** (did its log or output file move within `max_silence`) and
**presence** (is the long-running thing there). Design authority:
`process-sentinel-plan.md` in toodoo-herdr, sections 3.2, 3.3 and 3.5.

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
  sentinel's `doc`, and a model sentinel without its sandbox. It warns on a
  cron line neither wrapped nor pending and on an entry pending for more than
  30 days.

Keep every existing `stale` and `checklog` alert line until the P2 fleet view
has proved the same cases. `procrun` adds checks beside them; it does not
replace them yet.

## Platforms

Linux reads pid start times from `/proc/<pid>/stat` and the boot ID from
`/proc/sys/kernel/random/boot_id`. macOS uses `ps -o lstart=` (whole
seconds) and `sysctl kern.bootsessionuuid`. Elsewhere both are omitted and
an orphan is detected by pid alone.

Tests: `bash scripts/procrun.test.sh`, also run by `just test-all`.
