# Pre-flight sanity check — design

**Date:** 2026-07-26
**Status:** approved, awaiting implementation plan

## Problem

Every status in this toolkit is computed from configuration _shape_, not
behaviour. `cmd_list` derives its three states from the presence of a JSON key
and a `disabled` flag:

```
● active     = a key exists in ~/.claude.json
○ disabled   = key exists with disabled: true
· not added  = no key
```

So `● active` means _configured_, never _working_. Nothing anywhere — not
`setup.sh`, not `scripts/`, not the `maintain` skill — ever asks whether an
asset functions.

Four failures found on 2026-07-26, all reporting healthy:

| Failure                            | Why it hid                                                  |
| ---------------------------------- | ----------------------------------------------------------- |
| `n8n-mcp` → `n8n.example.com`      | `setup.sh` wrote the placeholder itself, then enabled it    |
| `crawl4ai` → `crawl.example.com`   | same, plus `CRAWL4AI_URL`/`TOKEN` were never set            |
| `magic` → auth failure             | no declared key requirement; fails only on a live handshake |
| `agent-browser` absent from `PATH` | CLAUDE.md mandates it as primary for all browser work       |

Two were _manufactured_ by `setup.sh`, which had no way to detect what it
created.

## Goals

Verify that every configured asset works, contain what breaks, and report the
rest.

## Non-goals

- Repairing assets. The checker diagnoses and contains; you fix.
- Covering plugin-supplied skills. All 103 live in versioned cache directories
  you cannot edit, so findings there would be unactionable.
- Replacing `just lint`. This checks configuration, not code.

## Architecture

```
lib/integrations.sh      NEW   extracted INTEGRATIONS array
scripts/preflight.sh     NEW   the checker
tests/preflight/         NEW   fixtures + harness
tests/smoke/             NEW   opt-in, one file per asset
justfile                 EDIT  + preflight, audit, test
setup.sh                 EDIT  sources lib/integrations.sh
update.sh                EDIT  + final verification step
```

`setup.sh` defines `INTEGRATIONS` inline, so nothing else can read it without
executing `setup.sh`'s top-level code. Extracting the array to
`lib/integrations.sh` and sourcing it from both scripts is the one refactor this
design requires.

### Command surface

| Command                       | Tier          | Writes           |
| ----------------------------- | ------------- | ---------------- |
| `just preflight`              | 2 — handshake | no               |
| `just preflight --quarantine` | 2             | `~/.claude.json` |
| `just audit`                  | 2 + 3 — smoke | no               |
| `just test`                   | —             | no               |
| `update.sh` final step        | 2             | no               |

## Asset classes

| Class             | Source of truth                                          | Tier 2 probe                                                         | Tier 3                     | Containable |
| ----------------- | -------------------------------------------------------- | -------------------------------------------------------------------- | -------------------------- | ----------- |
| MCP servers       | `lib/integrations.sh`, `~/.claude.json`, plugin-supplied | one `claude mcp list`                                                | `tests/smoke/mcp-<n>.sh`   | yes         |
| Mandated CLIs     | `MANDATED_CLIS` in `lib/integrations.sh`                 | `command -v`                                                         | `tests/smoke/cli-<n>.sh`   | no          |
| Env-var services  | `key_var`/`extra_vars`, `~/.claude/.env`                 | set? resolves? reserved placeholder?                                 | via dependent asset        | indirectly  |
| Hooks and scripts | `settings.json` `hooks`                                  | path exists, executable                                              | —                          | no          |
| Repo skills       | `skills/*/SKILL.md`                                      | frontmatter parses, `name` matches directory, referenced paths exist | `tests/smoke/skill-<n>.sh` | no          |

One `claude mcp list` covers every server in roughly 90 seconds. Probing each
server separately would cost 90 seconds per server.

Mandated CLIs come from a declared `MANDATED_CLIS` array, not from parsing
CLAUDE.md. Scraping backticked tokens out of markdown tables would break the
moment someone reformats a table, and it cannot distinguish a mandated tool from
one merely mentioned. Declaring the list beside `INTEGRATIONS` keeps every
asset class driven by an explicit declaration.

## Verdict model

Four verdicts, because collapsing them is what hid the original failures.

- **PASS** — the probe succeeded.
- **FAIL** — the probe ran and the asset is broken. Quarantinable.
- **UNKNOWN** — the asset needs something from you but is not faulty.
  `stripe` and `supabase` reporting _needs authentication_ belong here.
  **Never quarantine UNKNOWN.**
- **UNTESTED** — tier 3 only, and deliberately not PASS. No smoke test exists,
  so the checker claims nothing.

Listing UNTESTED assets by name turns coverage into a worklist instead of a
silent gap.

## Containment

Only MCP servers can be contained. A missing CLI has nothing to disable,
disabling a hook changes behaviour silently, and repo skills have no per-skill
switch.

Quarantine records provenance:

```json
"magic": {
  "disabled": true,
  "_preflight": {
    "quarantinedAt": "2026-07-26T07:52:00Z",
    "reason": "handshake failed: Not authenticated"
  }
}
```

Without the marker, a later run cannot distinguish an asset the checker disabled
from one you disabled deliberately. With it, `just preflight` re-probes
quarantined assets and reports when one is healthy again.

Recovery is `./setup.sh add <name>`. That is a constraint, not a preference:
`set_mcp_server` and `remove_mcp_server` in `setup.sh` are the only writers to
`mcpServers`. `update.sh` reads `~/.claude.json` solely to back it up and
restore it.

Quarantine writes its backup in the format `update.sh` already uses, so the
existing `rollback.sh` reverts it. It takes its own snapshot rather than assuming
a caller made one.

## Integration with `update.sh`

`update.sh` upgrades the CLI stack and re-vendors skills — the operations most
likely to break an asset. A new final step runs `scripts/preflight.sh`
read-only after the upgrade.

That step **never mutates and never fails the update**. An upgrade is not broken
because an unrelated MCP server is down; conflating the two teaches you to ignore
the exit code, which is how this problem started. `just update` is the routine
command, so it must never silently disable anything. Quarantine stays explicit.

## Output

### Human

```
PREFLIGHT  desktop · 2026-07-26 07:52

MCP SERVERS                                13
  ✔ context7  github  firecrawl  headroom  openrouter  morphllm
  ✘ magic            auth failed — API key missing or reset
  ! stripe           needs authentication
  ○ crawl4ai         quarantined 2026-07-20 — NOW HEALTHY
                     re-enable: ./setup.sh add crawl4ai

MANDATED CLIS                               6
  ✔ gh  bun  uv  just  jq
  ✘ agent-browser    not on PATH — CLAUDE.md names it primary

REPO SKILLS                                31
  ✔ 30 parsed
  ✘ isolate          references references/rubric.md (missing)

────────────────────────────────────────────
60 assets · 55 pass · 4 fail · 1 unknown
contain 1 of 4:  just preflight --quarantine
3 failures need you — not containable
```

Passing assets collapse to one line. The summary states how many failures the
tool cannot fix, so `--quarantine` never implies a clean bill of health it did
not deliver.

### JSON

```json
{
  "schema": 1,
  "ranAt": "2026-07-26T07:52:00Z",
  "profile": "desktop",
  "tier": 2,
  "summary": {
    "assets": 60,
    "pass": 55,
    "fail": 4,
    "unknown": 1,
    "untested": 0
  },
  "assets": [
    {
      "class": "mcp",
      "name": "magic",
      "verdict": "fail",
      "detail": "auth failed — API key missing or reset",
      "containable": true,
      "quarantined": false
    }
  ]
}
```

`schema: 1` lets cron alerting and a future `/preflight` skill consume the
results without re-parsing the human table.

## Exit codes

- `0` — no FAILs
- `1` — at least one FAIL; **the checker ran**
- `2` — the checker could not run: `claude`, `jq`, or `just` missing

Separating 1 from 2 distinguishes "tool ran and failed" from "tool never ran".
Collapsing them is how a green cron job hides a checker that has been crashing
for a month.

## Error handling

**A checker failure must never look like an asset failure.** When
`claude mcp list` times out, every MCP server becomes UNKNOWN, never FAIL.
Auto-disabling a whole toolchain on a network blip is the worst outcome this
design can produce. Hard timeout: 180 seconds against an observed 90.

**Probe classes are fenced independently.** A malformed `SKILL.md` fails that
skill alone. One class crashing yields partial results and an explicit
`class errored` line.

**Quarantine is idempotent.** Re-quarantining preserves the original
`quarantinedAt`.

**Smoke tests are sandboxed.** Each runs in a subshell under `timeout` with its
exit code captured. A hung smoke test becomes one FAIL; it does not hang
`just audit`.

**Smoke tests run only for assets that passed tier 2.** Smoke-testing a server
that never connected buries the root cause under cascading noise.

## Testing

```
tests/preflight/
  fixtures/     recorded `claude mcp list` output, fake config trees
  run.sh        the harness
```

`just test` runs `tests/preflight/run.sh`. The justfile has a `lint` recipe
today but no `test` recipe.

The harness shadows `claude` and `jq` on `PATH`, so tests run offline and
deterministically and can reproduce states that are hard to create on demand: a
403, a timeout, a malformed response.

### Regression corpus

The four failures found on 2026-07-26 are the acceptance test.

| Fixture                     | Expected                                     |
| --------------------------- | -------------------------------------------- |
| `n8n` → `example.com`       | FAIL, containable                            |
| `crawl4ai`, env vars unset  | FAIL, containable                            |
| `agent-browser` off `PATH`  | FAIL, not containable                        |
| `magic` auth failure        | FAIL, containable                            |
| `--quarantine` on the above | disables exactly 3, reports 1 as needing you |

### Negative control

An all-healthy fixture must produce exit 0 and zero findings. A probe that
silently does nothing looks identical to a clean environment, so the suite needs
one test that must produce findings and one that must not. Without both, the
checker can rot into a no-op and still look green.

All three exit codes are asserted explicitly, including 2 — stub `claude` as
absent and assert the run reports that the checker could not run.

## Known gaps

`just lint` requires `shellcheck`, which is absent on this machine, so
`preflight.sh` ships verified by `bash -n` alone until you install it.

Two commands named "update" do unrelated work: `just update` runs `update.sh`
(upgrade the CLI stack) and `./setup.sh update` re-applies dotfiles config.
Renaming one is a separate change.
