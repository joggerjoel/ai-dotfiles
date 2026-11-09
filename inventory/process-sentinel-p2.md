# process-sentinel P2 on aorus8: evidence

2026-11-09, run from the operator's Mac (`Mac.attlocal.net`, Tailscale `100.82.153.82`) against aorus8
(Tailscale `100.76.79.55`, LAN `192.168.1.217`). Commits: ai-dotfiles `f643054` on aorus8 (`~/.local/bin/procrun`
-> `~/ai-dotfiles/bin/procrun`, unmodified), herdr-orchestrator `802541c` (main) on the Mac.
Ledger rows (`process-sentinel-herdr-todo.md`): 3.3 (key), the acceptance part of 3.4, and 3.5 (retire).
The operator's task numbered them 3.3, 3.5 and 3.6.

## Row 3.3: restricted collector key (done)

- Key pair created on the Mac for this purpose only: `~/.ssh/herdr-collector` (mode 600) and
  `~/.ssh/herdr-collector.pub`, ed25519, no passphrase (an unattended collector uses it),
  `SHA256:J+wIxcraGlDd63q5z4BxRXPS4vowFsLnLfZfdRVqwSg`, comment `herdr-collector Mac->aorus8 2026-11-09`.
  It is used nowhere else.
- aorus8 sees the Mac as `100.82.153.82` (`$SSH_CLIENT`). `~/.ssh/authorized_keys` was backed up to
  `~/.ssh/authorized_keys.bak.20261109_102530` and gained one line (line 5; the other 4 lines are unchanged):
  ```
  restrict,from="100.82.153.82",command="/home/joggerjoel/.local/bin/procrun export" ssh-ed25519 AAAAC3… herdr-collector Mac->aorus8 2026-11-09
  ```

Proof, with the collector's own options
(`-x -a -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ControlMaster=no -o ControlPath=none -i ~/.ssh/herdr-collector`):

| test                   | command                                                                           | result                                                                                                                                  |
| ---------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| T1 answers an export   | `echo '[]' \| ssh -T … joggerjoel@aorus8`                                         | rc 0, JSON with `v, host=aorus8, ts, check, processes, sentinels, disk, streams`                                                        |
| T1b reads a stream     | `[{"stream":"status","key":"grafana-backup","offset":0,"inode":0}]`               | rc 0, that process's status lines, `inode 74593056`, `offset 16393`                                                                     |
| T1c rejects a path key | `[{"stream":"runs","key":"/etc/passwd",…}]`                                       | rc 1, item rejected, rest answered                                                                                                      |
| T2 another command     | `ssh -T … 'id; hostname; cat ~/.ssh/authorized_keys' </dev/null`                  | rc 0. Output is the export JSON (44900 bytes, valid JSON): 0 `uid=` matches, 0 `ssh-` matches. The forced command ran, not the request. |
| T3 shell / PTY         | `ssh -tt …`                                                                       | `PTY allocation request failed on channel 0`, rc 255                                                                                    |
| T4 stdio forward       | `ssh -W 127.0.0.1:22 …`                                                           | `channel 0: open failed: administratively prohibited`, `stdio forwarding failed`, rc 255                                                |
| T5 local forward       | `ssh -T -N -L 18999:127.0.0.1:22 …`, then `nc 127.0.0.1 18999`                    | `channel 2: open failed: administratively prohibited`, no bytes                                                                         |
| T6 remote forward      | `ssh -T -o ExitOnForwardFailure=yes -N -R 18998:127.0.0.1:22 …`                   | `Error: remote port forwarding failed for listen port 18998`, rc 255                                                                    |
| T7 sftp                | `sftp -i … joggerjoel@aorus8 <<< ls`                                              | no session and no listing; killed by `timeout 20` (rc 124)                                                                              |
| T9 scp                 | `scp -i … joggerjoel@aorus8:.bashrc /tmp/ps2/should-not-exist`                    | no file written; killed by `timeout 20` (rc 124)                                                                                        |
| T10 wrong source       | the same key to the LAN address `192.168.1.217`, so the source is `192.168.1.236` | `Permission denied (publickey,password)`, rc 255 (`from=` holds)                                                                        |

`ssh -v` reports `Remote: /home/joggerjoel/.ssh/authorized_keys:5: key options: command`.
`procrun export` writes nothing: `~/.local/state/procrun` mtime did not move during the tests.

## Row 3.4 (acceptance): collector configured, scheduled, every P1 case on /fleet and in Needs-you (done)

### Profile

The collector reads trusted profiles under the supervisor root `~/.local/state/toodoo/herdr-supervisor`
(guide: herdr-orchestrator `guides/process-collector.md`). I edited `machines/toodoo-herdr/MACHINE.md`,
whose Fleet registry lists `aorus8`. Backup: `~/.claude/.backups/herdr-supervisor/toodoo-herdr/MACHINE.md.20261109_102721`
(plus `MACHINE.sha256`). The change is logged in `~/.claude/.backups/CHANGELOG.md`. Added before
`Observed worker admission`:

```markdown
- **Process collector `aorus8`**:
  - `identity_file`: `/Users/joggerjoel/.ssh/herdr-collector`
  - `user`: `joggerjoel`
```

Running `herdr_master/cli.py --root <root> trust toodoo-herdr` printed `trusted toodoo-herdr at ff1e04f87c08`.
No other profile has a collector group, so the profiles cannot disagree.
The first `fleet-collect --machine aorus8` returned rc 0:
`{"error": null, "gaps": 0, "lines": 2260, "machine": "aorus8", "pages": 2, "raised": 6, "reachable": true}`.
The 6 escalations were real non-`ok` processes (27-32: `dice-purge-tmp`, `reachpro-match-audit-review`,
`status-watch-eventbrite`, `reachpro-tag-staleness`, `unlinked-report`, `cancelled-orders-watch`).

### Schedule

The schedule is a launchd agent on the Mac, `~/Library/LaunchAgents/com.sohyper.toodoo-herdr-fleet-collect.plist`.
It runs `~/.pyenv/versions/3.11.8/bin/python3 herdr_master/cli.py --root ~/.local/state/toodoo/herdr-supervisor fleet-collect`
with `StartInterval 300` and `RunAtLoad`, from WorkingDirectory `~/Developer/herdr-orchestrator`. It writes
stdout and stderr to `<root>/logs/fleet-collect.{out,err}`. This matches the viewer's
`com.sohyper.toodoo-herdr-viewer.plist`.
`plutil -lint` reports OK, and the agent was loaded with `launchctl bootstrap gui/$UID …`.
`launchctl print` shows `run interval = 300 seconds`, and runs 1, 2 and 3 exited with code 0.
Run 3 started at 10:37:53 and was scheduled, not manual.

- Stop it: `launchctl bootout gui/$(id -u)/com.sohyper.toodoo-herdr-fleet-collect`.

### pstest-* acceptance (criticality `high`, so every case escalates)

These were throwaway entries, defined like P1's row 4 but set to `high`. The script is `~/ps-task/pstest-p2-setup.sh`.
Backups were taken first: `~/ps-task/crontab.backup.p2-setup.20261109_102914` and
`~/ps-task/processes.toml.before-p2.20261109_102914`. Setup finished at 10:29:20, and `procrun validate` exited 0.

| case     | setup                                                                                                                                                  | `procrun check` status                                            | Needs-you escalation (collector poll) |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------- | ------------------------------------- |
| failed   | `* * * * * procrun pstest-fail -- sh -c '…; exit 3'`                                                                                                   | `failed (exit 3)` 10:30:01                                        | #34 15:32:49Z                         |
| orphaned | `procrun pstest-orphan -- sleep 1800` started by hand. Killed procrun's `uv` (3124161) and `python` (3124167) with `-9`; `sleep` 3124170 lived on      | `orphaned` "run 7e315de4 has no end and procrun is gone" 10:30:01 | #35 15:32:49Z                         |
| stalled  | `pstest-silent -- true`, `progress` = an empty log, `max_silence 3m`                                                                                   | `stalled` "no progress for 5 min" 10:35:01                        | #37 15:37:50Z                         |
| missed   | `pstest-disabled` ran every minute, then its line was commented out at 10:30:29 (backup `crontab.backup.p2-disable.20261109_103029`), `max_silence 2m` | `missed` "no start since 10:33" 10:35:01                          | #38 15:37:50Z                         |
| blocked  | `flock -n /tmp/pstest/pstest.lock sleep 1800` held the lock. `pstest-lock` has `overlap = "skip"` on that lock and runs every minute                   | `blocked` "three consecutive overlap skips" 10:35:01              | #39 15:37:50Z                         |
| down     | `docker run -d --name pstest-sleep alpine sleep 3600`, `kind = "container"`. It was `ok` at 10:30, then `docker stop` at 10:30:39                      | `down` "container stopped" 10:35:01                               | #40 15:37:50Z                         |

`cli.py status` escalation summaries read, for example,
`aorus8: process pstest-lock is blocked (three consecutive overlap skips); criticality high`.
`/fleet` (`http://127.0.0.1:18797/fleet`, collected 15:37:49Z) showed `aorus8 online`, `collector reachable`,
`disk / 88%`, `12 not ok` and `checker running`. It showed the six pstest rows with these statuses:

- `pstest-fail` with lattice `failed ×8` and the redacted excerpt `pstest-fail run`.
- `pstest-lock` with lattice `skipped (overlap)…`.
- `pstest-orphan` with lattice `running or open`.

procrun also mailed: 10:30:04 for failed and orphaned, and 10:35:04 for stalled, missed, blocked and down.
The daily `validate` mail fired at 10:35:02 with `FAIL: process 'pstest-disabled': no crontab line found`,
which is expected while that line was disabled.

### Cleanup (10:38:40)

- Ran `~/ps-task/pstest-p2-cleanup.sh`, with backups `crontab.backup.p2-cleanup.20261109_103840` and
  `processes.toml.before-p2-cleanup.20261109_103840`.
- Removed the pstest cron lines and the marked registry block, the lock holder, both `sleep 1800` processes,
  the container, `/tmp/pstest` and `~/.local/state/procrun/pstest-*.jsonl`. Copies are in `~/ps-task/p2/pstest-evidence/`.
- The crontab is identical to `crontab.backup.p2-setup.*`. The registry differs from `processes.toml.before-p2.*`
  only by the P3 model settings (see p3), and `procrun validate` exits 0.
- Afterwards no `pstest` container or process is left, `/fleet` contains no `pstest`, and no `pstest`
  escalation is open: they cleared themselves when the entries left the registry.

Not re-tested here: `checker down` on `/fleet` (row 3.4's Herdr evidence covers it with a fake export).

## Row 3.5: retire the legacy `stale` and `checklog` lines (done, 10:39)

Crontab backup: `~/ps-task/crontab.backup.p2-retire.20261109_103925`. These four lines were commented out with the prefix
`#RETIRED-2026-11-09-p2 (procrun registry covers it; process-sentinel 3.5)`:

| crontab line (`*/5 * * * * …/dice/dice-health-alert.sh …`)      | covered by registry entry                                                                                          |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `stale purchases-refresh var/purchases-refresh-ok 60`           | `dice-purchases-cache-refresh`: the same `progress` file, `max_silence 60m`, high                                  |
| `stale breaker-tick var/dice-api-breaker.tick 10`               | `dice-api-breaker`: the same `progress` tick file, `10m`, high                                                     |
| `checklog sentinel-02 watch-sentinel-02.md 45`                  | `sentinel-02` (`checks-02.jsonl`, `45m`, medium) and `sentinel-02-agent-cron` (agent log, `45m`, plus exit status) |
| `stale unbroadcast-cron …/clubs/logs/turn_off_broadcast.log 40` | `turn-off-broadcast`: the same `progress` log, `40m`, high                                                         |

Before retiring, none of the four had an active alert stamp (`var/alert-<name>.stamp`; only
`alert-liveproxies-plan.stamp` exists, and it is not affected). All six covering entries were `ok`.

The registry still had `migration = "pending"` entries for the four lines (`alert-stale-purchases-refresh`,
`alert-stale-breaker-tick`, `alert-checklog-sentinel-02`, `alert-stale-unbroadcast-cron`), so `procrun validate`
failed with `no crontab line found`. I removed those four entries (52 lines; backup
`processes.toml.before-p2-retire.20261109_103935`), after which `procrun validate` exits 0 (only the two
`@reboot` WARNs remain).

Kept: `procrun check`, `procrun watch-check` (the procrun-check watcher) and `procrun validate --mail`. Also
kept are the `dice-health-alert.sh` `disk` and `cmd` lines (`alert-disk-root`, `alert-liveproxies-plan`),
which are not `stale` or `checklog`.

Semantic note: the legacy `checklog` measured the newest check-log row in `watch-sentinel-02.md`. The registry
measures `sentinel-check.js` progress (`checks-02.jsonl`) and the agent's own runs. A model run that exits 0 without
appending a doc row is no longer alerted. Plan §3.1 accepts `progress` as the replacement.

## Follow-ups (not done here)

1. `~/ps-task/gen/gen_registry.py` still emits the four retired `alert-*` entries and does not know the P3 model
   settings. Regenerating the registry would undo both. Update the generator or stop using it.
2. Herdr's `alert_delivery_dead_letter` escalations keep opening (#24 14:14Z and #26 14:46Z before this work;
   #33, #36 and #41 during it). This is pre-existing and was not investigated.
3. The `procrun export` redaction corrupts `agent_runs` lines. See p3: it blocks row 4.9's cost evidence.
