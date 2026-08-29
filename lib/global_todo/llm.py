"""The claude-mem sweep: chunked extraction, then per-project verification.

Two orderings here are load-bearing and were both wrong in an earlier draft:

1. Chunks checkpoint individually and the run STOPS at the first failure, so
   observations are never re-read and re-extracted under fresh wording.
2. Verification runs on staging, before anything reaches the store, and
   consolidates BEFORE ids are assigned.
"""

from __future__ import annotations

import json
import re
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor

from . import core, sources
from .core import Item, claude_mem_id, log

CHUNK_SIZE = 120
CONCURRENCY = 6
MAX_ATTEMPTS = 3
VERIFY_BATCH = 60
RECENT_EVIDENCE = 40
TIMEOUT = 300

DEFAULT_MODEL = "claude-haiku-4-5-20251001"


class IncompleteSweep(Exception):
    """A sweep that stopped early.

    Carries its partial results: everything extracted before the stop is still
    valid and must be saved. Only the exit code differs, so a wrapper can tell
    4/110 chunks from 110/110.
    """

    def __init__(self, message: str, added: int, suppressed: int, items: list):
        super().__init__(message)
        self.added = added
        self.suppressed = suppressed
        self.items = items

_FENCED = re.compile(r"```(?:json)?\s*(\[.*?\])\s*```", re.S)

EXTRACT_PROMPT = """\
You are extracting OPEN WORK ITEMS from a coding agent's memory log.

Each input line is TAB-separated: id, project, type, date, title, subtitle.

Emit an item ONLY if work is left undone. Rules:
- Completed, verified, shipped, merged, or committed work yields NOTHING.
- Pure discoveries, notes, or observations with no implied action yield NOTHING.
- Merge the several observations describing ONE piece of work into a single item
  carrying all their ids in source_ids.
- text: imperative, <=120 chars, actionable without reading the source.
- topic: a short theme, 2-4 words. Do NOT include the project name.

Output STRICT JSON only. Schema:
[{"topic":"...","text":"...","source_ids":[1,2]}]

If nothing is open, output exactly: []

INPUT:
"""

VERIFY_PROMPT = """\
You are verifying whether candidate work items are STILL OPEN.

CANDIDATES (JSON) were extracted from older observations. RECENT OBSERVATIONS
are the newest activity in this project. An item is RESOLVED if the recent
observations show the work was completed, superseded, or abandoned.

Rules:
- Return only candidates that are STILL OPEN.
- Merge candidates describing facets of one piece of work into one item,
  carrying the UNION of their source_ids. Never drop a source_id.
- Keep text imperative and <=120 chars.
- When the recent observations say nothing about a candidate, KEEP it.

Output STRICT JSON only. Schema:
[{"topic":"...","text":"...","source_ids":[1,2]}]

"""


def strip_fence(raw: str) -> str:
    """Pull the JSON array out of a model response.

    Haiku fences its output on every observed response AND frequently appends
    a paragraph explaining its reasoning — "All work items ... are completed."
    Stripping only the fence leaves that prose behind and json.loads dies with
    "Extra data". Two spike chunks were both clean; at 110 chunks this appeared
    within the first five.

    Strategy: prefer a fenced array, else scan from the first '[' to its
    balanced ']', ignoring brackets inside strings.
    """
    m = _FENCED.search(raw)
    if m:
        return m.group(1)

    start = raw.find("[")
    if start == -1:
        raise ValueError("no JSON array in model response")

    depth = 0
    in_str = False
    esc = False
    for i, ch in enumerate(raw[start:], start):
        if esc:
            esc = False
            continue
        if ch == "\\" and in_str:
            esc = True
        elif ch == '"':
            in_str = not in_str
        elif not in_str:
            if ch == "[":
                depth += 1
            elif ch == "]":
                depth -= 1
                if depth == 0:
                    return raw[start:i + 1]
    raise ValueError("unbalanced JSON array in model response")


def call(prompt: str, model: str) -> list[dict]:
    """One `claude -p` call: pinned model, no tools, payload on stdin.

    Untrusted observation text reaches this process, so it must not inherit
    the host's Bash/MCP permissions. shell=False with an argument list; the
    payload never touches a command line.
    """
    proc = subprocess.run(
        ["claude", "-p",
         "--model", model,
         "--allowedTools", "",
         "--permission-mode", "plan",
         "--strict-mcp-config"],
        input=prompt, capture_output=True, text=True,
        timeout=TIMEOUT, shell=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"claude -p exited {proc.returncode}")
    data = json.loads(strip_fence(proc.stdout))
    if not isinstance(data, list):
        raise ValueError("model did not return a JSON array")
    return data


def _tsv(rows: list[dict]) -> str:
    return "\n".join(
        "\t".join((
            str(r["id"]), r["project"], r["type"],
            time.strftime("%Y-%m-%d", time.gmtime(r["epoch"] / 1000)),
            r["title"].replace("\t", " "), r["subtitle"].replace("\t", " "),
        ))
        for r in rows
    )


def extract_chunk(rows: list[dict], model: str) -> list[dict]:
    return call(EXTRACT_PROMPT + _tsv(rows), model)


def sweep(items: list[Item], state: dict, args) -> tuple[int, int, list[Item]]:
    """Extract -> verify -> merge. Returns (added, suppressed, items)."""
    model = state.get("model_id") or DEFAULT_MODEL
    state["model_id"] = model

    conn = sources.connect()
    watermark = 0 if args.cold_start else state.get("watermark_epoch", 0)
    rows = sources.fetch_observations(conn, watermark)
    if not rows:
        print("claude-mem: no new observations")
        return 0, 0, items

    chunks = [rows[i:i + CHUNK_SIZE] for i in range(0, len(rows), CHUNK_SIZE)]
    if args.max_chunks:
        chunks = chunks[:args.max_chunks]

    est = len(chunks) * 90 / CONCURRENCY / 60
    print(f"claude-mem: {len(rows)} observations -> {len(chunks)} chunks "
          f"(~{est:.0f} min at concurrency {CONCURRENCY}, model {model})")
    if args.cold_start and not args.yes:
        if input("  proceed? [y/N] ").strip().lower() != "y":
            print("  aborted")
            return 0, 0, items

    obs_index = sources.observation_index(rows)
    attempts = state.setdefault("chunk_attempts", {})
    staged: list[dict] = []
    committed = 0

    # Run concurrently but consume in submission order, so the watermark only
    # ever advances across a contiguous prefix.
    incomplete = False
    with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
        futures = [pool.submit(extract_chunk, c, model) for c in chunks]
        for n, (fut, chunk) in enumerate(zip(futures, chunks)):
            label = f"chunk {n + 1}/{len(chunks)}"
            try:
                out = fut.result()
            except Exception as e:  # noqa: BLE001
                # Retry once in-run before giving up on this chunk; a transient
                # timeout or a one-off malformed response should not cost the
                # whole tail of the sweep.
                log(f"chunk {n} failed ({type(e).__name__}); retrying in-run")
                print(f"  {label}: {type(e).__name__} — retrying", flush=True)
                try:
                    out = extract_chunk(chunk, model)
                except Exception as e2:  # noqa: BLE001
                    key = str(n)
                    attempts[key] = attempts.get(key, 0) + 1
                    log(f"chunk {n} failed again ({type(e2).__name__}) "
                        f"attempt {attempts[key]}")
                    if attempts[key] >= MAX_ATTEMPTS:
                        with core.FAILED.open("a") as fh:
                            fh.write(json.dumps({
                                "chunk": n, "attempts": attempts[key],
                                "error": type(e2).__name__,
                                "obs_ids": [r["id"] for r in chunk]}) + "\n")
                        print(f"  {label}: quarantined after {attempts[key]} attempts "
                              f"— advancing past it")
                        state["watermark_epoch"] = chunk[-1]["epoch"]
                        committed += 1
                        continue
                    print(f"  {label}: failed twice ({type(e2).__name__}) — stopping; "
                          f"re-run to resume (attempt {attempts[key]}/{MAX_ATTEMPTS})")
                    for f in futures[n:]:
                        f.cancel()
                    incomplete = True
                    break
            staged.extend(out)
            state["watermark_epoch"] = chunk[-1]["epoch"]
            attempts.pop(str(n), None)
            committed += 1
            print(f"  {label}: {len(out)} candidates", flush=True)

    core.write_state(state)
    print(f"claude-mem: {committed}/{len(chunks)} chunks committed, "
          f"{len(staged)} raw candidates")
    if incomplete:
        state["last_status"] = "incomplete"

    verified = _verify(staged, obs_index, conn, model)
    candidates = _to_items(verified, obs_index)
    merged, added, suppressed = core.merge(items, candidates)
    print(f"claude-mem: {len(verified)} verified  {added} new  {suppressed} known")
    if incomplete:
        raise IncompleteSweep(
            f"stopped after {committed}/{len(chunks)} chunks; "
            f"re-run `global-todo refresh` to resume",
            added, suppressed, merged,
        )
    return added, suppressed, merged


def _project_of(source_ids: list[int], obs_index: dict) -> str:
    """Project comes from the source rows, never from model output."""
    for sid in source_ids:
        row = obs_index.get(sid)
        if row:
            return row["project"]
    return "unknown"


def _verify(staged: list[dict], obs_index: dict, conn, model: str) -> list[dict]:
    """One call per project over staged candidates plus recent evidence.

    The sweep is chunk-local and cannot see that an August observation
    resolved a July item. This is the only stage that sees a whole project.
    """
    by_project: dict[str, list[dict]] = {}
    for cand in staged:
        sids = [s for s in cand.get("source_ids", []) if isinstance(s, int)]
        if not sids:
            continue
        cand["source_ids"] = sids
        by_project.setdefault(_project_of(sids, obs_index), []).append(cand)

    if not by_project:
        return []
    print(f"verifying:  {len(by_project)} projects", flush=True)

    # Gather evidence on THIS thread. sqlite3 connections are not thread-safe;
    # touching one from the pool raises ProgrammingError, which an outer
    # handler would then turn into silent, total candidate loss.
    evidence = {
        project: sources.recent_observations(conn, project, RECENT_EVIDENCE)
        for project in by_project
    }

    def run(project: str, cands: list[dict]) -> list[dict]:
        recent = evidence.get(project, [])
        out: list[dict] = []
        for i in range(0, len(cands), VERIFY_BATCH):
            batch = cands[i:i + VERIFY_BATCH]
            prompt = (VERIFY_PROMPT
                      + "CANDIDATES:\n" + json.dumps(batch, ensure_ascii=False)
                      + "\n\nRECENT OBSERVATIONS:\n"
                      + "\n".join(f"{r['title']} / {r['subtitle']}" for r in recent))
            try:
                out.extend(call(prompt, model))
            except Exception as e:  # noqa: BLE001
                log(f"verify {project} batch failed ({type(e).__name__}); keeping batch")
                out.extend(batch)  # fail toward visibility, never silent loss
        return out

    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
        futures = {pool.submit(run, p, c): (p, c) for p, c in by_project.items()}
        for fut, (project, cands) in futures.items():
            try:
                results.extend(fut.result())
            except Exception as e:  # noqa: BLE001
                # Same rule as the batch handler: an unverified candidate is a
                # triage problem, a dropped one is invisible forever.
                log(f"verify {project} failed ({type(e).__name__}); keeping {len(cands)}")
                print(f"  verify {project}: failed ({type(e).__name__}) — keeping unverified")
                results.extend(cands)
    return results


def _to_items(verified: list[dict], obs_index: dict) -> list[Item]:
    today = time.strftime("%Y-%m-%d")
    out: list[Item] = []
    for cand in verified:
        sids = sorted({s for s in cand.get("source_ids", []) if isinstance(s, int)})
        if not sids:
            continue
        project = _project_of(sids, obs_index)
        rows = [obs_index[s] for s in sids if s in obs_index]
        newest = max((r["epoch"] for r in rows), default=None)
        sensitive = any(r["type"] in sources.SENSITIVE_TYPES for r in rows)
        theme = str(cand.get("topic", "")).strip() or "general"
        try:
            out.append(core.validate({
                "id": claude_mem_id(sids),
                "topic": f"{project} / {theme}",
                "project": project,
                "text": str(cand.get("text", "")).strip(),
                "source": "claude_mem",
                "source_ids": sids,
                "newest_source_epoch": newest,
                "first_seen": today,
                "sensitive": sensitive,
            }))
        except core.StoreError as e:
            log(f"candidate rejected: {e}")
    return out
