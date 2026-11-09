// Tests for lib/log-contract/logv1.js and lib/log-contract/log-profile.js.
// Run by scripts/log-contract.test.sh; prints "N passed, M failed".
"use strict";

const assert = require("assert");
const path = require("path");

const lib = path.join(__dirname, "..", "..", "lib", "log-contract");
const { createLogger, VERSION: LOGV1_VERSION } = require(
  path.join(lib, "logv1.js"),
);
const { parseChunk, validateProfile, HOLD_BACK_MS } = require(
  path.join(lib, "log-profile.js"),
);

let passed = 0;
let failed = 0;
function test(name, fn) {
  try {
    fn();
    passed += 1;
  } catch (e) {
    failed += 1;
    console.log(
      `FAIL ${name}\n  ${e.stack.split("\n").slice(0, 3).join("\n  ")}`,
    );
  }
}

const ISO_OFFSET_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}$/;

function capture(options = {}) {
  const lines = [];
  const log = createLogger({ write: (l) => lines.push(l), ...options });
  return { log, lines, records: () => lines.map((l) => JSON.parse(l)) };
}

// ---- logv1.js ----

test("logv1 writes one v1 record per line with every required field", () => {
  const { log, lines, records } = capture({ proc: "demo", runId: "abc" });
  log.info("job.start", "Starting", { rows: 3 });
  assert.strictEqual(lines.length, 1);
  assert.ok(
    lines[0].endsWith("\n") && lines[0].indexOf("\n") === lines[0].length - 1,
  );
  const r = records()[0];
  assert.deepStrictEqual(Object.keys(r), [
    "v",
    "ts",
    "level",
    "proc",
    "run_id",
    "event",
    "msg",
    "fields",
  ]);
  assert.strictEqual(r.v, 1);
  assert.match(r.ts, ISO_OFFSET_RE);
  assert.strictEqual(r.level, "info");
  assert.strictEqual(r.proc, "demo");
  assert.strictEqual(r.run_id, "abc");
  assert.deepStrictEqual(r.fields, { rows: 3 });
});

test("logv1 takes run_id and proc from procrun environment", () => {
  const saved = {
    id: process.env.PROCRUN_RUN_ID,
    proc: process.env.PROCRUN_PROC,
  };
  process.env.PROCRUN_RUN_ID = "f".repeat(32);
  process.env.PROCRUN_PROC = "dice-onsale-notify";
  try {
    const { log, records } = capture();
    log.warn("notify.slow", "slow");
    assert.strictEqual(records()[0].run_id, "f".repeat(32));
    assert.strictEqual(records()[0].proc, "dice-onsale-notify");
  } finally {
    for (const [k, v] of [
      ["PROCRUN_RUN_ID", saved.id],
      ["PROCRUN_PROC", saved.proc],
    ]) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
});

test("logv1 generates a 128-bit run_id outside procrun", () => {
  const saved = process.env.PROCRUN_RUN_ID;
  delete process.env.PROCRUN_RUN_ID;
  try {
    assert.match(capture().log.runId, /^[0-9a-f]{32}$/);
  } finally {
    if (saved !== undefined) process.env.PROCRUN_RUN_ID = saved;
  }
});

test("logv1 keeps msg on one line and records err with its stack", () => {
  const { log, lines, records } = capture({ proc: "demo" });
  const err = Object.assign(new Error("Lock wait timeout\nexceeded"), {
    code: 1205,
  });
  log.error("db.lock_timeout", "Lock wait\ntimeout", undefined, err);
  assert.strictEqual(lines[0].split("\n").length, 2);
  const r = records()[0];
  assert.strictEqual(r.msg, "Lock wait timeout");
  assert.strictEqual(r.err.type, "Error");
  assert.strictEqual(r.err.code, 1205);
  assert.strictEqual(r.err.message, "Lock wait timeout exceeded");
  assert.ok(r.err.stack.includes("Lock wait timeout"));
  assert.strictEqual(r.fields, undefined);
});

test("logv1 rejects unknown levels and malformed event names", () => {
  const { log } = capture({ proc: "demo" });
  assert.throws(() => log.log("fatal", "a.b", "x"), /unknown level/);
  assert.throws(() => log.info("Lock Timeout", "x"), /event must look like/);
});

test("log-contract helpers share one version line", () => {
  const fs = require("fs");
  for (const file of ["logv1.js", "logv1.py", "logv1.sh"]) {
    const head = fs
      .readFileSync(path.join(lib, file), "utf8")
      .split("\n")
      .slice(0, 3)
      .join("\n");
    assert.ok(
      head.includes(`log-contract-v1 helper ${LOGV1_VERSION}`),
      `${file} version line`,
    );
  }
});

// ---- log-profile.js ----

const NY = {
  timestamp: "datetime",
  tz: "America/New_York",
  continuation: "timestamp",
};
// A check long after every record, so no trailing record is held back.
const LATER = Date.parse("2100-01-01T00:00:00Z");
const ts = (text, profile, options) =>
  parseChunk(text, profile, { now: LATER, ...options }).records.map(
    (r) => r.ts,
  );

test("dated styles parse to the same instant", () => {
  const instant = Date.parse("2026-11-08T22:25:08Z");
  const styles = [
    ["[2026-11-08 17:25:08]", NY],
    ["[2026-11-08 22:25:08 UTC]", NY],
    ["2026-11-08 17:25:08 EST", NY],
    ["2026-11-08T17:25:08-05:00 x", NY],
    ["2026-11-08T22:25:08Z x", NY],
    ["[2026-11-08 22:25:08]", { ...NY, tz: "UTC" }],
    ["[2026-11-08 23:25:08]", { ...NY, tz: "+01:00" }],
    [
      '{"v":1,"ts":"2026-11-08T17:25:08.000-05:00","level":"info"}',
      { timestamp: "json", tz: "UTC", continuation: "none" },
    ],
  ];
  for (const [line, profile] of styles) {
    assert.deepStrictEqual(ts(line.startsWith("{") ? line + "\n" : line + " message\n", profile), [instant], line);
  }
  assert.deepStrictEqual(ts("[2026-11-08 17:25:08.110] x\n", NY), [
    instant + 110,
  ]);
});

test("profile tz follows daylight saving time", () => {
  assert.deepStrictEqual(ts("[2026-07-01 12:00:00] x\n", NY), [
    Date.parse("2026-07-01T16:00:00Z"),
  ]);
  assert.deepStrictEqual(ts("[2026-12-01 12:00:00] x\n", NY), [
    Date.parse("2026-12-01T17:00:00Z"),
  ]);
});

test("a bare time takes the nearest dated line's date", () => {
  const text =
    [
      "[2026-11-07 23:59:00] before midnight",
      "23:59:30 bare, nearest is the line above",
      "continuation of the bare record",
      "00:00:05 bare, nearest is the line below",
      "[2026-11-08 00:00:10] after midnight",
    ].join("\n") + "\n";
  assert.deepStrictEqual(ts(text, NY), [
    Date.parse("2026-11-08T04:59:00Z"),
    Date.parse("2026-11-08T04:59:30Z"),
    Date.parse("2026-11-08T05:00:05Z"),
    Date.parse("2026-11-08T05:00:10Z"),
  ]);
});

test("a bare time with no dated line uses dateHint, then the rotation day", () => {
  assert.deepStrictEqual(
    ts("17:06:41 x\n", NY, {
      dateHint: "2026-11-08",
      rotationDay: "2026-10-31",
    }),
    [Date.parse("2026-11-08T22:06:41Z")],
  );
  assert.deepStrictEqual(
    ts("17:06:41 x\n", NY, { rotationDay: "2026-10-31" }),
    [Date.parse("2026-10-31T21:06:41Z")],
  );
  assert.deepStrictEqual(ts("17:06:41 x\n", NY), [null]);
  const out = parseChunk("[2026-11-08 01:00:00] x\n17:00:00 y\n", NY, {
    now: LATER,
    dateHint: "2026-11-07",
  });
  assert.strictEqual(out.lastDate, "2026-11-08");
});

test("an undated source keeps record order", () => {
  const undated = { timestamp: "none", continuation: "indent" };
  const out = parseChunk("third run done\n  detail\nfirst\nsecond\n", undated, {
    now: 0,
  });
  assert.deepStrictEqual(
    out.records.map((r) => [r.seq, r.text, r.ts]),
    [
      [0, "third run done\n  detail", null],
      [1, "first", null],
      [2, "second", null],
    ],
  );
});

test("continuation lines merge into one record and level rules see the whole record", () => {
  const profile = {
    ...NY,
    level: { error: "\\b(Error|failed)\\b", warn: "⚠️" },
  };
  const text =
    "[2026-11-08 17:00:00] fetch started\n" +
    "[2026-11-08 17:00:01] request failed\n    at fetch (a.js:1)\n    at main (a.js:9)\n" +
    "[2026-11-08 17:00:02] ⚠️ slow\n";
  const records = parseChunk(text, profile, {
    now: Date.parse("2026-11-09T00:00:00Z"),
  }).records;
  assert.deepStrictEqual(
    records.map((r) => [r.lines, r.level]),
    [
      [1, null],
      [3, "error"],
      [1, "warn"],
    ],
  );
});

test("a record split across two checks counts once", () => {
  const profile = { ...NY, level: { error: "Lock wait timeout" } };
  const start = Date.parse("2026-11-08T22:00:00Z");
  const firstChunk =
    "[2026-11-08 16:59:59] ok\n[2026-11-08 17:00:00] ER_LOCK_WAIT_TIMEOUT:\n";
  const secondChunk =
    "  Lock wait timeout exceeded; try restarting transaction\n[2026-11-08 17:00:30] ok\n";
  const countErrors = (records) =>
    records.filter((r) => r.level === "error").length;

  const first = parseChunk(firstChunk, profile, { now: start + 5000 });
  assert.strictEqual(first.records.length, 1);
  assert.strictEqual(countErrors(first.records), 0);
  assert.strictEqual(
    first.heldBack,
    "[2026-11-08 17:00:00] ER_LOCK_WAIT_TIMEOUT:\n",
  );
  assert.strictEqual(first.heldBackBytes, Buffer.byteLength(first.heldBack));

  const second = parseChunk(first.heldBack + secondChunk, profile, {
    now: start + 40000,
  });
  assert.strictEqual(
    countErrors(first.records) + countErrors(second.records),
    1,
  );
  assert.strictEqual(second.records[0].lines, 2);
});

test("a trailing record older than 60 s is counted in the same check", () => {
  const profile = { ...NY, level: { error: "timeout" } };
  const recordTs = Date.parse("2026-11-08T22:00:00Z");
  const text = "[2026-11-08 17:00:00] timeout talking to DB\n";
  const old = parseChunk(text, profile, { now: recordTs + HOLD_BACK_MS + 1 });
  assert.deepStrictEqual(
    old.records.map((r) => r.level),
    ["error"],
  );
  assert.strictEqual(old.heldBack, "");
  const young = parseChunk(text, profile, { now: recordTs + HOLD_BACK_MS - 1 });
  assert.strictEqual(young.records.length, 0);
});

test("an undated trailing record is aged by the file mtime", () => {
  const undated = { timestamp: "none", continuation: "indent" };
  assert.strictEqual(
    parseChunk("Traceback:\n", undated, { now: 100000, lastWriteMs: 99000 })
      .records.length,
    0,
  );
  assert.strictEqual(
    parseChunk("Traceback:\n", undated, { now: 100000, lastWriteMs: 1000 })
      .records.length,
    1,
  );
  assert.strictEqual(
    parseChunk("Traceback:\n", undated, { now: 100000 }).records.length,
    1,
  );
});

test("one-line records are not held back unless the last line is unfinished", () => {
  const lines = { timestamp: "none", continuation: "none" };
  assert.strictEqual(
    parseChunk("done\n", lines, { now: 0, lastWriteMs: 0 }).records.length,
    1,
  );
  const partial = parseChunk("done\nhalf a li", lines, {
    now: 0,
    lastWriteMs: 0,
  });
  assert.deepStrictEqual(
    [partial.records.length, partial.heldBack],
    [1, "half a li"],
  );
});

test("json sources take level from the record", () => {
  const profile = { timestamp: "json", tz: "UTC", continuation: "none" };
  const line =
    '{"v":1,"ts":"2026-11-08T17:00:00.000-05:00","level":"error","event":"db.lock_timeout"}\n';
  const [r] = parseChunk(line, profile, { now: Date.now() }).records;
  assert.strictEqual(r.level, "error");
  assert.strictEqual(r.json.event, "db.lock_timeout");
});

test("invalid profiles fail fast", () => {
  assert.throws(
    () => validateProfile({ timestamp: "datetime", continuation: "none" }),
    /tz is required/,
  );
  assert.throws(
    () => validateProfile({ ...NY, tz: "Mars/Olympus" }),
    /unknown tz/,
  );
  assert.throws(
    () => validateProfile({ timestamp: "none", continuation: "timestamp" }),
    /needs a source with timestamps/,
  );
  assert.throws(
    () => validateProfile({ ...NY, extra: 1 }),
    /unknown profile key/,
  );
  assert.throws(
    () => validateProfile({ ...NY, level: { fatal: "x" } }),
    /unknown level/,
  );
  assert.throws(
    () => validateProfile({ ...NY, continuation: { start: "(" } }),
    /not a valid regex/,
  );
});

console.log(`${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
