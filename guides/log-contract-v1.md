# Write logs to log contract v1

Log contract v1 is the log shape for new or changed programs on fleet machines.
A sentinel can count these records exactly, and `procrun` can join them to the
run that wrote them. Existing logs are not rewritten. A reader handles them
with a parser profile; see [Read legacy logs](#read-legacy-logs-with-a-parser-profile).

## The record

One record is one line of JSON:

```json
{
  "v": 1,
  "ts": "2026-11-08T17:06:41.110-05:00",
  "level": "error",
  "proc": "dice-api-breaker",
  "run_id": "9f2c…",
  "event": "db.lock_timeout",
  "msg": "Lock wait timeout on orders",
  "fields": { "table": "orders" },
  "err": {
    "type": "SqlError",
    "code": 1205,
    "message": "Lock wait timeout exceeded",
    "stack": "…"
  }
}
```

| Field    | Required | Value                                                                               |
| -------- | -------- | ----------------------------------------------------------------------------------- |
| `v`      | yes      | `1`                                                                                 |
| `ts`     | yes      | ISO 8601 with a UTC offset, such as `2026-11-08T17:06:41.110-05:00`                 |
| `level`  | yes      | `debug`, `info`, `warn` or `error`                                                  |
| `proc`   | yes      | the process name; under `procrun`, `PROCRUN_PROC`                                   |
| `run_id` | yes      | `PROCRUN_RUN_ID` under `procrun`; otherwise 128 random bits in hex, one per process |
| `event`  | yes      | a stable machine name, lowercase, dot-separated: `db.lock_timeout`                  |
| `msg`    | yes      | one line for a person to read                                                       |
| `fields` | no       | an object of extra values                                                           |
| `err`    | no       | `type`, `code`, `message` and `stack` of the error                                  |

Match on `event`, not on `msg`. Keep an event name stable once a sentinel
issue refers to it. Newlines in `msg` become spaces; a stack goes in
`err.stack`, where JSON escapes its newlines.

## Use a helper

Copy one file from `lib/log-contract/` in ai-dotfiles into your project. Each
file starts with a version line, such as `log-contract-v1 helper 1.0.0`. To
update, copy the file again. The helpers have no dependencies and write each
record with one write to stderr. Under `procrun` or `>> log 2>&1`, stderr goes
to the log file.

Each helper rejects an unknown level or a malformed event name. Test a new
log call once before you ship it.

### Node: `logv1.js`

```js
const { createLogger } = require("./logv1");
const log = createLogger({ proc: "dice-api-breaker" });

log.info("breaker.check", "Checked 12 endpoints", { endpoints: 12 });
try {
  await db.query(sql);
} catch (err) {
  log.error(
    "db.lock_timeout",
    "Lock wait timeout on orders",
    { table: "orders" },
    err,
  );
}
```

### Python: `logv1.py`

Python 3.8 or later, standard library only.

```python
from logv1 import Logger

log = Logger(proc="venue-stubhub")
log.info("pipeline.start", "Reviewing workbook", fields={"rows": 120})
try:
    fetch_listings()
except OSError as exc:
    log.error("fetch.failed", "Could not fetch listings", err=exc)
```

### Bash: `logv1.sh`

Bash 3.2 or later. Arguments after the message are `key=value` pairs. Keys
that start with `err.` fill `err`; the rest go into `fields` as strings.

```sh
. "$(dirname "$0")/logv1.sh"
LOGV1_PROC=dice-onsale-notify

logv1 info notify.start "Checking upcoming on-sales" window_h=24
./notify.js || logv1 error notify.failed "notify.js failed" err.type=exit "err.code=$?"
```

Set `LOGV1_FD` to write to a file descriptor other than 2.

## Read legacy logs with a parser profile

`lib/log-contract/log-profile.js` turns the text a log gained since the last
check into whole records with comparable instants. Give each source a profile:

```json
{
  "timestamp": "datetime",
  "tz": "America/New_York",
  "continuation": "timestamp",
  "level": { "error": "\\b(error|failed|timeout)\\b|❌", "warn": "⚠️" }
}
```

| Key            | Values                                                                                                                                                                     |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `timestamp`    | `datetime` (a date and time, or a bare time, at the line start), `json` (v1 records), `none`                                                                               |
| `tz`           | an IANA zone, `UTC`, or an offset such as `+01:00`. A zone written on the line (`UTC`, `EST`, `-05:00`) overrides it. Required unless `timestamp` is `none`.               |
| `continuation` | which lines start a record: `timestamp` (a line with a timestamp), `indent` (a line that does not start with whitespace), `none` (every line), or `{ "start": "<regex>" }` |
| `level`        | optional; a regex per level, tried from `error` down against the whole record. A v1 record's own `level` wins.                                                             |

`datetime` reads these forms, with or without brackets:
`2026-11-08 22:25:08`, `2026-11-08 22:25:08 UTC`, `2026-11-08 16:45:01 EST`,
`2026-11-08 16:41:51.110`, `2026-11-08T16:41:51-05:00`, and a bare `17:06:41`.

- A dated line gives an exact instant.
- A bare time takes the date of the nearest dated line in the same check. If
  there is none, it takes `dateHint` (the last date the previous check saw),
  then `rotationDay`. Otherwise it has no instant.
- A source with no timestamps keeps record order only.

```js
const { parseChunk } = require("./log-profile");
const out = parseChunk(state.heldBack + newText, profile, {
  now: Date.now(),
  lastWriteMs: stat.mtimeMs,
  dateHint: state.lastDate,
});
// out.records: [{ seq, text, lines, ts, level, json }]
state.heldBack = out.heldBack;
state.lastDate = out.lastDate;
```

A check withholds its last record only while the record could still grow:
the continuation rule could extend it (or its last line is unfinished), and it
is younger than 60 s by its timestamp, or by `lastWriteMs` when it has none.
Older trailing records are counted. Carry `heldBack` into the next check, or
rewind the stored byte offset by `heldBackBytes`. A record is then counted
once, at most one check late.
