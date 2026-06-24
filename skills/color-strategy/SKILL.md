---
name: color-strategy
description: Strategic color distribution for UI work. Enforces the 60/30/10 rule, OKLCH perceptual color scales, semantic color assignments (success/error/warning/info), and WCAG accessibility. Auto-invoke for any frontend work involving color decisions — new UIs, palette selection, theming, or when a design feels flat or generic. Skip if the project has a strict monotone design system that governs color via its own tokens (e.g. sigma-synapses).
---

# Color Strategy

A portable color framework for UI work. Covers distribution (60/30/10), generation (OKLCH), semantics, and accessibility. Use it to make color decisions intentional rather than instinctive.

## When to invoke

- New UI, page, or component where color choices haven't been made yet
- A design that feels flat, gray, or generic
- Choosing or extending a color palette
- Adding a new theme or brand variant
- Any task that uses the words: _color, palette, theme, brand, accent, tint, gradient, dark mode_

## When NOT to invoke

- The project has a strict monotone or token-driven design system that already governs color (check for a `design-system` skill or `DESIGN_SYSTEM.md` first — defer to it)
- You're only making structural/layout changes with no color decisions
- Color is explicitly out of scope for the task

---

## Step 1: Gather context first (mandatory)

Color without context produces generic AI slop. Before choosing a single hex value:

**Collect from the codebase or ask the user:**

| Context | Where to find it | Why it matters |
|---|---|---|
| Brand colors | `tailwind.config`, `globals.css`, `@theme`, design docs | Non-negotiable starting point |
| Target audience | README, product docs, existing copy tone | Age/culture/trust signals shape palette |
| Domain/industry | App type (finance, health, creative, B2B SaaS) | Finance = trust blues; health = greens; creative = latitude |
| Existing components | Current CSS, screenshots, component library | Can't clash with what's already there |
| Dark/light modes | Check theme tokens or `prefers-color-scheme` usage | Colors behave differently on dark backgrounds |

**If brand colors exist** → your palette is constrained. Derive the full system from them using OKLCH (see Step 3). Don't invent competing colors.

**If nothing exists** → ask one clarifying question: "What's the primary emotion this UI should evoke?" (trust, energy, calm, creativity). That anchors the hue.

---

## Step 2: Apply the 60/30/10 rule

Every color decision must fit one of three roles. Violating this produces visual noise.

```
60% — Dominant (base/neutral)
  The background, surfaces, cards. Usually a neutral or very subtle tint.
  Should feel invisible — it holds the space.

30% — Secondary
  Sections, sidebars, contrast areas. Adds depth without competing.
  One clear step away from dominant in lightness or hue.

10% — Accent
  CTAs, active states, highlights, key icons, data points.
  The color with the most saturation. Used sparingly — this is where
  the brand lives and where the eye goes.
```

**Common failure modes:**
- Two colors both fighting for the 10% slot → pick one, make the other 30%
- Accent used for 40% of the interface → it stops being an accent
- Dominant is pure white or pure black → add a 1-2% tint for warmth or coolness

---

## Step 3: Generate colors with OKLCH

OKLCH is the right color space for UI work. Equal lightness steps look equal to the human eye (unlike hex or HSL where L=50 can look very dark or very light depending on hue).

**Format:** `oklch(L% C H)` — Lightness (0–100%), Chroma (0–0.4), Hue (0–360°)

### Quick scale recipe (for any base hue)

```css
/* Brand hue: 220 (blue). Adjust C for saturation, keep L steps even. */
--color-50:  oklch(97% 0.01 220);  /* near-white tint — surfaces */
--color-100: oklch(93% 0.03 220);  /* light background */
--color-200: oklch(86% 0.06 220);  /* borders, dividers */
--color-300: oklch(76% 0.10 220);  /* disabled text, placeholders */
--color-400: oklch(65% 0.14 220);  /* secondary text */
--color-500: oklch(55% 0.18 220);  /* body text on light */
--color-600: oklch(45% 0.18 220);  /* primary accent */
--color-700: oklch(36% 0.16 220);  /* hover state */
--color-800: oklch(27% 0.12 220);  /* deep accent */
--color-900: oklch(18% 0.08 220);  /* near-black tint */
```

**Chroma guidance by use:**
- `0.01–0.03` → barely-tinted neutrals (surfaces, backgrounds)
- `0.06–0.10` → visible tint (borders, subtle fills)
- `0.14–0.20` → clear color (buttons, active states, icons)
- `0.25–0.35` → vivid (charts, data points, badges — use sparingly)

### Semantic color hues (cross-culturally reliable)

| State | Hue range | Example |
|---|---|---|
| Success | 140–165° (green) | `oklch(52% 0.18 145)` |
| Error | 15–30° (red-orange) | `oklch(52% 0.22 22)` |
| Warning | 60–80° (amber) | `oklch(72% 0.18 72)` |
| Info | 220–245° (blue) | `oklch(52% 0.16 230)` |
| Neutral | any hue at C < 0.04 | `oklch(50% 0.02 220)` |

---

## Step 4: Assign semantic color intentionally

Before adding color to any element, answer: **"What does this color communicate?"**

### State indicators (always semantic)
```tsx
// Never use brand color for error states — semantic always wins
<Badge className="bg-[oklch(95%_0.04_22)] text-[oklch(45%_0.20_22)]">Failed</Badge>
<Badge className="bg-[oklch(95%_0.04_145)] text-[oklch(40%_0.18_145)]">Active</Badge>
```

### Hierarchy indicators (use accent, not random colors)
- Primary CTA → accent (10%)
- Secondary CTA → secondary tint or outline
- Destructive action → semantic error color, not brand color

### Wayfinding (navigation, tabs, active states)
- Active = accent underline or background tint
- Hover = dominant + 5% darker, or accent at 10% opacity
- Focus ring = accent color, never hidden

---

## Step 5: Check accessibility

Every color pair must pass before shipping:

| Pair | Minimum contrast | Test |
|---|---|---|
| Body text on background | 4.5:1 (WCAG AA) | Required |
| Large text (18px+) on background | 3:1 (WCAG AA) | Required |
| UI component (border, icon) | 3:1 | Required |
| Decorative only | None | Allowed |

**OKLCH contrast shortcut:** If L values differ by ≥45 points (e.g., L=95 background, L=45 text), you're almost certainly at 4.5:1+. When L values are within 30 points, check with a tool.

**Color-alone rule:** Never use color as the only indicator. Always pair with an icon, label, underline, or pattern for colorblind users.

---

## Hard anti-patterns

```tsx
// ❌ Default AI purple-blue gradient — the most recognizable slop signal
background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
// ✅ Brand-derived, purposeful gradient
background: linear-gradient(135deg, oklch(65% 0.18 220), oklch(55% 0.14 265));

// ❌ Pure black/white for large surfaces — feels unfinished
background: #000000;  background: #ffffff;
// ✅ Tinted near-neutral
background: oklch(98% 0.01 220);  /* barely cool white */
background: oklch(10% 0.02 220);  /* deep tinted dark */

// ❌ Pure gray neutrals — lifeless
color: #9ca3af;
// ✅ Slightly tinted neutral (pick warm or cool and be consistent)
color: oklch(65% 0.03 220);

// ❌ Using brand accent color for error/success — breaks semantic meaning
.error { color: var(--brand-primary); }
// ✅ Always semantic for states
.error { color: oklch(52% 0.22 22); }

// ❌ Accent color everywhere (>20% of interface)
// ✅ Accent = 10% only — the rarer it appears, the more powerful it is

// ❌ Rainbow of unrelated colors
// ✅ 2–4 colors max beyond neutrals, all derived from the same hue family
```

---

## Quick decision tree

```
Starting a new color decision?
│
├─ Does the project have a design-system skill or DESIGN_SYSTEM.md?
│   └─ Yes → READ IT FIRST. Follow its rules. Only use this skill
│             for the 60/30/10 distribution logic and OKLCH math.
│
├─ Do brand colors exist in the codebase?
│   ├─ Yes → Extract hue from brand color. Build scale around it.
│   └─ No  → Ask: "What emotion should this UI evoke?" → pick hue.
│
├─ What am I adding color to?
│   ├─ State (success/error/warning/info) → Always semantic hues (Step 4)
│   ├─ CTA/primary action → Accent (10% slot)
│   ├─ Background/surface → Dominant (60% slot), low chroma
│   ├─ Section separator/card → Secondary (30% slot)
│   └─ Data viz/badge/icon → Accent or semantic, depends on meaning
│
└─ Does it pass contrast? (Step 5) → Ship it
```

---

## Compose with other skills

This skill handles **distribution and generation**. Pair it with:

- **`ui-ux-pro-max`** — overall UI vocabulary, component patterns, layout
- **`design-taste`** — motion, micro-interactions, polish, anti-slop instincts
- **Project `design-system`** — project-specific token rules (always override this skill)

Invocation order: `design-system` (if exists) → `color-strategy` → `ui-ux-pro-max` → `design-taste`
