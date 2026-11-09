# process-sentinel clubs rows 1.1–1.3 on aorus8: evidence

Repo `~/Documents/Projects/clubs` (HEAD `55d68446`, many uncommitted files of others; nothing committed, reset,
stashed or checked out). Backups before any edit, in `dice/`: `sentinel-check.js.bak.20261109_080622`,
`sentinel-check.test.js.bak.20261109_080622`, `sentinel-issues.json.bak.20261109_080622`,
`dice-api-breaker.js.bak.20261109_080622`. `process-sentinel-clubs-plan.md` (named as design authority in the
clubs todo) does not exist on this machine; I worked from `process-sentinel-plan.md` §3.4 and the parser's API.
`sentinel-issues.json` was edited only while `logs/.sentinel-02-agent.lock` was free (the agent copies back
over an unchanged original only, so it cannot overwrite the edit either way).

Files (all in `clubs/dice`):

- new `log-profile.js` (copy of `~/ai-dotfiles/lib/log-contract/log-profile.js`, version line `log-profile 1.0.0`),
  new `logv1.js` (copy of `lib/log-contract/logv1.js`, `log-contract-v1 helper 1.0.0`);
- `sentinel-check.js` (+122/−26), `sentinel-check.test.js` (+209), `sentinel-issues.json` (+80/−14),
  `dice-api-breaker.js` (+62/−5). `git diff --stat` total 473+/45−.

## 1.1 Parser profiles + sentinel-check applies them + incomplete tail across checks — done

Profiles chosen per source from a scan of each source's newest file (`~/ps-task/gen/profile_scan.js`) and the
timezone checked by comparing the last line with the file's mtime (only `breaker` is UTC):

| source                   | profile                                               | why                                                                                |
| ------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------------------- |
| 02 bands                 | datetime, America/New_York, start `^(?:ESC[..m)*\[\d` | `[YYYY-MM-DD HH:MM:SS(.fff)]` plus ANSI-coloured `[HH:MM:SS]` lines                |
| 02 onsale                | datetime, NY, timestamp                               | `[… .fff ET]` (`ET` is unknown to the parser, the profile tz covers it)            |
| 02/03 breaker            | datetime, UTC, timestamp                              | `[… ]` in UTC; alert-mail output lines join their record                           |
| 02 traffic               | none, none                                            | JSON with numeric `t`, not `ts`                                                    |
| 03 bands                 | datetime, NY, start `^(\[YYYY-MM-DD[ T]               | YYYYMMDD HH:MM:SS                                                                  | === )` | mixed stamp styles; `Timeout …`/`No listings …` and `curl` blocks join their fetch record |
| 03 replenish, 08 prevent | datetime, NY, timestamp                               | `YYYY-MM-DD HH:MM:SS,fff`; `Response: {…}` joins its request                       |
| 04 reconcile             | none, none                                            | JSON with epoch `timestamp`                                                        |
| 04b tracker              | none, none                                            | undated; indented `⚠️ mismatch` lines are separate findings, so not merged         |
| 05 tracker               | none, indent                                          | undated sections; tracebacks/details indented                                      |
| 07 watch                 | none, start `^\d{8} \d{2}:\d{2}:\d{2} `               | `YYYYMMDD HH:MM:SS` is not a style log-profile reads (no ts), but it marks records |
| 08 orders                | datetime, NY, timestamp                               | bare `HH:MM:SS` only                                                               |

`sentinel-check.js` changes: `loadRegistry` validates every profile (bad profile = registry error, exit 2) and
compiles issue patterns `mu` / the error pattern `imu` for profiled sources (`^`/`$` keep their per-line meaning);
`runCheck` feeds a profiled file's new whole lines to `parseChunk` with `dateHint` (stored per file in
`state.dates`) and `rotationDay` (from the file name), classifies whole records, rewinds the offset by
`heldBackBytes` and remembers the file in `state.pending` so a held-back record is read at the next check even if
the file did not change; check records gain `records` per source (`lines` stays the raw line count). An unmatched
record's signature is its first error line. A record that holds lines of two issues is not a `duplicate`; one
line matching two still is (found on live data: without this, sentinel 03 got a false `duplicate` ATTENTION for
`03#13 + 03-noise-empty-market`). `--no-profiles` classifies line by line as before. `runCheck` takes
`root/registry/stateDir/nowMs` for tests.

CHECK `cd dice && node --test sentinel-check.test.js` → `# tests 25 # pass 25 # fail 0` (14 old + 11 new):
dated styles (`[… ]` UTC, `[… UTC]`, `… EST`, `[… .000]` NY, `…,000 - INFO` NY, `[… ET]`) → same epoch ms; a bare
time takes the nearest dated line's date, else the rotation day; undated source keeps order and joins
continuation; profile validation; a multi-line record counts once (and twice with `--no-profiles`); a record
split across two checks counts once, in the check that completes it; a trailing record older than 60 s counts in
the same check; a held-back record is read next check without a file change; record signature; duplicate rule;
breaker v1 equivalence (1.3). Breaker tests unchanged: `node --test dice-api-breaker.test.js
dice-api-breaker-stats.test.js` → 30/30.

Live: the cron run at 08:12 EST (13:12Z) was the first with profiles. All seven `checks-<id>.jsonl` records have
`records`, `attention` 0 for every sentinel; `state-02.json` holds `dates` and `pending` (bands, onsale, breaker
tails held back).

## 1.2 `--dry-run` with and without profiles; differences explained — done

Recorded here (the row names `inventory/process-sentinel-p1-logs.md`; that `inventory/` directory is not in the
clubs repo and I did not create files outside the named ones). Tool: `~/ps-task/gen/compare_profiles.js` reads each
sentinel's unread window once from its saved offsets (state untouched), classifies it both ways and explains each
per-issue difference as merged continuation lines + lines in the held-back tail − records matching only across a
line break. Run at 13:31:25Z (`gen/compare-0831.json`; first run 13:09Z in `gen/compare-0809.json`):

```
unexplained 0
[02] lines bands 15737 onsale 467 breaker 24 traffic 3686 | records 15735 466 23 3686 | held back 2 1 1 0
     02#14 lines 4 records 3: heldBack 1
[03] lines bands 70793 replenish 244 breaker 24 | records 55029 201 23 | held back 66 0 1
     03#13 lines 117 records 39: merged 78        (gateway Timeout lines joined into their fetch records)
     03-noise-zero-failed lines 184 records 170: merged 12 + heldBack 2
[04] 46 lines = 46 records   [04b] 86 = 86   [05] 0   [07] 86 lines, 85 records, 1 held back   [08] 78/77, 1 held
unmatched: 0 in both modes for every sentinel; overlaps: none in either mode (after the duplicate rule)
```

Earlier run (13:09Z): `03#13` 356 → 53 (merged 303), `02#14` 8 → 7 (held back 1), unexplained 0; that run also
showed the false `duplicate` ATTENTION fixed above. The CLI agrees: `node sentinel-check.js --sentinel=03 --dry-run`
vs `… --no-profiles` gave lines 82349/82349, records 71096, attention 0/0 (02 and 07 likewise; the CLI's line counts
differ by the held-back lines only). Blank lines are not records (04b 215 lines → 195 records at 13:09Z).

## 1.3 Move `dice-api-breaker.js` to log contract v1 — NOT done (prepared behind a switch, not switched)

Reason: four other programs parse the breaker's legacy line format, and they are outside the files I may touch:

- `dice/dice-link-tag-sync.sh` `api_wide_failure()` (runs live in panes `dice:0.3`–`0.5`) greps
  `^\[[0-9-]+ [0-9:]+\] ok n=` to decide that Dice is refusing everyone and the cursor must not advance;
- `tmuxp/scraper-status.sh` (`\] ok n=`, `PAUSED|RESUMED`), `dice/dice-api-breaker-stats.js`
  (`^\[(date)\] (PAUSED: …|RESUMED on …)`), `dice/dice-salt-trip-report.js`.
  Writing JSON lines would silently disable the 403-storm guard of a production loop, i.e. change behaviour.

What is in place: `dice-api-breaker.js` has `breakerEvent(msg)` (stable event names, e.g. `breaker.tick`,
`breaker.paused`, `breaker.resumed`, `breaker.consumer_restart_failed`, levels per message) and
`breakerLogger({format})`. Default `legacy` writes the same bytes as before (`[YYYY-MM-DD HH:MM:SS] msg` UTC to
stdout; the crash line to stderr) — confirmed on the live log: ticks 13:13:01–13:15:01Z after the edit are
identical in form. `DICE_API_BREAKER_LOG=v1` writes one v1 record per message via `logv1.js` (`proc`
`dice-api-breaker`, `run_id` from `PROCRUN_RUN_ID` or random, same text in `msg`, crash with `err`). The test
"dice-api-breaker v1 lines hit the same sentinel issues as its legacy lines" renders the same messages both ways
(with an interleaved child-process line) and shows identical per-issue hits for sentinels 02 and 03 (non-zero for
`02#14`, `02#1`, `03#8`, …) with the v1 profile
`{timestamp: "json", tz: "UTC", continuation: {start: "^(?:\\{|\\[\\d{4}-\\d{2}-\\d{2} )"}}`.
To finish: make the four readers accept both line forms, set the `breaker` sources' profile to the v1 profile
above, then set `DICE_API_BREAKER_LOG=v1` on the breaker's cron line.

## Clubs todo

`~/ps-task/process-sentinel-clubs-todo.md`: rows 1.1 and 1.2 ticked with one Evidence line each; 1.3 left open.
