// log-profile 1.0.0
// Parser profiles for legacy and log contract v1 logs (guides/log-contract-v1.md).
// Turns the text a log gained since the last check into whole records with
// comparable instants. Single file, no dependencies; copy it into the reader.
"use strict";

const VERSION = "1.0.0";
const HOLD_BACK_MS = 60 * 1000;
const LEVELS = ["debug", "info", "warn", "error"];
const TIMESTAMPS = ["datetime", "json", "none"];
const CONTINUATIONS = ["timestamp", "indent", "none"];

const ZONE_OFFSETS = {
  Z: 0,
  UTC: 0,
  GMT: 0,
  EST: -300,
  EDT: -240,
  CST: -360,
  CDT: -300,
  MST: -420,
  MDT: -360,
  PST: -480,
  PDT: -420,
};
const ZONE =
  "(Z|[+-]\\d{2}:?\\d{2}|" +
  Object.keys(ZONE_OFFSETS)
    .filter((z) => z !== "Z")
    .join("|") +
  ")";
// [2026-11-08 22:25:08], [2026-11-08 22:25:08 UTC], 2026-11-08 16:45:01 EST,
// [2026-11-08 16:41:51.110], 2026-11-08T17:06:41.110-05:00
const DATED_RE = new RegExp(
  "^\\[?(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2}):(\\d{2})(?:[.,](\\d{1,9}))?(?:\\s*" +
    ZONE +
    "(?![A-Za-z0-9]))?\\]?",
);
// 17:06:41 or [17:06:41.110] at the start of a line
const BARE_RE = /^\[?(\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?\]?(?=\s|$)/;
const FIXED_OFFSET_RE = /^([+-])(\d{2}):?(\d{2})$/;

function fixedOffsetMinutes(zone) {
  if (Object.prototype.hasOwnProperty.call(ZONE_OFFSETS, zone))
    return ZONE_OFFSETS[zone];
  const m = FIXED_OFFSET_RE.exec(zone);
  if (!m) return null;
  return (m[1] === "-" ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3]));
}

const zoneFormatters = new Map();
function zoneFormatter(tz) {
  if (!zoneFormatters.has(tz)) {
    zoneFormatters.set(
      tz,
      new Intl.DateTimeFormat("en-US", {
        timeZone: tz,
        hourCycle: "h23",
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
      }),
    );
  }
  return zoneFormatters.get(tz);
}

// Offset of an IANA zone from UTC, in minutes, at a given instant.
function zoneOffsetMinutes(tz, instantMs) {
  const parts = {};
  for (const p of zoneFormatter(tz).formatToParts(new Date(instantMs)))
    parts[p.type] = p.value;
  const asUtc = Date.UTC(
    +parts.year,
    +parts.month - 1,
    +parts.day,
    +parts.hour,
    +parts.minute,
    +parts.second,
  );
  return Math.round((asUtc - Math.floor(instantMs / 1000) * 1000) / 60000);
}

// Wall-clock fields read in `zone` (an abbreviation, a fixed offset or an IANA name) to epoch ms.
function wallToInstant(f, zone) {
  const wall = Date.UTC(
    f.year,
    f.month - 1,
    f.day,
    f.hour,
    f.minute,
    f.second,
    f.ms,
  );
  const fixed = fixedOffsetMinutes(zone);
  if (fixed !== null) return wall - fixed * 60000;
  let instant = wall - zoneOffsetMinutes(zone, wall) * 60000;
  const second = zoneOffsetMinutes(zone, instant);
  instant = wall - second * 60000;
  return instant;
}

function millis(fraction) {
  return fraction ? Number(fraction.slice(0, 3).padEnd(3, "0")) : 0;
}

// Reads the timestamp at the start of one line of a datetime source.
function readDatetime(line) {
  let m = DATED_RE.exec(line);
  if (m) {
    return {
      kind: "dated",
      date: `${m[1]}-${m[2]}-${m[3]}`,
      fields: {
        year: +m[1],
        month: +m[2],
        day: +m[3],
        hour: +m[4],
        minute: +m[5],
        second: +m[6],
        ms: millis(m[7]),
      },
      zone: m[8] ? m[8].toUpperCase() : null,
    };
  }
  m = BARE_RE.exec(line);
  if (m)
    return {
      kind: "bare",
      time: { hour: +m[1], minute: +m[2], second: +m[3], ms: millis(m[4]) },
    };
  return null;
}

function compileRegex(source, what) {
  try {
    return new RegExp(source);
  } catch (e) {
    throw new Error(`log-profile: ${what} is not a valid regex: ${e.message}`);
  }
}

// Throws on any profile the parser cannot apply exactly; returns a compiled copy.
function validateProfile(profile) {
  if (!profile || typeof profile !== "object")
    throw new Error("log-profile: profile must be an object");
  const known = ["timestamp", "tz", "continuation", "level"];
  for (const key of Object.keys(profile)) {
    if (!known.includes(key))
      throw new Error(
        `log-profile: unknown profile key ${JSON.stringify(key)}`,
      );
  }
  const timestamp = profile.timestamp;
  if (!TIMESTAMPS.includes(timestamp)) {
    throw new Error(
      `log-profile: timestamp must be one of ${TIMESTAMPS.join(", ")}`,
    );
  }
  if (timestamp !== "none") {
    if (typeof profile.tz !== "string" || !profile.tz) {
      throw new Error(
        "log-profile: tz is required when the source has timestamps",
      );
    }
    if (fixedOffsetMinutes(profile.tz.toUpperCase()) === null) {
      try {
        zoneFormatter(profile.tz);
      } catch (e) {
        throw new Error(
          `log-profile: unknown tz ${JSON.stringify(profile.tz)}`,
        );
      }
    }
  }
  const tz =
    profile.tz && fixedOffsetMinutes(profile.tz.toUpperCase()) !== null
      ? profile.tz.toUpperCase()
      : profile.tz;

  let continuation = profile.continuation;
  let startRe = null;
  if (continuation && typeof continuation === "object") {
    if (typeof continuation.start !== "string")
      throw new Error("log-profile: continuation.start must be a regex string");
    startRe = compileRegex(continuation.start, "continuation.start");
    continuation = "start";
  } else if (!CONTINUATIONS.includes(continuation)) {
    throw new Error(
      `log-profile: continuation must be one of ${CONTINUATIONS.join(", ")} or {start: regex}`,
    );
  }
  if (continuation === "timestamp" && timestamp === "none") {
    throw new Error(
      'log-profile: continuation "timestamp" needs a source with timestamps',
    );
  }

  const levelRules = [];
  if (profile.level !== undefined) {
    if (!profile.level || typeof profile.level !== "object")
      throw new Error("log-profile: level must map levels to regexes");
    for (const name of Object.keys(profile.level)) {
      if (!LEVELS.includes(name))
        throw new Error(`log-profile: unknown level ${JSON.stringify(name)}`);
    }
    // Most severe first, so a record that matches several rules gets the worst level.
    for (const name of [...LEVELS].reverse()) {
      if (profile.level[name] !== undefined)
        levelRules.push([
          name,
          compileRegex(profile.level[name], `level.${name}`),
        ]);
    }
  }
  return { timestamp, tz, continuation, startRe, levelRules };
}

function readJson(line) {
  if (!line.startsWith("{")) return null;
  try {
    const obj = JSON.parse(line);
    return obj && typeof obj === "object" && !Array.isArray(obj) ? obj : null;
  } catch (e) {
    return null;
  }
}

// One entry per line: its timestamp in epoch ms (or null) and the calendar date it names.
function lineInstants(lines, p, dateHint, rotationDay) {
  const stamps = lines.map((line) => {
    if (p.timestamp === "none") return null;
    if (p.timestamp === "json") {
      const obj = readJson(line);
      const stamp =
        obj && typeof obj.ts === "string" ? readDatetime(obj.ts) : null;
      return stamp && stamp.kind === "dated"
        ? { ...stamp, json: obj }
        : obj
          ? { kind: "json", json: obj }
          : null;
    }
    return readDatetime(line);
  });

  const datedIdx = [];
  stamps.forEach((s, i) => {
    if (s && s.kind === "dated") datedIdx.push(i);
  });

  function nearestDate(i) {
    let best = null;
    for (const j of datedIdx) {
      if (best === null || Math.abs(j - i) < Math.abs(best - i)) best = j;
    }
    if (best !== null) return stamps[best].date;
    return dateHint || rotationDay || null;
  }

  return stamps.map((s, i) => {
    if (!s) return { ts: null, json: null, stamped: false };
    if (s.kind === "json") return { ts: null, json: s.json, stamped: true };
    if (s.kind === "dated") {
      return {
        ts: wallToInstant(s.fields, s.zone || p.tz),
        json: s.json || null,
        stamped: true,
        date: s.date,
      };
    }
    const date = nearestDate(i);
    if (!date) return { ts: null, json: null, stamped: true };
    const [year, month, day] = date.split("-").map(Number);
    return {
      ts: wallToInstant({ year, month, day, ...s.time }, p.tz),
      json: null,
      stamped: true,
    };
  });
}

function startsRecord(line, info, p) {
  switch (p.continuation) {
    case "none":
      return true;
    case "timestamp":
      return info.stamped;
    case "indent":
      return !/^\s/.test(line);
    case "start":
      return p.startRe.test(line);
    default:
      throw new Error(`log-profile: unhandled continuation ${p.continuation}`);
  }
}

function recordLevel(record, json, p) {
  if (json && LEVELS.includes(json.level)) return json.level;
  for (const [name, re] of p.levelRules) {
    if (re.test(record.text)) return name;
  }
  return null;
}

/**
 * Parses the text a source gained since the last check.
 *
 * text     prior heldBack (if any) followed by the new bytes, as a string.
 * profile  { timestamp, tz, continuation, level? }; see validateProfile.
 * options  now          epoch ms of this check (default Date.now()).
 *          lastWriteMs  the file's mtime; ages a trailing record that has no timestamp.
 *          dateHint     YYYY-MM-DD of the last dated line seen by the previous check.
 *          rotationDay  YYYY-MM-DD the file was rotated, for bare times with no dated line.
 *
 * Returns { records, heldBack, heldBackBytes, lastDate }. records are in file
 * order: { seq, text, lines, ts, level, json }. ts is epoch ms or null. heldBack
 * is the trailing record withheld because its continuation rule could still
 * extend it and it is younger than 60 s; prepend it to the next check's text,
 * or rewind the stored byte offset by heldBackBytes. Store lastDate as the next
 * check's dateHint.
 */
function parseChunk(text, profile, options = {}) {
  const p = validateProfile(profile);
  const now = options.now === undefined ? Date.now() : options.now;
  const dateHint = options.dateHint || null;

  const rawLines = text.split("\n");
  const endsWithNewline = text.endsWith("\n");
  if (endsWithNewline) rawLines.pop();
  const offsets = [];
  let offset = 0;
  for (const raw of rawLines) {
    offsets.push(offset);
    offset += raw.length + 1;
  }
  const lines = rawLines.map((raw) => raw.replace(/\r$/, ""));
  const infos = lineInstants(lines, p, dateHint, options.rotationDay || null);

  const records = [];
  let current = null;
  lines.forEach((line, i) => {
    if (!line.trim()) return;
    if (!current || startsRecord(line, infos[i], p)) {
      current = {
        seq: records.length,
        startOffset: offsets[i],
        text: line,
        lines: 1,
        ts: infos[i].ts,
        json: infos[i].json,
      };
      records.push(current);
    } else {
      current.text += "\n" + line;
      current.lines += 1;
    }
  });

  let lastDate = dateHint;
  infos.forEach((info) => {
    if (info.date) lastDate = info.date;
  });

  let heldBack = "";
  const last = records[records.length - 1];
  const extendable = p.continuation !== "none" || !endsWithNewline;
  if (last && extendable) {
    const reference = last.ts !== null ? last.ts : options.lastWriteMs;
    if (
      reference !== undefined &&
      reference !== null &&
      now - reference < HOLD_BACK_MS
    ) {
      heldBack = text.slice(last.startOffset);
      records.pop();
    }
  }

  for (const record of records) {
    record.level = recordLevel(record, record.json, p);
    delete record.startOffset;
  }
  return {
    records,
    heldBack,
    heldBackBytes: Buffer.byteLength(heldBack, "utf8"),
    lastDate,
  };
}

module.exports = { VERSION, HOLD_BACK_MS, validateProfile, parseChunk };
