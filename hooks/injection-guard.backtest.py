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
import os
import sys
from collections import defaultdict
from pathlib import Path

QUIET = "--quiet" in sys.argv
CHECK = "--check" in sys.argv      # compare to baseline, non-zero on drift
ACCEPT = "--accept" in sys.argv    # record current numbers as the new baseline
# Per-host, and deliberately OUTSIDE the repo. Each machine has its own transcript
# history, so a committed baseline is a number from someone else's corpus — it made
# every fleet host fail this check against a rate recorded on the laptop. Lives
# beside the log, which is already per-host and already gitignored by location.
BASELINE = Path(
    os.environ.get("INJECTION_GUARD_BASELINE")
    or Path.home() / ".claude" / "hooks" / ".logs" / "injection-guard.baseline.json"
)

# How far the hit rate may drift before a human has to look. Corpus grows as you
# work, so small movement is normal; a big move means the change altered what the
# guard sees. Downward is the dangerous direction — that is detection being lost.
TOLERANCE = 0.15  # relative

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
                if not ig._is_watched(name):
                    skipped += 1
                    continue
                text, _gap = ig._scan_windows(ig._text_of(blk.get("content")))
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
                    # Production suppression, called not copied. Echo suppression
                    # was removed as a second oracle — only path anchoring remains.
                    if ig._is_self_reference(inp):
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

if ACCEPT:
    # Store the matched payloads, not just the rate. The rate is a ratio over a
    # corpus that both grows (new sessions) and shrinks (Claude Code compacts
    # transcripts in place, so past records vanish from files that still exist).
    # A ratio over a mutable corpus cannot tell "detection regressed" apart from
    # "the corpus moved" — on 2026-08-28 it reported a 76.8% fall while the guard
    # was byte-identical to the version that recorded the baseline. Replaying the
    # stored payloads measures detection directly and is immune to corpus churn.
    #
    # These payloads are excerpts of real transcripts. The baseline lives outside
    # the repo, per-host, and must never be committed.
    BASELINE.parent.mkdir(parents=True, exist_ok=True)
    BASELINE.write_text(json.dumps({
        "rate": round(rate, 4),
        "hits": len(hits),
        "scanned": scanned,
        "payloads": [{"pattern": h["pattern"], "excerpt": h["excerpt"]} for h in hits],
    }, indent=2) + "\n")
    print(f"\n  baseline recorded: {rate:.4f}% ({len(hits)}/{scanned:,}) -> {BASELINE.name}")
    sys.exit(0)

if CHECK:
    if not BASELINE.exists():
        print(f"\n  NO BASELINE. Review the hits above, then record them:")
        print(f"    {Path(__file__).name} --accept")
        sys.exit(1)
    base = json.loads(BASELINE.read_text())
    prev = base.get("rate", 0.0)
    payloads = base.get("payloads")

    drift = abs(rate - prev) / prev if prev else (1.0 if rate else 0.0)
    r4 = round(rate, 4)
    arrow = "\u2192" if r4 == prev else ("\u2193" if r4 < prev else "\u2191")
    print(f"\n  baseline {prev:.4f}%  {arrow}  now {rate:.4f}%   "
          f"(drift {drift * 100:.1f}%, informational)")

    if payloads is None:
        # Pre-payload baseline. Its rate cannot distinguish a regression from
        # corpus churn, so it does not gate anything. Un-gated, not broken.
        print("\n  NO BASELINE payloads (recorded in the older rate-only format).")
        print(f"  Re-record to enable the regression check:  {Path(__file__).name} --accept")
        sys.exit(1)

    # The real check: every payload this guard caught before must still match.
    # Corpus churn cannot affect this — the payloads are frozen in the baseline.
    lost = []
    for item in payloads:
        text = item.get("excerpt", "")
        if not any(pat.search(text) for pat in ig.BLOCK_PATTERNS):
            lost.append(item)

    if lost:
        print(f"\n  \u2500\u2500 DETECTION LOST \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500")
        print(f"  {len(lost)} of {len(payloads)} recorded payloads no longer match any pattern.")
        print("  This is a real regression: the same bytes that tripped the guard")
        print("  before now pass it. Restore detection, or if the pattern was")
        print(f"  deliberately narrowed:  {Path(__file__).name} --accept")
        for item in lost[:10]:
            print(f"\n    was caught by: {item.get('pattern', '?')}")
            print(f"    excerpt: {item.get('excerpt', '')[:160]}")
        sys.exit(1)

    print(f"  all {len(payloads)} recorded payloads still detected.")
    if drift > TOLERANCE:
        # Worth a look, never a failure: the corpus moves on its own.
        print(f"  note: hit rate moved more than {TOLERANCE * 100:.0f}% — corpus churn,")
        print("  not a detection change (payload replay above is the real check).")
    sys.exit(0)

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
