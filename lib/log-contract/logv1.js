// log-contract-v1 helper 1.0.0
// Single-file Node helper for log contract v1 (guides/log-contract-v1.md).
// Copy this file into a project; update by copying it again. No dependencies.
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const VERSION = "1.0.0";
const LEVELS = ["debug", "info", "warn", "error"];
const EVENT_RE = /^[a-z0-9_]+(\.[a-z0-9_]+)*$/;

function pad(n, width = 2) {
  return String(n).padStart(width, "0");
}

// ISO 8601 local time with milliseconds and a numeric offset: 2026-11-08T17:06:41.110-05:00
function isoWithOffset(date = new Date()) {
  const offsetMin = -date.getTimezoneOffset();
  const sign = offsetMin >= 0 ? "+" : "-";
  const abs = Math.abs(offsetMin);
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}` +
    `.${pad(date.getMilliseconds(), 3)}${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`
  );
}

function oneLine(text) {
  return String(text)
    .replace(/\s*[\r\n]+\s*/g, " ")
    .trim();
}

function errorObject(err) {
  if (err instanceof Error) {
    const out = {
      type: err.name || err.constructor.name,
      message: oneLine(err.message),
    };
    const code = err.code !== undefined ? err.code : err.errno;
    if (code !== undefined) out.code = code;
    if (err.stack) out.stack = err.stack;
    return out;
  }
  return { type: typeof err, message: oneLine(err) };
}

function defaultProc() {
  if (process.env.PROCRUN_PROC) return process.env.PROCRUN_PROC;
  const script = process.argv[1];
  return script ? path.basename(script).replace(/\.[^.]+$/, "") : "node";
}

// options: proc (default PROCRUN_PROC, then the script name), runId (default
// PROCRUN_RUN_ID, then 128 random bits), write (default: one write to stderr).
function createLogger(options = {}) {
  const proc = options.proc || defaultProc();
  const runId =
    options.runId ||
    process.env.PROCRUN_RUN_ID ||
    crypto.randomBytes(16).toString("hex");
  const write = options.write || ((line) => fs.writeSync(2, line));

  function log(level, event, msg, fields, err) {
    if (!LEVELS.includes(level))
      throw new Error(`logv1: unknown level ${JSON.stringify(level)}`);
    if (!EVENT_RE.test(event))
      throw new Error(
        `logv1: event must look like db.lock_timeout, got ${JSON.stringify(event)}`,
      );
    const record = {
      v: 1,
      ts: isoWithOffset(),
      level,
      proc,
      run_id: runId,
      event,
      msg: oneLine(msg),
    };
    if (fields && Object.keys(fields).length) record.fields = fields;
    if (err !== undefined && err !== null) record.err = errorObject(err);
    write(JSON.stringify(record) + "\n");
  }

  const logger = { proc, runId, log };
  for (const level of LEVELS) {
    logger[level] = (event, msg, fields, err) =>
      log(level, event, msg, fields, err);
  }
  return logger;
}

module.exports = { VERSION, LEVELS, createLogger, isoWithOffset };
