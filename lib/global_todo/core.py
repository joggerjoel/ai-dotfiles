"""Store, ids, locking and schema validation for global-todo.

`global-todo.json` is the authoritative store. Everything else on disk is
either operational state or a rendered view. See the design spec for why ids
derive from provenance rather than from item text.
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path

SCHEMA_VERSION = 1
STORE_DIR = Path(os.environ.get("GLOBAL_TODO_DIR", Path.home() / ".claude" / "global-todo"))

STORE = STORE_DIR / "global-todo.json"
BAK = STORE_DIR / "global-todo.json.bak"
STATE = STORE_DIR / ".state.json"
STAGING = STORE_DIR / ".staging.jsonl"
LOCK = STORE_DIR / ".lock"
FAILED = STORE_DIR / ".failed.jsonl"
LOG = STORE_DIR / ".log"

DIR_MODE = 0o700
FILE_MODE = 0o600

STATUSES = ("open", "done", "dismissed", "resolved_by_verification")
CLOSED_STATUSES = ("done", "dismissed", "resolved_by_verification")
CLOSED_BY = (None, "user", "model", "verification")

MAX_TEXT = 120
EXIT_LOCKED = 75

# Control characters and anything that could break out of a rendered line.
_CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
_WS = re.compile(r"\s+")
_PUNCT = re.compile(r"[^\w\s]")


class StoreError(Exception):
    """Raised when the store cannot be read or is structurally invalid."""


class Locked(Exception):
    """Raised when another process holds the store lock."""


# --------------------------------------------------------------------------
# ids and normalization
# --------------------------------------------------------------------------

def normalize(text: str) -> str:
    """Casefold, strip markdown and punctuation, collapse whitespace.

    Used ONLY by the fuzzy near-match pass. Never used to derive an id --
    that is the whole point of keying on provenance instead.
    """
    t = text.casefold()
    t = re.sub(r"[*_`~\[\]()#]", " ", t)
    t = _PUNCT.sub(" ", t)
    return _WS.sub(" ", t).strip()


def claude_mem_id(source_ids: list[int]) -> str:
    key = "claude_mem|" + ",".join(str(i) for i in sorted(source_ids))
    return hashlib.sha256(key.encode()).hexdigest()[:8]


def docs_id(rel_path: str) -> str:
    return hashlib.sha256(f"docs|{rel_path}".encode()).hexdigest()[:8]


def slug(project: str) -> str:
    """Filename-safe project slug with a hash suffix.

    The suffix prevents `13.10.2` and a `13-10-2` sibling from colliding and
    silently overwriting each other's page.
    """
    base = re.sub(r"[^a-z0-9]+", "-", project.lower()).strip("-") or "unnamed"
    h = hashlib.sha256(project.encode()).hexdigest()[:4]
    return f"{base}-{h}"


def jaccard(a: str, b: str) -> float:
    sa, sb = set(a.split()), set(b.split())
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


# --------------------------------------------------------------------------
# item
# --------------------------------------------------------------------------

@dataclass
class Item:
    id: str
    topic: str
    project: str
    text: str
    status: str = "open"
    source: str = "claude_mem"
    source_ids: list[int] = field(default_factory=list)
    alias_ids: list[str] = field(default_factory=list)
    path: str | None = None
    remaining_steps: int | None = None
    newest_source_epoch: int | None = None
    first_seen: str = ""
    closed_at: str | None = None
    closed_by: str | None = None
    sensitive: bool = False

    def is_open(self) -> bool:
        return self.status == "open"

    def keys(self) -> set[str]:
        """Every id this record answers to, so a merge cannot strand a status."""
        return {self.id, *self.alias_ids}


def validate(raw: dict) -> Item:
    """Schema-validate a record before it is allowed into the store.

    The <=120 char rule in the extraction prompt is a request to a model, not
    a guarantee; this is where it becomes one.
    """
    required = ("id", "topic", "project", "text")
    for k in required:
        if not isinstance(raw.get(k), str) or not raw[k].strip():
            raise StoreError(f"record missing/invalid required field: {k}")

    text = _CTRL.sub("", raw["text"]).strip()
    if not text:
        raise StoreError("record text empty after control-character strip")
    if len(text) > MAX_TEXT:
        raise StoreError(f"record text exceeds {MAX_TEXT} chars: {len(text)}")

    status = raw.get("status", "open")
    if status not in STATUSES:
        raise StoreError(f"invalid status: {status!r}")

    closed_by = raw.get("closed_by")
    if closed_by not in CLOSED_BY:
        raise StoreError(f"invalid closed_by: {closed_by!r}")

    source = raw.get("source", "claude_mem")
    if source not in ("claude_mem", "docs"):
        raise StoreError(f"invalid source: {source!r}")

    source_ids = raw.get("source_ids") or []
    if not isinstance(source_ids, list) or not all(isinstance(i, int) for i in source_ids):
        raise StoreError("source_ids must be a list of ints")

    return Item(
        id=raw["id"],
        topic=_CTRL.sub("", raw["topic"]).strip(),
        project=_CTRL.sub("", raw["project"]).strip(),
        text=text,
        status=status,
        source=source,
        source_ids=source_ids,
        alias_ids=list(raw.get("alias_ids") or []),
        path=raw.get("path"),
        remaining_steps=raw.get("remaining_steps"),
        newest_source_epoch=raw.get("newest_source_epoch"),
        first_seen=raw.get("first_seen") or time.strftime("%Y-%m-%d"),
        closed_at=raw.get("closed_at"),
        closed_by=closed_by,
        sensitive=bool(raw.get("sensitive", False)),
    )


# --------------------------------------------------------------------------
# store io
# --------------------------------------------------------------------------

def ensure_dirs() -> None:
    STORE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(STORE_DIR, DIR_MODE)
    (STORE_DIR / "projects").mkdir(exist_ok=True)


def load() -> list[Item]:
    """Read the store. Raises StoreError rather than silently starting fresh."""
    if not STORE.exists():
        return []
    try:
        raw = json.loads(STORE.read_text())
    except (json.JSONDecodeError, OSError) as e:
        raise StoreError(f"store unreadable: {e}") from e
    if not isinstance(raw, dict) or not isinstance(raw.get("items"), list):
        raise StoreError("store is not a {items: [...]} object")
    return [validate(r) for r in raw["items"]]


def save(items: list[Item]) -> None:
    """Back up, then write atomically. Never overwrites a store it can't parse."""
    ensure_dirs()
    if STORE.exists():
        shutil.copy2(STORE, BAK)
        os.chmod(BAK, FILE_MODE)
    payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "items": [asdict(i) for i in items],
    }
    tmp = STORE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    os.chmod(tmp, FILE_MODE)
    tmp.replace(STORE)


def read_state() -> dict:
    if not STATE.exists():
        return {"watermark_epoch": 0, "watermark_unit": "milliseconds",
                "last_run": None, "last_status": None, "chunk_attempts": {}}
    try:
        return json.loads(STATE.read_text())
    except (json.JSONDecodeError, OSError) as e:
        raise StoreError(f"state unreadable: {e}") from e


def write_state(state: dict) -> None:
    ensure_dirs()
    unit = state.get("watermark_unit")
    if unit != "milliseconds":
        raise StoreError(f"watermark_unit must be 'milliseconds', got {unit!r}")
    wm = state.get("watermark_epoch", 0)
    # A seconds-valued watermark matches every row and turns every refresh
    # into a full sweep. 10^12 ms is 2001; any live value is far above it.
    if wm and wm < 1_000_000_000_000:
        raise StoreError(f"watermark_epoch {wm} looks like seconds, not milliseconds")
    tmp = STATE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, indent=2))
    os.chmod(tmp, FILE_MODE)
    tmp.replace(STATE)


def log(msg: str) -> None:
    """Append a diagnostic line.

    Only ids, counts and error classes belong here -- never raw observation or
    model text, which may carry the content of security-typed rows.
    """
    ensure_dirs()
    try:
        if LOG.exists() and LOG.stat().st_size > 1_000_000:
            LOG.replace(LOG.with_suffix(".log.1"))
        with LOG.open("a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}\n")
        os.chmod(LOG, FILE_MODE)
    except OSError:
        pass


class store_lock:
    """Exclusive non-blocking lock over every store mutation.

    fcntl.flock, not the flock(1) binary -- that binary is absent on macOS.
    Held by refresh AND by the close verbs, so a closure issued during a long
    refresh is not discarded by the refresh's final write.
    """

    def __enter__(self):
        ensure_dirs()
        self.fd = os.open(LOCK, os.O_CREAT | os.O_RDWR, FILE_MODE)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.fd)
            raise Locked("another global-todo process holds the lock")
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)
        return False


# --------------------------------------------------------------------------
# merge
# --------------------------------------------------------------------------

def merge(existing: list[Item], candidates: list[Item]) -> tuple[list[Item], int, int]:
    """Fold candidates into the store. Returns (items, added, suppressed).

    Exact id match is load-bearing and runs against ALL records including
    closed ones. Fuzzy is a quality backstop and also sees closed records --
    scoping it to open items is what let reworded candidates resurrect
    closed work.
    """
    by_key: dict[str, Item] = {}
    for item in existing:
        for k in item.keys():
            by_key[k] = item

    norm_index: list[tuple[str, str, Item]] = [
        (i.project, normalize(i.text), i) for i in existing
    ]

    out = list(existing)
    added = suppressed = 0

    for cand in candidates:
        hit = by_key.get(cand.id)
        if hit is not None:
            # Known record: refresh mutable fields only, never status.
            if cand.remaining_steps is not None:
                hit.remaining_steps = cand.remaining_steps
            if cand.newest_source_epoch is not None:
                hit.newest_source_epoch = cand.newest_source_epoch
            suppressed += 1
            continue

        ncand = normalize(cand.text)
        fuzzy = next(
            (it for proj, ntext, it in norm_index
             if proj == cand.project and jaccard(ntext, ncand) >= 0.7),
            None,
        )
        if fuzzy is not None:
            # Same work, different wording. Absorb the id so a future exact
            # match lands, and inherit the existing status.
            if cand.id not in fuzzy.alias_ids:
                fuzzy.alias_ids.append(cand.id)
                by_key[cand.id] = fuzzy
            suppressed += 1
            continue

        out.append(cand)
        for k in cand.keys():
            by_key[k] = cand
        norm_index.append((cand.project, ncand, cand))
        added += 1

    return out, added, suppressed
