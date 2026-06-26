---
name: responsive-audit
description: Use when running a mobile/responsive audit on any web app — captures every page at iPhone SE / iPhone 13 / iPad / Desktop via agent-browser, runs an in-page overflow/affordance probe, generates a before/after audit doc, and builds a single shareable cloud-viewable comparison page hosted in the app's own public dir. Trigger on phrases like "mobile audit", "responsive audit", "test every page on mobile", "find responsive bugs", or "compare before/after at mobile widths".
---

# /responsive-audit

End-to-end workflow for finding and fixing mobile/responsive bugs on any web app, with a cloud-viewable before/after page so reviewers don't need to clone or run anything locally.

> This is the **global methodology**. Each project should layer a companion file at `.claude/skills/responsive-audit.md` with its specific route list, viewport priorities, auth pattern, and output paths. Both compose.

## Why this exists

Without this skill the loop is: capture screenshots manually → eyeball them → ship a patch → hope it stuck. With it, every audit produces:

1. A reproducible probe that catches the actual bugs (overflow, off-viewport CTAs, scroll-affordance gaps)
2. A static cloud-viewable comparison page anyone on the team can review from their phone
3. An E2E suite that prevents the same class of regression from coming back

## When to invoke

- User reports a mobile bug ("X is broken on iPhone")
- About to ship a UI change that could affect responsive behavior
- Before a major release — sweep every page once at every viewport
- Periodic baselining (monthly?) to catch slow drift

## The five phases

### Phase 1 — Snapshot the broken state

Use [agent-browser](agent-browser:agent-browser) (skill `agent-browser:agent-browser`) to capture every page at every target viewport BEFORE making any code changes.

```bash
# Spin up a named session at the target viewport
agent-browser --session audit set viewport 375 667
agent-browser --session audit open <BASE_URL>/login
agent-browser --session audit wait --load networkidle
agent-browser --session audit snapshot -i  # get refs for the login form

# Programmatic login (use your project's test creds)
agent-browser --session audit fill @e_email "$TEST_EMAIL"
agent-browser --session audit fill @e_pass  "$TEST_PASSWORD"
agent-browser --session audit click @e_submit
agent-browser --session audit wait --url "**/dashboard|**/overview|**/home"

# Sweep every route at iPhone SE
for r in "${ROUTES[@]}"; do
  agent-browser --session audit open "<BASE_URL>/$r"
  agent-browser --session audit wait --load networkidle
  agent-browser --session audit wait 1000
  agent-browser --session audit screenshot ".audit/screenshots/se-${r//\//-}.png"
done

# Repeat at iPhone 13 (390x844), iPad Mini (768x1024), Desktop (1280x800)
```

Save screenshots to `.audit/screenshots/` (gitignored — see [references/gitignore-pattern.md](references/gitignore-pattern.md)).

### Phase 2 — Run the in-page probe

The probe (loaded into the page via `agent-browser eval`) returns structured data on three failure modes:

1. **`docOverflow`** — pixels the document exceeds the viewport width. > 2px is a real bug.
2. **`offenders`** — interactive elements (button, link, role=button, input, select) whose right edge is past the viewport edge. **Excludes** elements inside intentional `overflow-x: auto/scroll` containers and `[role=dialog]` portals.
3. **`unannouncedScrollers`** — `overflow-x: auto/scroll` containers with off-screen content but no `aria-roledescription` and no sibling fade-gradient indicator. This is the class of bug that makes a scroll-strip "look broken" because text clips mid-word with no scroll hint.

Probe source: [references/probe.js](references/probe.js). Invoke per route:

```bash
SCRIPT=$(cat <path-to-probe.js>)
for r in "${ROUTES[@]}"; do
  agent-browser --session audit open "<BASE_URL>/$r"
  agent-browser --session audit wait 1000
  result=$(agent-browser --session audit eval "$SCRIPT" --json)
  echo "$result" >> .audit/findings.json
done
```

### Phase 3 — Write the audit doc

For each finding group by severity:

- **SEV-1** — visible bug that breaks the layout (overflow, off-viewport CTA, content overlap)
- **SEV-2** — degraded but functional (cramped headers, awkward chip wrap, dense grids)
- **SEV-3** — edge cases at specific widths

For each bug record: page, file path with line numbers, screenshot reference, what's wrong, and the **pattern** (so you fix it once for the whole codebase, not once per page).

Common recurring patterns to look for:

| Pattern | Symptom | Fix |
|---|---|---|
| `flex justify-between` with no wrap on card/page headers | Right action group bleeds off card | `flex-col gap-3 sm:flex-row sm:items-center sm:justify-between` + `flex-wrap` on action group + `min-w-0` on title block |
| `truncate` on stat-card labels | "Active Age…" | `line-clamp-2`; cards stay aligned via grid `items-stretch` |
| `overflow-x-auto` tab bar with no fade | Mid-word clipping looks broken | Layer fade gradients on either edge when scrollable + `aria-roledescription` |
| Redundant filter UI on mobile | Desktop tabs visible alongside mobile chip rows | Wrap the desktop variant in `hidden sm:block` |
| Long auto-generated IDs in card titles | `"Widget 1778243…"` ellipsized | Display ID as separate metadata, not concatenated into name |

### Phase 4 — Fix + verify

Apply fixes, then re-run Phase 1 + Phase 2 capturing into a sibling `.audit/screenshots/after/` directory. Diff visually + re-run the probe to confirm clean.

Update the project's design-system skill with any new patterns you established so future devs follow them automatically.

### Phase 5 — Generate the cloud viewer + commit

Copy `before/` + `after/` screenshots into the app's public dir (e.g. `apps/<app>/public/_dev/audits/<slug>/img/`) and generate a single HTML page that:

1. Lists each bug with before/after side-by-side at iPhone SE
2. Mounts live iframes at iPhone SE / 13 / iPad / Full on click (same-origin iframes inherit the user's session, so they render the real app at that viewport)
3. Links to file paths + explanations
4. Lives behind the same auth gate as the rest of the app

Template: [references/viewer-template.html](references/viewer-template.html). Customize the per-bug sections; image paths must be absolute (`/_dev/audits/<slug>/img/...`) so they resolve correctly whether the user hits `/_dev/audits/<slug>` or `/dev/audits/<slug>` (via rewrite).

Add a Next.js rewrite for a clean URL:

```ts
// next.config.ts
async rewrites() {
  return [
    { source: "/dev/audits/<slug>", destination: "/_dev/audits/<slug>/index.html" },
  ];
}
```

Push the branch → Vercel auto-deploys → share the preview URL + `/dev/audits/<slug>` path.

## Decision tree

```
Is this a "find what's broken" task?
- Yes → run Phase 1+2 to baseline, then write audit doc (Phase 3)
- No, I know what's broken → skip to Phase 4

After fixing, do I need to share results?
- Reviewer on a different machine / wants mobile inspection → Phase 5 (cloud viewer)
- Just commit → skip Phase 5, audit doc is enough

Should I add E2E coverage?
- Yes if the same bug class could regress → add a Playwright probe spec
- Skip if it's a one-off layout tweak that's content-specific
```

## Outputs

A standard audit produces these artifacts:

```
.audit/                                         # gitignored — work product
  screenshots/<viewport>-<route>.png            # raw captures, before
  screenshots/after/<viewport>-<route>.png      # raw captures, after
  findings.json                                 # raw probe output, before
  findings-after.json                           # raw probe output, after
  AUDIT.md                                      # written audit doc

apps/<app>/public/_dev/audits/<slug>/           # cloud viewer (committed)
  index.html
  img/before-<page>-<viewport>.png
  img/after-<page>-<viewport>.png

apps/<app>/tests/e2e/responsive/                # E2E coverage (committed)
  _config.ts
  _probe.ts
  auth.setup.ts
  probe.spec.ts
  visual.spec.ts (optional — public routes only, dynamic content breaks pixel diff)
```

## References

- [references/probe.js](references/probe.js) — the in-page audit probe
- [references/viewer-template.html](references/viewer-template.html) — cloud viewer HTML template
- [references/playwright-probe-spec.ts](references/playwright-probe-spec.ts) — Playwright probe-spec template
- [references/gitignore-pattern.md](references/gitignore-pattern.md) — what to gitignore vs commit

## Anti-patterns

- **Don't** patch each bug in isolation — most cluster into 2-3 recurring patterns. Fix the pattern at the component layer.
- **Don't** pixel-diff data-driven dashboard pages — content shifts between runs, false positives train you to ignore failures. Reserve pixel-diff for static auth pages.
- **Don't** silently hide content at narrow widths to "fix" overflow. Either it's important (mobile-stack it) or it isn't (delete it).
- **Don't** rely on `overflow-x: auto` alone for affordance — pair with `aria-roledescription` and/or visible fade gradients so users (and screen readers) know they can scroll.
