# Process monitoring and sentinels checklist: ai-dotfiles (TODO)

[process-sentinel-herdr-plan.md](process-sentinel-herdr-plan.md) is the design authority. Every row starts open. To finish a row, change only its `[ ]` to `[x]` and add one line directly after the row's last indented line: four spaces, then `Evidence: ` (capital E, colon, one space, no date in parentheses), one line under 2000 characters. Edit nothing else in this file.

- [x] **1.1 Write `procrun` as a `uv` script pinned to Python 3.12 with `croniter`: settings from the registry by name; `PROCRUN_RUN_ID` and `PROCRUN_PROC` in the child's environment; one shared append descriptor for stdout and stderr; start and end records with `log_bytes`, `reason`, pid start time and boot ID; child in its own session, `SIGTERM` then `SIGKILL` to that group on timeout; `flock(2)` overlap skip with `skipped` records; whole-line appends.**
    depends-on: []
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #20: bin/procrun, a uv script pinned to Python 3.12 with croniter: registry settings by name, PROCRUN_RUN_ID/PROCRUN_PROC, one shared append fd, start/end records with log_bytes, reason, pid start time and boot ID, own session with SIGTERM then SIGKILL, flock(2) overlap skip with skipped records.

- [x] **1.2 Tests: the log file content and ordering match `>> file 2>&1`; output continues if `procrun` is killed; timeout kills the child and its grandchildren but not `procrun` or the cron shell; skip is compatible with an unwrapped `flock -n` job; a reused pid does not hide an orphan.**
    depends-on: ["1.1"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #20: scripts/procrun.test.sh 69 cases pass on macOS and Linux (Debian, real flock and /proc): log order matches >> file 2>&1, output survives a killed procrun, timeout kills child and grandchildren but not the cron shell, skip interoperates with flock -n, reused pid and other-boot starts are orphaned.

- [x] **1.3 Write `procrun check`: run, progress and presence signals; statuses in precedence `down`, `orphaned`, `failed`, `missed`, `blocked`, `stalled`, `ok`; `croniter` due times; restart baselines that move after one alert; tmux presence by program pattern; `check-state.json` touched every run; `status.jsonl` on transitions only; record-file rotation under `flock`; a silent baseline on the first run, then mail on every non-`ok` transition with reminder intervals by criticality.**
    depends-on: ["1.2"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #20: procrun check with run, progress and presence signals, status precedence, croniter due times, silent first-run baseline, status.jsonl on transitions, check-state.json every run, criticality reminders, tmux presence, rotation under flock; tests in procrun.test.sh.

- [ ] **1.4 Live proof: Add a `procrun watch-check` cron line that mails if `check-state.json` is older than 15 min.**
    depends-on: ["1.3"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [ ] **1.5 Live proof: Generate `processes.toml` for aorus8 from the crontab, tmuxp files, `systemctl` and `docker ps`; mark every `cron` entry `migration = "pending"`; add one `sentinel` entry per counting and model sentinel; set every `timeout = 0`; fill owner, `max_silence`, `progress`, criticality and identity fields by hand.**
    depends-on: ["1.4"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [x] **1.6 Write `procrun validate` with the plan's fail and warn rules, including the `checklog` target rule; run it daily and from `procrun check` when the registry changed; it never blocks checks. Prove it fails on a missing launcher, a schedule mismatch and the old `watch-sentinel.md` target.**
    depends-on: ["1.3"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #20: procrun validate fails on a launcher with no entry, a schedule mismatch and the old watch-sentinel.md checklog target; runs daily with --mail and from check when the registry changed without blocking it; template validates cleanly.

- [x] **1.7 Install `procrun` at `~/.local/bin/procrun` through the installer chosen in decision 1.**
    depends-on: ["1.6"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #20: link_bin_tools installs ~/.local/bin/procrun -> bin/procrun; tested, including running under cron's minimal PATH.

- [ ] **1.8 Live proof: Wrap aorus8's cron lines in batches, backing up the crontab before each batch; replace each `flock -n` with `overlap = "skip"` and its lock path; mark wrapped entries `migration = "done"`.**
    depends-on: ["1.7"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [x] **1.9 Keep every existing `stale` and `checklog` line until P2 acceptance.**
    depends-on: ["1.7"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: Constraint row: PR #20 changes no stale or checklog cron line; guides/procrun.md says to keep them until P2 acceptance.

- [ ] **1.10 Live proof: After two weeks of `procrun` records, set each job's `timeout` from its measured durations (for example three times its longest normal run), reviewed by its owner.**
    depends-on: ["1.9"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [ ] **1.11 Live proof: Acceptance on aorus8: a failing job, a job that exits 0 without writing, a disabled job, a killed `procrun`, a held lock and a stopped container show as `failed`, `stalled`, `missed`, `orphaned`, `blocked` and `down`, each within its threshold, and each mails; the first run after registry creation sent no mail. Record it in `inventory/process-sentinel-p1.md`.**
    depends-on: ["1.10"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [x] **2.1 Write the v1 contract as a short guide with one example per language, and ship single-file helpers for Node, Python and Bash from `ai-dotfiles` with a version line.**
    depends-on: []
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #19: guides/log-contract-v1.md with Node, Python and Bash examples; single-file helpers lib/log-contract/logv1.{js,py,sh} sharing version line 'log-contract-v1 helper 1.0.0', run_id/proc from PROCRUN_RUN_ID/PROCRUN_PROC.

- [x] **2.2 Tests: dated styles parse to the same instant; a bare time takes the nearest dated line's date; an undated source keeps order; a record split across two checks counts once; a trailing record older than 60 s is counted in the same check.**
    depends-on: ["2.1"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #19: lib/log-contract/log-profile.js parser with tests (dated styles same instant, bare time takes nearest dated date, undated keeps order, split record counts once, trailing record >60 s counted); just test-all 724 passed, 0 failed.

- [x] **3.1 Write `procrun export`: stdin request of `{stream, key, offset, inode}` with process names or `project:id` keys; unknown keys rejected; paths resolved from the registry only; `check-state.json` last-run time; rotated generation read before the current file; 1 MB cap; sentinel issue statuses; `df`; last 50 log lines for non-`ok` processes; one redaction filter on all text; writes nothing.**
    depends-on: ["1.1", "1.2", "1.3", "1.6", "1.7", "1.9", "2.1", "2.2"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #21: procrun export answers {stream, key, offset, inode} requests with check state, statuses with 50-line excerpts when not ok, sentinel issues, mount space and record lines across rotation (prev position), capped at 1 MB, redacted with toodoo-herdr's rules (byte-identical copy), writes nothing; authorized_keys restrict,from=,command= line documented.

- [x] **3.2 Tests: a request naming a path or an unknown key is rejected; rotation between polls loses no line; redaction removes token, key, password, `Authorization` and email patterns.**
    depends-on: ["3.1"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #21: tests reject path and unknown keys, lose no line across a rotation, report two rotations as gap, page past the 1 MB cap exactly once, redact secrets, write nothing; just test-all 845 passed, 0 failed.

- [ ] **3.3 Live proof: Create a dedicated collector key pair and install it on aorus8 with `restrict,from="<herdr host>",command=".../procrun export"`. Test that it cannot open a shell, forward a port or run another command.**
    depends-on: ["3.2"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [ ] **3.4 Live proof: Acceptance: every P1 case appears on `/fleet`, and in Needs-you for a test process marked `high`; stopping `procrun check` shows `checker down`; machine health appears on Toodoo's Workforce page. Record it in `inventory/process-sentinel-p2.md`.**
    depends-on: ["3.3"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [ ] **3.5 Live proof: After acceptance, retire the `stale` and `checklog` cron lines the registry now covers, except the `procrun-check` watcher.**
    depends-on: ["3.4"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed

- [x] **4.1 Extract `sentinel-agent <project> <id>` from `sentinel-02-agent.sh`, keeping every current safety property.**
    depends-on: ["1.1", "1.2", "1.3", "1.6", "1.7", "1.9", "2.1", "2.2", "3.1", "3.2"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #22: bin/sentinel-agent <project> <id> keeps every safeguard of sentinel-02-agent.sh (evidence captured outside the sandbox, bwrap read-only root, private tmp, pid namespace, die-with-parent, .env masked, only work/ writable, Read and Edit on copies only, validated copy-back, run lock); refuses to run the model without bwrap.

- [x] **4.2 Copy-back guard: reject edits that move an issue to `accepted`, `fixed` or `closed`, remove an issue, change an existing pattern, or add a pattern to an `accepted` or `closed` issue. Test each with a crafted edit.**
    depends-on: ["4.1"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #22: copy-back guard rejects accepted/fixed/closed transitions, removed issues, changed patterns, patterns added to accepted or closed issues and invalid JSON, each with a crafted-edit test.

- [x] **4.3 Wrapper-written proposals: validate the model's proposal copy file and append to `proposals-<id>.jsonl`.**
    depends-on: ["4.2"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #22: proposals validated (exact keys, lengths, existing issue_id) and appended to var/sentinel/proposals-<id>.jsonl with a proposal_id; tests.

- [x] **4.4 Wrapper metering: `claude -p --output-format json` with a pinned `--model`; append every run to `agent-runs-<id>.jsonl` with tokens and cost.**
    depends-on: ["4.3"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #22: claude -p --output-format json with a pinned --model; every run, failed and skipped included, appended to agent-runs-<id>.jsonl with tokens and cost; tests.

- [x] **4.5 Budget: skip runs at `max_usd_per_day`; truncate the snapshot to `max_input_kb`, noting it in the prompt.**
    depends-on: ["4.4"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #22: runs skip at max_usd_per_day (today only); snapshot truncated to max_input_kb with a note in the prompt; procrun validate requires both caps and a pinned model; tests.

- [x] **4.6 Project-level lock for runners sharing one `sentinel-issues.json`.**
    depends-on: ["4.5"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #22: one project lock var/sentinel/sentinel-issues.lock around copy-back for all runners of a project; busy lock keeps edits uncopied; tests.

- [x] **4.7 `procrun validate` fails a model `sentinel` entry whose `sandbox` lacks `bwrap`, `read_only` or a tool list.**
    depends-on: ["4.6"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #21: procrun validate fails a model sentinel whose sandbox lacks bwrap = true, read_only = true or a non-empty tools list; tests in 'validate: model sentinel sandbox'.

- [x] **4.8 Enforce `retain` for rotated and dated logs; report single legacy logs without pruning or moving them.**
    depends-on: ["4.7"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
    Evidence: PR #22: bin/procrun-retain enforces retain for rotated generations and dated log_glob matches, never the newest, and only reports single legacy logs; procrun-retain.test.sh 20 checks; just test-all 0 failed.

- [ ] **4.9 Live proof: Acceptance: one real proposal appears in Needs-you with its run's cost, and a crafted status-closing edit is rejected. Record it in `inventory/process-sentinel-p3.md`.**
    depends-on: ["4.8"]
    CHECK tests: just test-all
    EXPECT tests: [0-9]+ passed, 0 failed
