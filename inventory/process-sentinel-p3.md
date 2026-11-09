# process-sentinel P3 on aorus8: evidence (row 4.9, NOT passed)

2026-11-09, aorus8, run over ssh from the operator's Mac on the operator's own Claude login
(`~/.claude/.credentials.json` OAuth). The ssh environment has no `ANTHROPIC_*` variables, and the runs also
used `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN`. No API key or metered token was used. `cost_usd` is the
CLI's API-equivalent `total_cost_usd`. Commits: ai-dotfiles `f643054` on aorus8 (`~/.local/bin/sentinel-agent`,
unmodified), herdr-orchestrator `802541c` on the Mac. `claude` 2.1.319, `bwrap` at `/usr/bin/bwrap`.

**Result:** the guard part passes. The proposal part did not happen: two real runs found nothing to propose.
The cost part is blocked by a redaction bug (finding 1). Row 4.9 stays open.

## Model sentinel entry

`~/.config/procrun/processes.toml` was backed up to `~/ps-task/processes.toml.before-p3.20261109_103211`.
The existing `sentinel-02-agent` entry (`kind = "sentinel"`, `sentinel = "dice:02"`) gained:

```toml
model = "claude-sonnet-5-5"
max_usd_per_day = 2.0          # API-equivalent guard
max_input_kb = 256
sandbox = { bwrap = true, read_only = true, tools = ["Read", "Edit"] }
# [[process.capture]] × 10, mirroring sentinel-02-agent.sh: cmd node sentinel-check.js --sentinel=02 --last
# (check-last); tmux dice:0.0 … dice:0.6, 8 lines each (pane-0..6); tail logs/dice-api-breaker.log 15
# (breaker-tail); tail logs/dice-link-tag-sync-2*.log newest 3, 15 lines (band)
```

`procrun validate` accepts it. Its only FAIL at that moment was the deliberately disabled `pstest-disabled` line
from p2, and after cleanup it exits 0. No cron line runs `sentinel-agent`: the legacy `sentinel-02-agent.sh`
(cron 9,39) is unchanged.

## Real runs of `sentinel-agent dice 02`

Both runs started after the legacy 10:39 run had ended (10:40:27), so they did not share `var/sentinel-02-snapshot/`.

| run         | started-ended     | rc  | input / output tokens | cost_usd  | copied back            | rejected | proposals |
| ----------- | ----------------- | --- | --------------------- | --------- | ---------------------- | -------- | --------- |
| `38aeda68…` | 10:40:37-10:41:34 | 0   | 327632 / 6340         | 0.2030455 | `watch-sentinel-02.md` | none     | 0         |
| `5729efb3…` | 10:42:00-10:44:36 | 0   | 254962 / 2882         | 0.1845013 | `watch-sentinel-02.md` | none     | 0         |

- **Run 1.** The model reported `ATTENTION: none` and "no new issue type". It appended one check-log row (10:41)
  and left `proposals.json` as `[]`. It also reported that its Bash calls were denied, which is the sandbox
  allowlist working.
- **Run 2.** To give the model a legitimate reason to propose, I briefly added an `instructions` line asking it to
  propose for open 02 issues when the evidence supports a next step (backup
  `processes.toml.before-p3-instructions.20261109_104200`). It answered that "none of the open issues had new
  evidence pointing to a concrete next step" and wrote no proposals. I then restored the backup, so the entry
  is exactly the operator-specified config above.
- Both runs added a real check-log row to `watch-sentinel-02.md`, like the legacy agent does.
- No proposal was fabricated. `var/sentinel/proposals-02.jsonl` does not exist, so Needs-you has no
  `fleet_proposal`. Today's metered total is $0.388 of the $2.00 cap. Logs: `~/ps-task/p3/sentinel-agent-run{,2}.log`.

## Crafted status-closing edit: rejected (passes)

- **Setup.** I ran the installed wrapper with `PROCRUN_REGISTRY=~/ps-task/p3/guard/processes.toml`, which points
  project `dice` at an isolated copy: `sentinel-issues.json` byte-identical to the live file
  (sha256 `6599c1f6…82eb` for both) and `watch-sentinel-02.md`. The entry uses the same model and sandbox, with
  no captures. `PATH` started with `~/ps-task/p3/guard/bin`, whose `claude` is a crafted stub
  (`~/ps-task/p3/claude-stub`). The stub is run by the wrapper inside bwrap. It sets the first open 02 issue
  to `closed` in the work copy and prints a cost-0 result.
- **Wrapper log.**
  ```
  2026-11-09 10:32:32 model output:
  crafted edit: issue 02#7 open -> closed
  2026-11-09 10:32:32 sentinel-issues.json edit rejected, not copied back (kept in …/sentinel-02-snapshot/sentinel-issues.json.rejected): moves issue 02#7 from open to closed
  2026-11-09 10:32:32 end rc=0 cost_usd=0
  ```
- **Result.** The run record shows `"copied_back":[],"rejected":["sentinel-issues.json"]`. The copy's
  `sentinel-issues.json` still has the original sha256. The only difference in `.rejected` is
  `"status": "open"` -> `"closed"` on 02#7.
- **Why a copy.** I used the isolated copy so the crafted run's cost-0 record would not enter the live
  `agent-runs-02.jsonl`, where it would distort the budget and `/fleet`.

## Findings

1. **`procrun export` redaction corrupts `agent_runs` lines.** This blocks the "with its run's cost" half of 4.9.
   - The `secret_assignment` rule in `lib/procrun/redaction-rules.json` matches any key containing `token`.
     It therefore rewrites `"input_tokens":327632` and `"output_tokens":6340` to `[REDACTED:secret_assignment]`,
     making each `agent-runs` line invalid JSON:
     ```
     …"model":"claude-sonnet-5-5",…,"input_tokens":[REDACTED:secret_assignment],"output_tokens":[REDACTED:secret_assignment],"cost_usd":0.2030455,…
     ```
   - The collector's `json.loads` drops such lines (`fleet_collector.py` ingest loop). Herdr's
     `fleet_agent_runs` has 0 rows, while its `agent_runs dice:02` position is already at offset 744. `/fleet`
     shows "model-run cost per day: none metered".
   - The tests missed it because their counts (150, 40) are shorter than the rule's 4-character minimum.
   - The rule file is a byte-identical copy of toodoo-herdr's, so the fix belongs in both, or the redaction
     should apply only to free-text fields and not to structured records.
   - After a fix, these two runs will not be re-read unless the collector's `agent_runs dice:02` position is reset.
2. `sentinel-agent` and the legacy `sentinel-02-agent.sh` share `var/sentinel-02-snapshot/` and take different
   locks (`var/sentinel/agent-02.lock` vs `logs/.sentinel-02-agent.lock`). Running both on a schedule could
   collide. Retire the legacy script before giving `sentinel-agent` a cron line.
3. `~/ps-task/gen/gen_registry.py` does not know the model settings. Regenerating the registry drops them.

## To pass 4.9

- Fix finding 1 and reset the `agent_runs dice:02` position.
- Then run `sentinel-agent dice 02` when sentinel 02 has an ATTENTION item or a new issue type, so the model has
  something to propose. Confirm the `fleet_proposal` escalation and the run's cost on `/fleet`.
