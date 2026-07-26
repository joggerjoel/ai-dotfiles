#!/usr/bin/env python3
"""Replay injection-guard over historical Claude Code transcripts.

Answers "what would this hook have done to me over the last N months" without
waiting out a soak. Run it after ANY change to the patterns, the extractor, or
the suppression rules — a change that looks like a small false-positive tweak can
silently gut detection, and this is the only check here that measures the guard
against real traffic instead of against hand-written fixtures.

    hooks/injection-guard.backtest.py            # summary + every hit
    hooks/injection-guard.backtest.py --quiet    # counts only

It imports the guard beside it and calls the SAME patterns, WATCHED set,
_text_of, and _is_self_reference that run in production. Do not reimplement any
of that logic here: a divergent copy measures the wrong thing, which has already
happened once (2026-07-26, a self-reference change appeared to have no effect
because this script still applied the old rule).

Reads only local transcripts under ~/.claude/projects. Nothing leaves the box.
"""
from __future__ import annotations

import importlib.util
import json
import sys
from collections import defaultdict
from pathlib import Path

QUIET = "--quiet" in sys.argv

# Importing the guard would otherwise drop a __pycache__ beside it — in the repo
# and, when run against the symlink, inside ~/.claude/hooks.
sys.dont_write_bytecode = True

# Import the sibling guard, so a backtest run measures the working tree you are
# about to ship — not whatever is currently symlinked into ~/.claude/hooks.
GUARD = Path(__file__).resolve().with_name("injection-guard.py")
if not GUARD.exists():
    sys.exit(f"guard not found beside this script: {GUARD}")
spec = importlib.util.spec_from_file_location("ig", GUARD)
ig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ig)

transcripts = sorted((Path.home() / ".claude" / "projects").glob("*/*.jsonl"))
if not transcripts:
    sys.exit("no transcripts under ~/.claude/projects — nothing to replay")

print(f"replaying {GUARD.name} ({len(ig.BLOCK_PATTERNS)} patterns) "
      f"over {len(transcripts)} transcripts…\n")

scanned = skipped = 0
hits: list[dict] = []
echoes: list[dict] = []
by_project: dict[str, int] = defaultdict(int)

for f in transcripts:
    calls: dict = {}          # tool_use_id -> (tool_name, arg_text, arg_dict)
    try:
        lines = f.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        continue

    for line in lines:
        try:
            rec = json.loads(line)
        except Exception:
            continue
        content = (rec.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue

        for blk in content:
            if not isinstance(blk, dict):
                continue

            if blk.get("type") == "tool_use":
                inp = blk.get("input") if isinstance(blk.get("input"), dict) else {}
                argtext = " ".join(str(v) for v in inp.values())
                calls[blk.get("id")] = (blk.get("name") or "", argtext, inp)

            elif blk.get("type") == "tool_result":
                name, argtext, inp = calls.get(blk.get("tool_use_id"), ("", "", {}))
                if name not in ig.WATCHED:
                    skipped += 1
                    continue
                text = ig._text_of(blk.get("content"))[:ig.MAX_SCAN]
                if not text.strip():
                    continue
                scanned += 1

                for pat in ig.BLOCK_PATTERNS:
                    m = pat.search(text)
                    if not m:
                        continue
                    row = {
                        "project": f.parent.name,
                        "tool": name,
                        "pattern": pat.pattern,
                        "excerpt": text[max(0, m.start() - 90):m.end() + 90].replace("\n", " "),
                    }
                    # Production suppression, called not copied.
                    if pat.search(argtext) or ig._is_self_reference(inp):
                        echoes.append(row)
                    else:
                        hits.append(row)
                        by_project[f.parent.name] += 1
                    break

rate = (len(hits) / scanned * 100) if scanned else 0.0
print(f"  tool_results scanned (watched)     : {scanned:,}")
print(f"  skipped (unwatched tool)           : {skipped:,}")
print(f"  HITS   (would warn in enforce)     : {len(hits)}")
print(f"  suppressed (echo / self-reference) : {len(echoes)}")
print(f"  hit rate                           : {rate:.4f}%")

if not hits:
    print("\n  No hits across the corpus.")
    sys.exit(0)

counts: dict[str, int] = defaultdict(int)
for h in hits:
    counts[h["pattern"]] += 1
print("\n  by pattern:")
for pat, n in sorted(counts.items(), key=lambda kv: -kv[1]):
    print(f"    {n:5d}  {pat}")

print("\n  by project:")
for proj, n in sorted(by_project.items(), key=lambda kv: -kv[1])[:10]:
    print(f"    {n:5d}  {proj[:70]}")

if QUIET:
    sys.exit(0)

print("\n  every hit — judge each as genuinely foreign content or a false positive:")
for h in hits[:40]:
    print(f"\n    [{h['tool']}] {h['project'][:60]}")
    print(f"      …{h['excerpt'][:200]}…")
if len(hits) > 40:
    print(f"\n    (+{len(hits) - 40} more)")
