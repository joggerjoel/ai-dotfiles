"""HTML views.

A view is a registry entry -- (title, filter, sort, grouping) over the same
item list -- so adding one is a config line, not a new code path.

Every interpolated field goes through html.escape: item text originates in
arbitrary observation content, and these pages are opened over file://, where
injected markup executes with local-file read.
"""

from __future__ import annotations

import html
import shutil
import time
from pathlib import Path

from .core import STORE_DIR, CLOSED_STATUSES, Item, slug

FULL_PAGE_SIZE = 100
STALE_DAYS = 30
LATEST_DAYS = 14

CSS = """\
:root {
  --bg: #fbfbfa; --fg: #1c1c1a; --muted: #6b6b66; --line: #e4e4e0;
  --open: #b45309; --closed: #4d7c0f; --accent: #1d4ed8; --sensitive: #9333ea;
}
@media (prefers-color-scheme: dark) {
  :root { --bg: #16161a; --fg: #e8e8e4; --muted: #9a9a94; --line: #2c2c31;
          --open: #f59e0b; --closed: #a3e635; --accent: #93c5fd; --sensitive: #d8b4fe; }
}
* { box-sizing: border-box; }
body { margin: 0; padding: 2.5rem 1.5rem 5rem; background: var(--bg); color: var(--fg);
  font: 15px/1.6 ui-sans-serif, -apple-system, "Segoe UI", sans-serif;
  max-width: 62rem; margin-inline: auto; }
h1 { font-size: 1.5rem; margin: 0 0 .25rem; letter-spacing: -.02em; }
h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .08em;
  color: var(--muted); margin: 2.5rem 0 .75rem; font-weight: 600; }
.meta { color: var(--muted); font-size: .85rem; margin-bottom: 2rem; }
nav { display: flex; flex-wrap: wrap; gap: .25rem; margin-bottom: 2.5rem;
  border-bottom: 1px solid var(--line); padding-bottom: .75rem; }
nav a { padding: .3rem .7rem; border-radius: 6px; text-decoration: none;
  color: var(--muted); font-size: .9rem; }
nav a:hover { background: var(--line); color: var(--fg); }
nav a.on { background: var(--fg); color: var(--bg); }
table { width: 100%; border-collapse: collapse; }
td { padding: .55rem .5rem; border-bottom: 1px solid var(--line); vertical-align: top; }
tr:hover td { background: color-mix(in oklab, var(--line) 45%, transparent); }
td.id { font-family: ui-monospace, SFMono-Regular, monospace; font-size: .8rem;
  color: var(--muted); white-space: nowrap; width: 5.5rem; }
td.n { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap;
  width: 4.5rem; color: var(--muted); font-size: .9rem; }
a { color: var(--accent); }
.dot { display: inline-block; width: .5rem; height: .5rem; border-radius: 50%;
  margin-right: .5rem; vertical-align: middle; }
.dot.open { background: var(--open); } .dot.closed { background: var(--closed); }
.tag { font-size: .7rem; padding: .1rem .4rem; border-radius: 4px;
  border: 1px solid var(--sensitive); color: var(--sensitive); margin-left: .5rem; }
.empty { color: var(--muted); font-style: italic; padding: 2rem 0; }
.path { color: var(--muted); font-size: .8rem; font-family: ui-monospace, monospace; }
footer { margin-top: 4rem; color: var(--muted); font-size: .8rem;
  border-top: 1px solid var(--line); padding-top: 1rem; }
"""

VIEWS = [
    ("index.html", "Summary"),
    ("full.html", "All open"),
    ("latest.html", "Latest"),
    ("stale.html", "Stale"),
    ("closed.html", "Closed"),
]


def _now_ms() -> int:
    return int(time.time() * 1000)


def _nav(current: str, depth: int = 0) -> str:
    up = "../" * depth
    links = "".join(
        f'<a href="{up}{href}" class="{"on" if href == current else ""}">{html.escape(label)}</a>'
        for href, label in VIEWS
    )
    return f"<nav>{links}</nav>"


def _page(title: str, current: str, body: str, depth: int = 0, subtitle: str = "") -> str:
    up = "../" * depth
    stamp = time.strftime("%Y-%m-%d %H:%M", time.localtime())
    return (
        "<!doctype html><html lang=en><head><meta charset=utf-8>"
        '<meta name=viewport content="width=device-width,initial-scale=1">'
        f"<title>{html.escape(title)}</title>"
        f'<link rel=stylesheet href="{up}style.css"></head><body>'
        f"<h1>{html.escape(title)}</h1>"
        f'<p class=meta>{html.escape(subtitle or "")} · generated {stamp}</p>'
        f"{_nav(current, depth)}{body}"
        f"<footer>global-todo · read-only · close items with "
        f"<code>global-todo done &lt;id&gt;</code></footer>"
        "</body></html>"
    )


def _rows(items: list[Item], show_project: bool = False) -> str:
    if not items:
        return '<p class=empty>Nothing here.</p>'
    out = ["<table>"]
    for i in items:
        tag = '<span class=tag>sensitive</span>' if i.sensitive else ""
        extra = ""
        if i.path:
            steps = f" · {i.remaining_steps} open steps" if i.remaining_steps else ""
            extra = f'<br><span class=path>{html.escape(i.path)}{html.escape(steps)}</span>'
        proj = f'<br><span class=path>{html.escape(i.topic)}</span>' if show_project else ""
        out.append(
            f'<tr><td class=id>{html.escape(i.id)}</td>'
            f"<td>{html.escape(i.text)}{tag}{proj}{extra}</td></tr>"
        )
    out.append("</table>")
    return "".join(out)


def render_all(items: list[Item], outdir: Path = STORE_DIR) -> dict:
    """Regenerate every page. Returns counts for the caller to report."""
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "style.css").write_text(CSS)

    open_items = [i for i in items if i.is_open()]
    closed_items = [i for i in items if i.status in CLOSED_STATUSES]

    projects: dict[str, list[Item]] = {}
    for i in items:
        projects.setdefault(i.project, []).append(i)

    # --- summary -----------------------------------------------------------
    rows = ["<table>"]
    for proj in sorted(projects, key=lambda p: (-sum(1 for i in projects[p] if i.is_open()), p)):
        group = projects[proj]
        o = sum(1 for i in group if i.is_open())
        c = sum(1 for i in group if i.status in CLOSED_STATUSES)
        rows.append(
            f'<tr><td><a href="projects/{slug(proj)}.html">{html.escape(proj)}</a></td>'
            f'<td class=n><span class="dot open"></span>{o}</td>'
            f'<td class=n><span class="dot closed"></span>{c}</td></tr>'
        )
    rows.append("</table>")
    sub = f"{len(open_items)} open · {len(closed_items)} closed · {len(projects)} projects"
    (outdir / "index.html").write_text(
        _page("Global TODO", "index.html", "".join(rows), subtitle=sub)
    )

    # --- all open, paginated ----------------------------------------------
    pages = max(1, -(-len(open_items) // FULL_PAGE_SIZE))
    for p in range(pages):
        chunk = open_items[p * FULL_PAGE_SIZE:(p + 1) * FULL_PAGE_SIZE]
        body = _rows(chunk, show_project=True)
        if pages > 1:
            nav = " ".join(
                f'<a href="{"full.html" if n == 0 else f"full-{n + 1}.html"}">{n + 1}</a>'
                if n != p else f"<strong>{n + 1}</strong>"
                for n in range(pages)
            )
            body += f"<p class=meta>Page {p + 1} of {pages} — {nav}</p>"
        name = "full.html" if p == 0 else f"full-{p + 1}.html"
        (outdir / name).write_text(
            _page("All open items", "full.html", body,
                  subtitle=f"{len(open_items)} open")
        )

    # --- latest ------------------------------------------------------------
    cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - LATEST_DAYS * 86400))
    latest = [i for i in open_items if i.first_seen >= cutoff]
    (outdir / "latest.html").write_text(
        _page("Latest", "latest.html", _rows(latest, True),
              subtitle=f"first seen in the last {LATEST_DAYS} days")
    )

    # --- stale -------------------------------------------------------------
    # 30 days, not 90: at 90 this page could not select the 34-day-dormant
    # redlayer case that motivated building it.
    stale_before = _now_ms() - STALE_DAYS * 86400 * 1000
    stale = sorted(
        [i for i in open_items
         if i.newest_source_epoch and i.newest_source_epoch < stale_before],
        key=lambda i: i.newest_source_epoch or 0,
    )
    (outdir / "stale.html").write_text(
        _page("Stale", "stale.html", _rows(stale, True),
              subtitle=f"no source activity in {STALE_DAYS}+ days — likely already resolved")
    )

    # --- closed ------------------------------------------------------------
    closed_sorted = sorted(closed_items, key=lambda i: i.closed_at or "", reverse=True)
    (outdir / "closed.html").write_text(
        _page("Closed", "closed.html", _rows(closed_sorted, True),
              subtitle=f"{len(closed_items)} closed")
    )

    # --- per project, swapped atomically ----------------------------------
    staging = outdir / "projects.tmp"
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    for proj, group in projects.items():
        o = [i for i in group if i.is_open()]
        c = [i for i in group if i.status in CLOSED_STATUSES]
        body = _rows(o)
        if c:
            body += (f"<h2>Closed ({len(c)})</h2>"
                     + _rows(sorted(c, key=lambda i: i.closed_at or "", reverse=True)))
        (staging / f"{slug(proj)}.html").write_text(
            _page(proj, "index.html", body, depth=1,
                  subtitle=f"{len(o)} open · {len(c)} closed")
        )
    final = outdir / "projects"
    old = outdir / "projects.old"
    if final.exists():
        final.replace(old)
    staging.replace(final)
    if old.exists():
        shutil.rmtree(old)

    return {"open": len(open_items), "closed": len(closed_items),
            "projects": len(projects), "pages": pages + 4 + len(projects)}
