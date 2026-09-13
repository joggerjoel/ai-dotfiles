"""
Supervisor-owned persisted state (plan 2.3, 2.6, 10.4).

Everything here lives on the orchestrator host under ~/.herdr-master/ and is read with
ordinary file I/O, never through a pane. A worker that can reach its own attempt counter,
retry budget, or verifier record can talk itself into a pass (10.2).

Two stores with different shapes, because they answer different questions. `state.db` is
current state and answers "what should happen next"; `actions.jsonl` is an append-only
record of what was done and answers "what happened". Neither holds a commit sha or a
changed-file list: git owns those, and a second copy drifts the moment an attempt dies
between the commit and the write.
"""

import datetime
import json
import os
import pathlib
import re
import sqlite3

ROOT = pathlib.Path("~/.herdr-master").expanduser()
DIR_MODE = 0o700
FILE_MODE = 0o600

SCHEMA = """
CREATE TABLE IF NOT EXISTS work_units (
  unit_id       TEXT PRIMARY KEY,
  lane          TEXT NOT NULL,
  profile       TEXT NOT NULL,
  title         TEXT NOT NULL,
  branch        TEXT NOT NULL,
  tree          TEXT NOT NULL,
  base_branch   TEXT NOT NULL,
  state         TEXT NOT NULL,
  attempt       INTEGER NOT NULL DEFAULT 0,
  retry_budget  INTEGER NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS attempts (
  unit_id          TEXT NOT NULL,
  attempt          INTEGER NOT NULL,
  nonce            TEXT NOT NULL,
  agent_kind       TEXT,
  pane_id          TEXT,
  verifier_command TEXT,
  verifier_exit    INTEGER,
  verifier_excerpt TEXT,
  started_at       TEXT NOT NULL,
  closed_at        TEXT,
  PRIMARY KEY (unit_id, attempt)
);
CREATE TABLE IF NOT EXISTS pane_names (
  profile TEXT NOT NULL,
  name    TEXT NOT NULL,
  pane_id TEXT NOT NULL,
  PRIMARY KEY (profile, name)
);
CREATE TABLE IF NOT EXISTS escalations (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  unit_id   TEXT,
  kind      TEXT NOT NULL,
  detail    TEXT NOT NULL,
  opened_at TEXT NOT NULL,
  acked_at  TEXT,
  ack       TEXT
);
"""

# Shapes, not guesses. An audit log that redacts anything six digits long eats exit codes
# and timeouts; the auth bridge marks its own OTPs instead (9.2), via redact_value.
SECRETS = [
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bsk-[A-Za-z0-9\-]{20,}"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._\-]{12,}"),
    re.compile(r"(?i)\b(password|passwd|token|secret|api[_-]?key)\s*[=:]\s*\S+"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S),
]
REDACTED = "<redacted>"


class BudgetExhausted(RuntimeError):
    """The 3-attempt fix-and-reverify budget is spent (plan 6). Only --retry resets it."""


def redact(text):
    if not isinstance(text, str):
        return text
    for pattern in SECRETS:
        text = pattern.sub(REDACTED, text)
    return text


def _scrub(value):
    if isinstance(value, str):
        return redact(value)
    if isinstance(value, dict):
        return {k: _scrub(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_scrub(v) for v in value]
    return value


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


class ActionLog:
    """Append-only audit trail (2.3).

    Not tamper-evident against a same-user agent in the TODO lane, and 2.3 says so; this
    is a record against mistakes and for reconstruction. Secrets are scrubbed before the
    write, not after, because a line already on disk cannot be unwritten.
    """

    def __init__(self, path):
        self.path = pathlib.Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=DIR_MODE)
        self.path.touch(mode=FILE_MODE, exist_ok=True)
        os.chmod(self.path, FILE_MODE)

    def append(self, action, **fields):
        record = {"at": now(), "action": action, **_scrub(fields)}
        with open(self.path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        return record

    def read(self):
        with open(self.path, encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]


class Store:
    def __init__(self, root=ROOT):
        self.root = pathlib.Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=DIR_MODE)
        os.chmod(self.root, DIR_MODE)
        self.db_path = self.root / "state.db"
        self.db = sqlite3.connect(self.db_path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)
        self.db.commit()
        os.chmod(self.db_path, FILE_MODE)
        self.actions = ActionLog(self.root / "actions.jsonl")

    def close(self):
        self.db.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    # Work units -------------------------------------------------------------

    def open_unit(self, unit_id, *, lane, profile, title, branch, tree, base_branch, retry_budget=3):
        """Idempotent: re-opening a known unit returns it unchanged.

        A daemon restart reconciles a `[>]` queue line by unit_id (2.5), so this is called
        again for work already in flight and must not reset the attempt counter or budget.
        """
        existing = self.unit(unit_id)
        if existing:
            return existing
        stamp = now()
        self.db.execute(
            "INSERT INTO work_units (unit_id, lane, profile, title, branch, tree, base_branch,"
            " state, attempt, retry_budget, created_at, updated_at)"
            " VALUES (?,?,?,?,?,?,?,'open',0,?,?,?)",
            (unit_id, lane, profile, title, branch, tree, base_branch, retry_budget, stamp, stamp),
        )
        self.db.commit()
        self.actions.append("unit_opened", unit_id=unit_id, lane=lane, title=title)
        return self.unit(unit_id)

    def unit(self, unit_id):
        row = self.db.execute("SELECT * FROM work_units WHERE unit_id = ?", (unit_id,)).fetchone()
        return dict(row) if row else None

    def set_state(self, unit_id, state):
        self.db.execute(
            "UPDATE work_units SET state = ?, updated_at = ? WHERE unit_id = ?",
            (state, now(), unit_id),
        )
        self.db.commit()
        self.actions.append("unit_state", unit_id=unit_id, state=state)

    # Attempts ---------------------------------------------------------------

    def begin_attempt(self, unit_id, nonce, *, agent_kind=None, pane_id=None):
        """Allocate the next attempt. Raises when the retry budget is spent (6)."""
        unit = self.unit(unit_id)
        if unit is None:
            raise KeyError(unit_id)
        if unit["retry_budget"] <= 0:
            raise BudgetExhausted(f"{unit_id} has no retry budget left")
        attempt = unit["attempt"] + 1
        self.db.execute(
            "INSERT INTO attempts (unit_id, attempt, nonce, agent_kind, pane_id, started_at)"
            " VALUES (?,?,?,?,?,?)",
            (unit_id, attempt, nonce, agent_kind, pane_id, now()),
        )
        self.db.execute(
            "UPDATE work_units SET attempt = ?, updated_at = ? WHERE unit_id = ?",
            (attempt, now(), unit_id),
        )
        self.db.commit()
        self.actions.append("attempt_begin", unit_id=unit_id, attempt=attempt, kind=agent_kind)
        return attempt

    def close_attempt(self, unit_id, attempt, *, command, exit_code, excerpt):
        """Record the verifier outcome. The budget decrements only on failure (6)."""
        self.db.execute(
            "UPDATE attempts SET verifier_command = ?, verifier_exit = ?, verifier_excerpt = ?,"
            " closed_at = ? WHERE unit_id = ? AND attempt = ?",
            (command, exit_code, redact(excerpt), now(), unit_id, attempt),
        )
        if exit_code != 0:
            self.db.execute(
                "UPDATE work_units SET retry_budget = retry_budget - 1, updated_at = ?"
                " WHERE unit_id = ?",
                (now(), unit_id),
            )
        self.db.commit()
        self.actions.append(
            "attempt_close", unit_id=unit_id, attempt=attempt, exit_code=exit_code
        )

    def last_verification(self, unit_id):
        """The one piece of prior-attempt state a packet carries (10.2)."""
        row = self.db.execute(
            "SELECT verifier_command, verifier_exit, verifier_excerpt FROM attempts"
            " WHERE unit_id = ? AND verifier_exit IS NOT NULL"
            " ORDER BY attempt DESC LIMIT 1",
            (unit_id,),
        ).fetchone()
        if not row:
            return None
        return {
            "command": row["verifier_command"],
            "exit_code": row["verifier_exit"],
            "excerpt": row["verifier_excerpt"],
        }

    # Pane name map ----------------------------------------------------------

    def bind_pane(self, profile, name, pane_id):
        """`pane rename` is a display label only, so the resolvable map lives here (2.3, 7)."""
        self.db.execute(
            "INSERT INTO pane_names (profile, name, pane_id) VALUES (?,?,?)"
            " ON CONFLICT(profile, name) DO UPDATE SET pane_id = excluded.pane_id",
            (profile, name, pane_id),
        )
        self.db.commit()

    def pane(self, profile, name):
        row = self.db.execute(
            "SELECT pane_id FROM pane_names WHERE profile = ? AND name = ?", (profile, name)
        ).fetchone()
        return row["pane_id"] if row else None

    def revalidate_panes(self, profile, live_pane_ids):
        """Drop names pointing at panes that no longer exist (7).

        A pane closed while the daemon was down leaves a name aimed at a dead or, worse,
        a recycled id. Returns the names dropped so the caller can rebuild them.
        """
        live = set(live_pane_ids)
        rows = self.db.execute(
            "SELECT name, pane_id FROM pane_names WHERE profile = ?", (profile,)
        ).fetchall()
        stale = [r["name"] for r in rows if r["pane_id"] not in live]
        for name in stale:
            self.db.execute("DELETE FROM pane_names WHERE profile = ? AND name = ?", (profile, name))
        self.db.commit()
        if stale:
            self.actions.append("panes_revalidated", profile=profile, dropped=stale)
        return stale

    # Escalations ------------------------------------------------------------

    def escalate(self, kind, detail, unit_id=None):
        cursor = self.db.execute(
            "INSERT INTO escalations (unit_id, kind, detail, opened_at) VALUES (?,?,?,?)",
            (unit_id, kind, redact(detail), now()),
        )
        self.db.commit()
        self.actions.append("escalation", unit_id=unit_id, kind=kind, detail=detail)
        return cursor.lastrowid

    def ack(self, escalation_id, decision):
        self.db.execute(
            "UPDATE escalations SET acked_at = ?, ack = ? WHERE id = ? AND acked_at IS NULL",
            (now(), decision, escalation_id),
        )
        self.db.commit()
        self.actions.append("ack", escalation_id=escalation_id, decision=decision)

    def open_escalations(self, unit_id=None):
        if unit_id:
            rows = self.db.execute(
                "SELECT * FROM escalations WHERE acked_at IS NULL AND unit_id = ? ORDER BY id",
                (unit_id,),
            ).fetchall()
        else:
            rows = self.db.execute(
                "SELECT * FROM escalations WHERE acked_at IS NULL ORDER BY id"
            ).fetchall()
        return [dict(r) for r in rows]
