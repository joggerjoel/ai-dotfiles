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
You are verifying whether candidate work items are STILL OPEN, and whether any
of them duplicate work already tracked.

CANDIDATES (JSON) were extracted from older observations. RECENT OBSERVATIONS
are the newest activity in this project. EXISTING are items already tracked and
still open, each with an id.

An item is RESOLVED if the recent observations show the work was completed,
superseded, or abandoned.

Rules:
- Return only candidates that are STILL OPEN.
- If a candidate describes the SAME piece of work as an EXISTING item, set
  "merge_into" to that item's id instead of returning it as new. Judge by
  meaning, not wording: "Fix missing stop hook scripts" and "Create two missing
  stop hook scripts" are the same work.
- Merge candidates describing facets of one piece of work into one item,
  carrying the UNION of their source_ids. Never drop a source_id.
- Keep text imperative and <=120 chars.
- When the recent observations say nothing about a candidate, KEEP it.
- Only ever merge into an id listed under EXISTING. Never invent one.

Output STRICT JSON only. Schema:
[{"topic":"...","text":"...","source_ids":[1,2],"merge_into":"<id or null>"}]

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

    # One transaction, then the connection is gone. No database handle exists
    # from here on, so no thread can touch one.
    watermark = 0 if args.cold_start else state.get("watermark_epoch", 0)
    snap = sources.take_snapshot(watermark, recent_limit=RECENT_EVIDENCE)
    rows = snap.rows
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

    obs_index = snap.index()
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

    existing_by_project: dict[str, list[Item]] = {}
    for it in items:
        existing_by_project.setdefault(it.project, []).append(it)

    verified = _verify(staged, obs_index, snap.recent_by_project, model,
                       existing_by_project)
    verified, n_merged = apply_merges(items, verified)
    if n_merged:
        print(f"claude-mem: {n_merged} candidate(s) merged into existing items")
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


def _keep_unverified(project: str, cands: list[dict], exc: Exception,
                     where: str) -> list[dict]:
    """The single failure policy for verification: never drop on error.

    Verification's job is to REMOVE candidates, so any error inside it is
    indistinguishable from "the model said these are resolved" unless the
    failure path is explicitly the other way. An unverified candidate is a
    triage problem you can see; a dropped one is invisible forever.

    This exists as one named function because the bug it prevents was caused
    by having two handlers with opposite policies: the inner one kept the
    batch, the outer one dropped it, and the outer one is the one that fired.
    Every failure path in _verify routes through here. Do not add another.
    """
    log(f"verify {project} {where} failed ({type(exc).__name__}); "
        f"keeping {len(cands)} unverified")
    print(f"  verify {project}: {type(exc).__name__} in {where} "
          f"— keeping {len(cands)} unverified", flush=True)
    return list(cands)


def apply_merges(items: list[Item], verified: list[dict]) -> tuple[list[dict], int]:
    """Fold `merge_into` decisions into existing records.

    Returns (candidates that are genuinely new, merge count).

    Token-overlap dedupe cannot close this gap. On the live store, Jaccard at
    the configured 0.7 matched zero pairs out of 172 open items, while three
    separate records described one piece of stop-hook work -- scoring 0.278
    against each other, below even a 0.4 threshold. Short imperative sentences
    reworded by a model share too few tokens. Meaning has to be judged by
    something that understands meaning.

    Safety: only OPEN records were offered to the model, and a merge_into
    naming anything else is ignored rather than trusted. Merging into a closed
    record would hand the model a silent way to suppress new work.
    """
    open_by_id = {i.id: i for i in items if i.is_open()}
    fresh: list[dict] = []
    merged = 0

    for cand in verified:
        target_id = cand.get("merge_into")
        if not target_id or not isinstance(target_id, str):
            fresh.append(cand)
            continue
        target = open_by_id.get(target_id)
        if target is None:
            # Hallucinated or closed id: treat as new rather than dropping it.
            log(f"merge_into '{target_id}' is not an open record; keeping as new")
            fresh.append(cand)
            continue
        sids = [s for s in cand.get("source_ids", []) if isinstance(s, int)]
        target.source_ids = sorted(set(target.source_ids) | set(sids))
        # The record keeps its id and status, so a `done` set by the user is
        # never stranded by a later merge.
        merged += 1

    return fresh, merged


def _verify(staged: list[dict], obs_index: dict,
            recent_by_project: dict[str, list[dict]], model: str,
            existing_by_project: dict[str, list[Item]] | None = None) -> list[dict]:
    """One call per project over staged candidates plus recent evidence.

    The sweep is chunk-local and cannot see that an August observation
    resolved a July item. This is the only stage that sees a whole project.

    Takes pre-read evidence, never a database connection: this function owns a
    thread pool, and a live sqlite3 handle in its scope is the exact hazard
    that silently discarded every candidate once already.
    """
    by_project: dict[str, list[dict]] = {}
    dropped_no_ids = 0
    for cand in staged:
        sids = [s for s in cand.get("source_ids", []) if isinstance(s, int)]
        if not sids:
            dropped_no_ids += 1
            continue
        cand["source_ids"] = sids
        by_project.setdefault(_project_of(sids, obs_index), []).append(cand)

    if dropped_no_ids:
        # Loud, because this is a silent-loss path: a candidate with no usable
        # source_ids cannot be keyed, so it cannot enter the store at all.
        log(f"verify: {dropped_no_ids} candidate(s) had no usable source_ids")
        print(f"  verify: {dropped_no_ids} candidate(s) dropped — no source_ids",
              flush=True)

    if not by_project:
        return []
    print(f"verifying:  {len(by_project)} projects", flush=True)

    existing_by_project = existing_by_project or {}

    def run(project: str, cands: list[dict]) -> list[dict]:
        recent = recent_by_project.get(project, [])
        # Only open records are offered: a merge into a closed one would be a
        # silent suppression path.
        existing = [{"id": i.id, "text": i.text}
                    for i in existing_by_project.get(project, []) if i.is_open()]
        out: list[dict] = []
        for i in range(0, len(cands), VERIFY_BATCH):
            batch = cands[i:i + VERIFY_BATCH]
            prompt = (VERIFY_PROMPT
                      + "CANDIDATES:\n" + json.dumps(batch, ensure_ascii=False)
                      + "\n\nEXISTING:\n" + json.dumps(existing[:200], ensure_ascii=False)
                      + "\n\nRECENT OBSERVATIONS:\n"
                      + "\n".join(f"{r['title']} / {r['subtitle']}" for r in recent))
            try:
                out.extend(call(prompt, model))
            except Exception as e:  # noqa: BLE001
                out.extend(_keep_unverified(project, batch, e, "batch"))
        return out

    results: list[dict] = []
    with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
        futures = {pool.submit(run, p, c): (p, c) for p, c in by_project.items()}
        for fut, (project, cands) in futures.items():
            try:
                results.extend(fut.result())
            except Exception as e:  # noqa: BLE001
                results.extend(_keep_unverified(project, cands, e, "worker"))
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
