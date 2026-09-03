"""Readers. Each yields candidate Items; neither writes to the store.

claude_mem needs an LLM to infer whether work is open. superpowers_docs states
it outright, which is why --docs-only is deterministic and free.
"""

from __future__ import annotations

import os
import re
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from .core import Item, docs_id, log

# ---------------------------------------------------------------------------
# claude-mem
# ---------------------------------------------------------------------------

CLAUDE_MEM_DB = Path(
    os.environ.get("CLAUDE_MEM_DATA_DIR", Path.home() / ".claude-mem")
) / "claude-mem.db"

SENSITIVE_TYPES = {"security_alert", "security_note", "sensitive"}

# `/<slug>-<hash>` suffixes are per-session scratch keys; roll them into the
# root project so 43 raw keys don't become 43 headings for ~20 real projects.
_SESSION_SUFFIX = re.compile(r"/[a-z0-9-]+-[0-9a-f]{6}$")


def root_project(project: str) -> str:
    return _SESSION_SUFFIX.sub("", project)


@dataclass
class Snapshot:
    """Everything the sweep will ever need from claude-mem, read once.

    The connection is opened, drained inside a single deferred transaction,
    and closed before this object is returned -- so by the time any
    ThreadPoolExecutor exists there is no database handle left to misuse.

    That is deliberate. sqlite3 connections are not thread-safe, and an
    earlier version called recent_observations() from inside the verification
    pool: it raised ProgrammingError on every project, an outer handler logged
    it, and every candidate was silently discarded. A clean exit 0 with all
    work gone. Passing a live connection into a function that spawns threads
    is the hazard; not having one is the fix.

    Reading in one transaction also gives every chunk a consistent view. The
    sweep runs ~28 minutes while claude-mem keeps writing; without this,
    chunk 1 and the verification evidence would see different databases.
    """

    rows: list[dict]
    recent_by_project: dict[str, list[dict]]

    def index(self) -> dict[int, dict]:
        return {r["id"]: r for r in self.rows}


def take_snapshot(watermark: int, db: Path = CLAUDE_MEM_DB,
                  recent_limit: int = 40) -> Snapshot:
    """Open, read everything, close. The only function that touches sqlite."""
    conn = connect(db)
    try:
        # DEFERRED so the read set is a single consistent view without
        # blocking claude-mem's writer.
        conn.execute("BEGIN DEFERRED")
        rows = fetch_observations(conn, watermark)

        # Evidence for every project, not just the ones that produce
        # candidates: which projects those are is not known until extraction
        # finishes ~28 minutes later, and reopening then would defeat both the
        # snapshot and the no-live-handle rule. 43 projects x 40 rows is
        # nothing next to the 13k rows already being read.
        recent: dict[str, list[dict]] = {}
        for project in sorted({r["project"] for r in rows}):
            recent[project] = recent_observations(conn, project, recent_limit)

        conn.execute("COMMIT")
        return Snapshot(rows=rows, recent_by_project=recent)
    finally:
        conn.close()


def connect(db: Path = CLAUDE_MEM_DB) -> sqlite3.Connection:
    """Read-only, WAL-aware, with a busy timeout.

    Deliberately NOT immutable=1: against a live claude-mem worker holding a
    4.2 MB -wal that returns a stale snapshot, and a stale read still advances
    the watermark past rows it never saw.
    """
    if not db.exists():
        raise FileNotFoundError(f"claude-mem database not found: {db}")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5.0)
    conn.execute("PRAGMA busy_timeout = 5000")
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='observations'"
    ).fetchone()
    if row is None:
        raise RuntimeError(f"no 'observations' table in {db}")
    return conn


def fetch_observations(conn: sqlite3.Connection, watermark: int) -> list[dict]:
    """Rows newer than the watermark, oldest first so chunks are contiguous."""
    cur = conn.execute(
        """
        SELECT id, project, type, created_at_epoch,
               COALESCE(title, ''), COALESCE(subtitle, '')
        FROM observations
        WHERE created_at_epoch > ?
        ORDER BY created_at_epoch ASC
        """,
        (watermark,),
    )
    return [
        {
            "id": r[0],
            "project": root_project(r[1] or "unknown"),
            "type": r[2] or "",
            "epoch": r[3],
            "title": r[4],
            "subtitle": r[5],
        }
        for r in cur
    ]


def observation_index(rows: list[dict]) -> dict[int, dict]:
    return {r["id"]: r for r in rows}


def recent_observations(conn: sqlite3.Connection, project: str, limit: int = 40) -> list[dict]:
    """Newest rows for one project, used as verification evidence."""
    cur = conn.execute(
        """
        SELECT id, project, created_at_epoch,
               COALESCE(title, ''), COALESCE(subtitle, '')
        FROM observations
        WHERE project = ? OR project LIKE ?
        ORDER BY created_at_epoch DESC
        LIMIT ?
        """,
        (project, f"{project}/%", limit),
    )
    return [
        {"id": r[0], "project": root_project(r[1]), "epoch": r[2],
         "title": r[3], "subtitle": r[4]}
        for r in cur
    ]


# ---------------------------------------------------------------------------
# superpowers docs
# ---------------------------------------------------------------------------

def docs_roots() -> list[Path]:
    """Absolute roots, independent of caller cwd.

    A repo-relative path in a host-global tool would silently yield zero
    records when run from anywhere else -- or, worse, let any third-party
    checkout containing docs/superpowers/ feed the global store.
    """
    env = os.environ.get("GLOBAL_TODO_DOCS_ROOTS")
    if env:
        return [Path(p).expanduser().resolve() for p in env.split(":") if p]
    return [Path.home() / "Developer" / "ai-dotfiles" / "docs" / "superpowers"]


# Anchored and whitelisted. An unanchored /built|shipped|merged|complete/i
# matches "incomplete" and "not yet built" as substrings, silently suppressing
# the most natural phrasings of "still open".
TERMINAL_STATUS = re.compile(r"^\s*(built|shipped|merged|complete[d]?)\b", re.I)
STATUS_LINE = re.compile(r"^\*\*Status:\*\*\s*(.*)$", re.M)
UNCHECKED = re.compile(r"^\s*[-*]\s+\[ \]", re.M)


def scan_docs(roots: list[Path] | None = None) -> list[Item]:
    """One record per file, not per checkbox.

    A plan with 35 open steps is one piece of owed work; the plan file remains
    the task tracker. Files whose Status is terminal are skipped; files with no
    Status line emit a record (relationship-bot-todo.md is exactly that case).
    """
    roots = roots if roots is not None else docs_roots()
    today = time.strftime("%Y-%m-%d")
    items: list[Item] = []

    for root in roots:
        if not root.exists():
            log(f"docs root missing: {root}")
            continue
        project = _project_for_root(root)
        for path in sorted(root.rglob("*.md")):
            try:
                body = path.read_text(errors="replace")
            except OSError as e:
                log(f"docs read failed {path.name}: {type(e).__name__}")
                continue

            m = STATUS_LINE.search(body)
            status_text = m.group(1).strip() if m else ""
            if m and TERMINAL_STATUS.match(status_text):
                continue

            remaining = len(UNCHECKED.findall(body))
            rel = str(path.relative_to(root))
            label = _label(path, status_text, remaining)
            items.append(
                Item(
                    id=docs_id(rel),
                    topic=f"{project} / docs",
                    project=project,
                    text=label,
                    source="docs",
                    source_ids=[],
                    path=str(path),
                    remaining_steps=remaining,
                    first_seen=today,
                )
            )
    return items


def _project_for_root(root: Path) -> str:
    """The repo the docs tree belongs to: .../<repo>/docs/superpowers."""
    parts = root.parts
    if "docs" in parts:
        return parts[parts.index("docs") - 1]
    return root.name


def _label(path: Path, status_text: str, remaining: int) -> str:
    """Stable, countless item text.

    The step count lives in remaining_steps, not in the text -- text feeds the
    fuzzy pass, and a number that changes every time you tick a box would make
    near-matching noisier for no benefit.
    """
    stem = re.sub(r"^\d{4}-\d{2}-\d{2}-", "", path.stem)
    stem = stem.replace("-design", "").replace("-plan", "").replace("-", " ")
    suffix = f": {status_text}" if status_text else ""
    text = f"{stem}{suffix}"
    return text[:117] + "..." if len(text) > 120 else text


def close_finished_docs(items: list[Item], roots: list[Path] | None = None) -> int:
    """Auto-close docs records whose file vanished or went terminal.

    The emission rule alone only stops producing a record; without this a
    finished plan stays open forever with a stale path.
    """
    closed = 0
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for item in items:
        if item.source != "docs" or not item.is_open() or not item.path:
            continue
        p = Path(item.path)
        gone = not p.exists()
        terminal = False
        if not gone:
            m = STATUS_LINE.search(p.read_text(errors="replace"))
            terminal = bool(m and TERMINAL_STATUS.match(m.group(1).strip()))
        if gone or terminal:
            item.status = "done"
            item.closed_at = now
            item.closed_by = "verification"
            closed += 1
    return closed
