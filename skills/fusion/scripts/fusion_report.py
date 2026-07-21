#!/usr/bin/env python3
"""fusion_report.py <run-dir> — render a self-contained report.html for a fusion run.

Reads meta.json + agent artifacts written by fusion.sh. Stdlib only.
Sections: run header/stat table, side-by-side answer panels, fusion
consensus/divergence/discarded cards, auto-validate gate + round logs.
"""
import html
import json
import os
import re
import sys

d = sys.argv[1]
meta = json.load(open(os.path.join(d, "meta.json")))


def read(name):
    p = os.path.join(d, name)
    return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else ""


def esc(s):
    return html.escape(s or "")


def md_min(s):
    """Minimal markdown -> html: headings, bold, inline code, fenced code. Safe: escapes first."""
    s = esc(s)
    s = re.sub(r"```(\w*)\n(.*?)```", lambda m: f"<pre class=code>{m.group(2)}</pre>", s, flags=re.S)
    s = re.sub(r"^### (.+)$", r"<h4>\1</h4>", s, flags=re.M)
    s = re.sub(r"^## (.+)$", r"<h3>\1</h3>", s, flags=re.M)
    s = re.sub(r"^# (.+)$", r"<h3>\1</h3>", s, flags=re.M)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    s = re.sub(r"`([^`\n]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\[(ARCHITECT|BOTH)\]", r'<span class="tag arch">[\1]</span>', s)
    s = re.sub(r"\[(BUILDER)\]", r'<span class="tag build">[\1]</span>', s)
    return f'<div class="md">{s}</div>'


def split_fusion(text):
    """Split the fusion answer into its four contract sections."""
    parts = {}
    keys = ["Fused Result", "Consensus", "Divergence", "Discarded"]
    pat = re.compile(r"^##\s*(" + "|".join(keys) + r")\s*$", re.M | re.I)
    hits = list(pat.finditer(text))
    for i, m in enumerate(hits):
        end = hits[i + 1].start() if i + 1 < len(hits) else len(text)
        parts[m.group(1).title()] = text[m.end():end].strip()
    return parts


rows = ""
for a in meta.get("agents", []):
    tin = a.get("tokens_in") or (a.get("tokens_total") and f'{a["tokens_total"]} (total)') or "–"
    tout = a.get("tokens_out") or "–"
    cost = f'${a["cost"]:.4f}' if isinstance(a.get("cost"), (int, float)) else "–"
    ok = "✓" if a.get("rc") == 0 else f'rc={a.get("rc")}'
    rows += (f'<tr><td class="role">{esc(a["role"])}</td><td>{esc(a["engine"])}</td>'
             f'<td>{a.get("secs","–")}s</td><td>{tin}</td><td>{tout}</td><td>{cost}</td><td>{ok}</td></tr>')

panels = ""
if meta["command"] in ("opinion", "fuse"):
    a_txt, b_txt = read("architect.txt"), read("builder.txt")
    panels = f"""
<div class="cols">
  <div class="panel"><div class="ph arch">ARCHITECT · claude</div>{md_min(a_txt)}</div>
  <div class="panel"><div class="ph build">BUILDER · codex</div>{md_min(b_txt)}</div>
</div>"""

fusion_html = ""
if meta["command"] == "fuse":
    parts = split_fusion(read("fusion.txt"))
    fused = parts.get("Fused Result") or read("fusion.txt")
    cards = ""
    for key, cls in (("Consensus", "green"), ("Divergence", "amber"), ("Discarded", "red")):
        body = parts.get(key, "").strip() or "(none)"
        cards += f'<div class="card {cls}"><div class="ch">{key}</div>{md_min(body)}</div>'
    fusion_html = f"""
<h2>Fused result</h2><div class="panel">{md_min(fused)}</div>
<h2>Convergence analysis</h2><div class="cards">{cards}</div>"""

gate_html = ""
if meta["command"] == "autovalidate":
    gate = read("gate.sh")
    rounds = ""
    n = 0
    while os.path.exists(os.path.join(d, f"gate_round_{n}.log")):
        log = read(f"gate_round_{n}.log")
        passed = len(re.findall(r"^PASS", log, re.M))
        failed = len(re.findall(r"^FAIL", log, re.M))
        badge = "green" if failed == 0 and n > 0 else ("amber" if n == 0 else "red")
        label = "initial (pre-build)" if n == 0 else f"round {n}"
        rounds += (f'<div class="card {badge}"><div class="ch">Gate {label} — {passed} pass / {failed} fail</div>'
                   f'<pre class=code>{esc(log[:4000])}</pre></div>')
        n += 1
    status = meta.get("status", "?")
    gate_html = f"""
<h2>Acceptance gate <span class="tag {'arch' if status=='green' else 'build'}">status: {esc(status)}</span></h2>
<div class="panel"><pre class=code>{esc(gate)}</pre></div>
<h2>Gate runs</h2><div class="cards">{rounds}</div>"""

page = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>fusion · {esc(meta["command"])} · {esc(meta.get("created",""))}</title>
<style>
:root {{ --bg:#fff; --fg:#1a1a1a; --mut:#666; --line:#e2e2e2; --panel:#fafafa;
        --green:#e7f6ec; --greenb:#2e7d32; --amber:#fdf3e0; --amberb:#b26a00; --red:#fdecec; --redb:#c62828;
        --arch:#e8eefc; --archb:#2b5cad; --build:#f3e8fc; --buildb:#7b3fa9; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#141414; --fg:#e8e8e8; --mut:#999; --line:#333;
        --panel:#1d1d1d; --green:#12291a; --amber:#2b2213; --red:#2b1414; --arch:#16223a; --build:#251733; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.55 -apple-system,system-ui,sans-serif; max-width:1200px; margin:2rem auto; padding:0 1rem; }}
h1 {{ font-size:1.3rem }} h2 {{ font-size:1.05rem; margin-top:2rem }}
table {{ border-collapse:collapse; width:100%; font-size:.88rem }}
td,th {{ border:1px solid var(--line); padding:.35rem .6rem; text-align:left }}
.role {{ font-weight:600 }}
.cols {{ display:grid; grid-template-columns:1fr 1fr; gap:1rem; margin-top:1rem }}
@media (max-width:900px) {{ .cols {{ grid-template-columns:1fr }} }}
.panel {{ border:1px solid var(--line); border-radius:8px; background:var(--panel); padding:1rem; overflow-x:auto }}
.ph {{ font-weight:700; font-size:.8rem; letter-spacing:.05em; margin:-1rem -1rem 1rem; padding:.5rem 1rem; border-bottom:1px solid var(--line); border-radius:8px 8px 0 0 }}
.ph.arch {{ background:var(--arch); color:var(--archb) }} .ph.build {{ background:var(--build); color:var(--buildb) }}
.cards {{ display:grid; gap:1rem; margin-top:.5rem }}
.card {{ border:1px solid var(--line); border-left-width:5px; border-radius:8px; padding: .75rem 1rem; background:var(--panel) }}
.card.green {{ border-left-color:var(--greenb); background:var(--green) }}
.card.amber {{ border-left-color:var(--amberb); background:var(--amber) }}
.card.red   {{ border-left-color:var(--redb);   background:var(--red) }}
.ch {{ font-weight:700; margin-bottom:.4rem }}
.tag {{ font-size:.72rem; font-weight:700; padding:.05rem .4rem; border-radius:4px }}
.tag.arch {{ background:var(--arch); color:var(--archb) }} .tag.build {{ background:var(--build); color:var(--buildb) }}
pre.code {{ background:rgba(127,127,127,.12); border-radius:6px; padding:.6rem .8rem; overflow-x:auto; font-size:.82rem; white-space:pre-wrap }}
code {{ background:rgba(127,127,127,.15); border-radius:4px; padding:0 .25rem }}
.md {{ white-space:normal }} .prompt {{ color:var(--mut); white-space:pre-wrap }}
</style></head><body>
<h1>fusion · /{esc(meta["command"])} <span class="tag arch">{esc(meta.get("created",""))}</span></h1>
<p class="prompt">{esc(meta.get("prompt",""))}</p>
<table><tr><th>role</th><th>engine</th><th>wall</th><th>tokens in</th><th>tokens out</th><th>cost</th><th>rc</th></tr>{rows}</table>
{panels}{fusion_html}{gate_html}
</body></html>"""

out = os.path.join(d, "report.html")
open(out, "w", encoding="utf-8").write(page)
print(out)
