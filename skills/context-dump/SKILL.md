---
name: context-dump
description: Capture all open browser tabs (Safari, Chrome, Arc, Brave, Edge) into a dated, insightfully-organized markdown file at ~/Documents/Context-Dumps/YYYY-MM-DD_<browser>-tabs.md so the user can close their browser windows with confidence. Use whenever the user says "dump my tabs", "tab triage", "too many tabs open", "save my context", "clear my safari/chrome", "organize my tabs", "context dump", "i have too many windows open", "help me close tabs", or describes feeling overwhelmed by open tabs/windows. Designed specifically for ADHD task offloading — produces a thematically clustered document with duplicate detection, cross-cluster connections, and "force a decision" / "research-as-procrastination" callouts, not just a flat URL list. Trigger this even when the user doesn't explicitly say "skill" or "context-dump" — recognize the underlying intent of "I need to clear my browser without losing what I was working on."
---

# Context Dump

## What this skill does

Extracts every open tab from the user's browser, then writes a richly-organized markdown file to `~/Documents/Context-Dumps/YYYY-MM-DD_<browser>-tabs.md` so the user can close their browser without losing their mental context.

The output is **never just a flat URL list**. It is structured so that someone with ADHD — or anyone with 100+ tabs from parallel investigations — can scan it in 60 seconds and decide what to act on, what to bookmark, and what to close.

## When to use

Trigger when the user expresses any of these underlying intents:

- "I have too many tabs/windows open"
- "Help me clear Safari/Chrome/Arc"
- "Dump my tabs / tab triage / context dump"
- "Save what I'm working on so I can close everything"
- General overwhelm signals around browser state

Do not require the user to explicitly invoke the skill. If the intent matches, run the workflow.

## Workflow

### Step 1 — Pick the browser

If the user named a browser, use that. Otherwise run the extraction script with no argument; it auto-detects the frontmost browser via System Events.

Supported: `safari`, `chrome`, `arc`, `brave`, `edge`. (Firefox doesn't expose tabs to AppleScript reliably — if the user is on Firefox, ask them to export tabs via an extension and paste, or use a different approach.)

### Step 2 — Extract tabs

Run the bundled extractor. It outputs window markers + pipe-delimited TAB rows to stdout.

```bash
~/.claude/skills/context-dump/scripts/extract-tabs.sh [browser] > /tmp/tabs.txt
```

Format:

```
===WINDOW 1 (8 tabs)===
TAB|<window_idx>|<tab_idx>|<title>|<url>
TAB|...
===WINDOW 2 (25 tabs)===
...
```

Read `/tmp/tabs.txt` with the Read tool to bring it into context for analysis.

### Step 3 — Analyze (don't skip this — this is the value)

The point of this skill is the **analysis**, not the extraction. After reading the tabs, do these passes:

**(a) Find recurring tabs** — same URL across multiple windows. These are usually "I keep opening a new window" muscle memory, not 15 separate intentions. Build a table.

**(b) Find adjacent duplicates** — same URL twice in the same window. These are even more clearly accidental.

**(c) Cluster by theme** — group tabs into 8–14 thematic clusters. Common patterns to look for:

- Live infrastructure / dashboards (admin panels the user forgot to close)
- Active client work
- A specific research thread (e.g. "evaluating auth providers") — these are often the **most valuable** to surface because they're unresolved decisions
- Active AI conversations (Claude.ai, ChatGPT, Grok)
- Personal research rabbit holes (wellness, esoteric, music)
- Failed/dead tabs ("Failed to open page", 404s, empty homepages)

**(d) Identify connections between clusters** — this is where the skill earns its keep. Look for non-obvious links: e.g. "the user's sacred-geometry tabs and their BasedAI tabs share the same 64-tetrahedron iconography" or "the auth research connects to the SigmaOS dashboards because that's the app needing auth." Surface these explicitly. They are often the hidden through-line of a research session.

**(e) Spot decision-fatigue patterns** — when the user has 5+ tabs open evaluating the same kind of tool (auth providers, LLM gateways, hosting platforms), they have an unresolved decision. Call this out with a "💡 Action: force a decision" callout.

**(f) Spot research-as-procrastination patterns** — when one cluster has 20+ tabs of incremental searches on the same wellness/spiritual/biohacking topic, the user is using research to avoid commitment. Call this out gently with a "💡 Insight: pick ONE protocol/concept and try it before opening 30 more tabs."

### Step 4 — Write the markdown file

Path: `~/Documents/Context-Dumps/YYYY-MM-DD_<browser>-tabs.md` (always dated, browser in filename).

Create the folder if it doesn't exist: `mkdir -p ~/Documents/Context-Dumps`.

Use the structure in the **Output Template** section below. Stick to it — this is what makes the document scannable.

### Step 5 — Report back

End your response by:

1. Confirming the file path
2. Naming the top 1–3 patterns you found (e.g. "the same Gmail thread is open in all 15 windows", "you have an unresolved auth decision across 3 windows")
3. Asking if they want the workflow saved as memory for next time, or if they want help with one of the open decisions surfaced

**Do not** offer to close their tabs for them unless they ask. The whole point is they decide.

## Output Template

Use this structure exactly. Heading levels matter — they let the user collapse sections in their editor.

```markdown
# <Browser> Tab Dump — YYYY-MM-DD

> **Captured:** YYYY-MM-DD HH:MM TZ
> **Source:** <Browser> (<N> windows, <N> tabs)
> **Purpose:** Context offload to clear working memory — close <browser> with confidence after reviewing this.

---

## TL;DR — What This Session Actually Was

[2–4 sentences. Not "you had X tabs open" — instead, name the parallel investigations the user was running. E.g. "You had four parallel investigations going: (1) a side project's infra, (2) auth-provider evaluation, (3) AI agent orchestration research, (4) personal wellness research. Plus one email thread open in every window — that's window-creation muscle memory, not 15 intentions."]

**Biggest insight:** [the single most useful pattern you found]

---

## 🔁 Recurring Tabs (Open Once, Close N-1)

[Table of URLs that appear in multiple windows. Columns: Tab | Appears In | Action.
Include adjacent-in-same-window duplicates with "(×2 adjacent!)" notation.]

---

## 🧭 Cluster 1: <Theme Name>

[Brief 1-line description of what this cluster represents.]

[Optional sub-groupings if the cluster is large.]

- [Tab title](url) — optional inline note
- [Tab title](url)

> **💡 Action:** [If applicable — what to do with this cluster]
> **💡 Insight:** [If applicable — non-obvious pattern]

## 🧭 Cluster 2: ...

[Repeat for each cluster.]

---

## ⚠️ Failed / Stale Tabs (Just Close)

- "Failed to open page" × N
- 404 errors
- Empty homepages (github.com, youtube.com with no path) × N

---

## 📋 Recommended Workflow Going Forward

[3–6 ADHD-friendly bullets — Tab Groups suggestion, decision-forcing for open loops, research-as-procrastination check, etc.]

---

## 📊 Stats

- **Total tabs:** N
- **Windows:** N
- **Most-duplicated tab:** <name> (N instances)
- **Adjacent duplicates:** N cases
- **Failed/dead tabs:** N
- **Live infra dashboards:** ~N
- **Research/exploration tabs:** ~N
```

## Writing voice

The document is for one human, often with ADHD, often a little overwhelmed. Voice principles:

- **Validate first, then suggest.** "You had four parallel investigations" beats "you have too many tabs."
- **Insightful, not preachy.** Don't lecture. Surface a pattern and trust them.
- **Specific over generic.** "ZITADEL is the most-enterprise option, Better Auth is the most-revisited" beats "you should pick one."
- **Use callouts sparingly.** A `💡 Action` box with no real action is noise. Only flag the patterns that genuinely matter.
- **Connect the dots they may not have seen.** This is the highest-value content. "The sacred-geometry tabs and BasedAI's Brain Mint use the same 64-tetrahedron iconography — there's a real thread here, not noise" is the kind of observation that makes the document valuable.

## Why this skill exists

Tab overload is a symptom, not the problem. The real problem is that **a browser session is a working-memory cache** for parallel investigations, and closing it without externalizing the cache feels like losing context. This skill externalizes the cache in a form that is denser and more useful than the tabs themselves were — so closing the browser becomes a relief rather than a loss.

The dated filename is non-negotiable: it lets the user accumulate a low-effort longitudinal record of what they were thinking about. Three months from now they can grep `~/Documents/Context-Dumps/` for "auth" and recover the exact context they had.

## Edge cases & notes

- **Local files / `file://` URLs**: include them. They're often SOW templates, drafts, etc. that matter.
- **`localhost:` URLs**: cluster as "Local Dev (Probably Stale)" — they're almost always dead.
- **Search-engine result tabs**: include the search query verbatim — it shows what the user was researching.
- **Chat session URLs (claude.ai, chatgpt.com, x.com/grok)**: these often have no useful title. Pull a hint from the URL or just label "untitled chat" and group them under "Active AI Conversations."
- **Very large sessions (300+ tabs)**: don't truncate. The whole point is completeness. The clustering makes it scannable regardless of size.
- **Empty homepages** (`https://github.com/`, `https://www.youtube.com/`): always go in the "Failed / Stale" section — they carry no information.

## Folder convention

`~/Documents/Context-Dumps/` is shared across browsers and other context-offload tasks (terminal sessions, Claude conversations, etc.). Filenames are always:

- `YYYY-MM-DD_<source>-tabs.md` for browser dumps
- `YYYY-MM-DD_<source>.md` for other context types

If a file already exists for today, append a time suffix: `YYYY-MM-DD_HHMM_<source>-tabs.md`.
