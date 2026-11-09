# Run a model sentinel with sentinel-agent

`sentinel-agent <project> <id>` runs one headless model review for a
project's sentinel. The wrapper captures the evidence, runs `claude -p`
inside bubblewrap with read and edit access only, validates every edit
before it reaches the real files, writes the model's proposals itself, and
meters the run's cost. Design authority: `process-sentinel-plan.md` in
toodoo-herdr, section 3.8. It generalizes `sentinel-02-agent.sh` in
`clubs/dice`.

The model proposes; a person decides. Nothing here applies a fix, restarts
a process or commits.

## Install

`./setup.sh` (or `./update.sh`) links `bin/sentinel-agent` to
`~/.local/bin/sentinel-agent`, next to `procrun`, whose registry it reads.
It needs `uv`, `claude` (on `PATH` or `~/.local/bin/claude`) and `bwrap`.

**Without `bwrap` it refuses to run the model.** It logs the refusal,
records a `skipped: "no-sandbox"` run and exits 1. On macOS there is no
bubblewrap, so a model sentinel runs only on Linux machines.

## Registry entry

A model sentinel is a `kind = "sentinel"` entry in the machine's
`processes.toml` with `sentinel = "<project>:<id>"` and the keys below. The
project's `sentinel-issues.json` (in the `[projects]` directory) must list
the sentinel under `sentinels` with its `doc`.

```toml
[[process]]
name = "sentinel-02-agent"
kind = "sentinel"
sentinel = "dice:02"
progress = "~/Documents/Projects/clubs/dice/var/sentinel/checks-02.jsonl"
log = "~/Documents/Projects/clubs/dice/logs/sentinel-02-agent.log"
max_silence = "45m"
criticality = "low"
model = "<pinned model id>"        # required, set by the operator
max_usd_per_day = 2.0              # required, set by the operator
max_input_kb = 256                 # required
sandbox = { bwrap = true, read_only = true, tools = ["Read", "Edit"] }
instructions = "Optional project-specific lines appended to the prompt."

[[process.capture]]
cmd = ["node", "sentinel-check.js", "--sentinel=02", "--last"]
name = "check-last"

[[process.capture]]
tmux = "dice:0.0"
lines = 8

[[process.capture]]
tail = "logs/dice-link-tag-sync-2*.log"
newest = 3
lines = 15
name = "band"
```

**`model` and `max_usd_per_day` have no default.** The operator chooses
both for each model sentinel (plan decision 4). An entry without either is
refused, and so is a model alias such as `sonnet` or `opus`: pin a full
model ID so a silent alias move cannot change cost or behavior.
`max_input_kb` is required too.

The `sandbox` must say `bwrap = true` and `read_only = true`. `tools` may
name only `Read` and `Edit`; the wrapper turns them into path-scoped rules
(`Read` of the snapshot directory, `Edit` of three copies in its `work/`
directory). Any other tool is refused.

Each `capture` runs outside the sandbox, before the model starts, and writes
one file (or one per matched file) into the snapshot:

| Key    | Captures                                                          | Options                            |
| ------ | ----------------------------------------------------------------- | ---------------------------------- |
| `cmd`  | stdout and stderr of an argv run in the project directory (120 s) | `name` (required)                  |
| `tmux` | `tmux capture-pane` of a target                                   | `lines` (15), `name`               |
| `tail` | the last lines of a file or glob, relative to the project or `~`  | `lines` (15), `newest` (1), `name` |

## Cron line

Wrap it in `procrun` so its output goes to the entry's `log` and the run is
recorded:

```
9,39 * * * * /home/<user>/.local/bin/procrun sentinel-02-agent -- /home/<user>/.local/bin/sentinel-agent dice 02
```

## What a run does

1. Takes the sentinel's run lock (`var/sentinel/agent-<id>.lock`). A run that
   is still going makes the next tick log `previous run still active,
skipped`.
2. Skips the run when today's metered cost in `agent-runs-<id>.jsonl` has
   reached `max_usd_per_day`, and records `skipped: "budget"`.
3. Rebuilds `var/sentinel-<id>-snapshot/` from the captures. When the
   captures exceed `max_input_kb`, it drops the oldest lines of the largest
   files first and says so in the prompt.
4. Copies the sentinel's doc and `sentinel-issues.json` into `work/` and
   creates an empty `work/proposals.json`.
5. Runs `claude -p --output-format json --model <model> --setting-sources ""
--permission-mode dontAsk --allowedTools ...` inside `bwrap` with `/`
   read-only, `/dev`, `/proc`, a private `/tmp`, its own pid namespace,
   `--die-with-parent`, `~/.claude` and `~/.claude.json` writable for the
   CLI's own state, `~/.claude/.env` masked with `/dev/null`, and only
   `work/` writable in the project. The tmux socket is not reachable. The
   run is killed after 25 minutes.
6. Under the project lock (`var/sentinel/sentinel-issues.lock`, shared by
   every sentinel of the project), copies back each edited copy whose real
   file did not change during the run and that passes validation. A changed
   original keeps the edit in `<file>.conflict` in the snapshot.
7. Appends each valid proposal to `var/sentinel/proposals-<id>.jsonl`.
8. Appends the run's record to `var/sentinel/agent-runs-<id>.jsonl`.

### The copy-back guard

The model can add, never weaken. An edit of `sentinel-issues.json` is
rejected whole, kept in `sentinel-issues.json.rejected`, and logged with
every reason when it:

- moves an issue to `accepted`, `fixed` or `closed`;
- removes an issue;
- changes or removes an existing pattern;
- adds a pattern to an issue that is `accepted` or `closed` (an injected line
  could otherwise route new errors into a silenced issue);
- changes an issue of another sentinel, or moves an issue to another one;
- adds an issue for another sentinel, or with a status other than `open` or
  `watch`;
- changes anything outside `issues` (such as `error_pattern` or `sentinels`);
- is not valid JSON.

The model may add issues of its own sentinel with new patterns, set its
issues to `watch`, and edit other fields of them. Anything stronger is a
proposal.

### Proposals

The model writes a JSON array to `work/proposals.json`. Each entry has
exactly `issue_id` (an issue that exists after copy-back), `title` (one line,
at most 200 characters) and `proposal` (at most 4000 characters), with no
control characters; at most 10 per run. The wrapper drops and logs each
invalid entry and appends each valid one as:

```json
{
  "v": 1,
  "ts": "…",
  "proposal_id": "<128-bit hex>",
  "run_id": "…",
  "host": "aorus8",
  "project": "dice",
  "sentinel": "02",
  "issue_id": "02-I",
  "title": "…",
  "proposal": "…"
}
```

A proposal reaches the operator through Herdr's Needs-you
(`procrun export` stream `proposals`). It becomes work only through a person.

### Run records

Every run, including a skipped one, appends:

```json
{
  "v": 1,
  "run_id": "…",
  "host": "aorus8",
  "project": "dice",
  "sentinel": "02",
  "model": "…",
  "started": "…",
  "ended": "…",
  "rc": 0,
  "input_tokens": 150,
  "output_tokens": 40,
  "cost_usd": 0.25,
  "truncated": false,
  "copied_back": ["sentinel-issues.json"],
  "rejected": [],
  "proposals": 1
}
```

`input_tokens` counts uncached, cache-creation and cache-read input tokens.
`cost_usd` is `total_cost_usd` from the CLI's JSON output, or `null` when the
run produced none (a crash or a timeout); such a run cannot count toward the
budget. A skipped run has `rc: null`, `skipped: "budget"` or
`"no-sandbox"` and cost 0.

Tests: `bash scripts/sentinel-agent.test.sh`, also run by `just test-all`.
