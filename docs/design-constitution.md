# Operator Control Plane — Design Constitution

A binding visual + interaction contract for autonomous-system operator surfaces.
Derived from the `speckit_orchestrator` control plane.

Language: **MUST** / **SHOULD** / **NEVER**. A design that violates a MUST is non-compliant.

---

## I. First Principles

1. **The operator is watching a machine, not browsing a site.** Density, legibility at a glance, and truthfulness beat whitespace and delight. NEVER apply consumer-web tropes (hero sections, marketing gradients, decorative illustration, emoji).
2. **State is the content.** Every screen MUST answer "what is happening right now" above the fold. Status, progress, and cost are primary; chrome is secondary.
3. **The UI mirrors the system's real vocabulary.** Labels MUST use the system's actual identifiers — function names (`resume/2`), atoms (`:needs_human`), file paths (`checkpoint.json`), config keys (`max_concurrency`). NEVER invent friendly synonyms for things the operator will type into a shell.
4. **Show the receipt.** Any state the UI asserts MUST be traceable to a visible artifact — a path, a transcript, a record, an ID.
5. **Destructive and expensive actions are never one ambiguous button.** Distinct recovery paths MUST be visually distinct (see §VII).

---

## II. Color

Dark, near-black, low-chroma canvas. A single violet accent. Color carries **meaning**, never decoration.

### Surfaces (never interchangeable)

| Token | Value | Use |
|---|---|---|
| `--bg` | `#0b0d12` | App canvas, inset wells, textareas |
| `--panel` | `#0e1016` | Sidebar, topbar, drawer |
| `--card` | `#12151d` | Cards, tables, panels |
| `--raised` | `#161a23` | Hover rows, secondary buttons, chips |

### Borders

| Token | Value | Use |
|---|---|---|
| `--hairline` | `#14181f` | Row dividers inside a card |
| `--border-subtle` | `#1c212c` | Structural region dividers |
| `--border` | `#232936` | Default card/panel border |
| `--border-strong` | `#2a3142` | Interactive/secondary button border |

### Text (four steps, no more)

| Token | Value | Use |
|---|---|---|
| `--text` | `#e6e9f0` | Primary |
| `--text-secondary` | `#c3c9d6` | Values, body |
| `--text-muted` | `#8b93a7` | Descriptions, secondary labels |
| `--text-faint` | `#5a6274` | Mono metadata, uppercase eyebrows |

### Accent — violet, used sparingly

| Token | Value | Use |
|---|---|---|
| `--accent` | `#7c5cff` | Primary action, active nav, focus |
| `--accent-light` | `#a78bfa` | Inline code refs, links, checkpoint marks |
| `--accent-hover` | `#c4b5fd` | Link hover |
| `--accent-deep` | `#5a3fe0` | Gradient terminus |
| `--accent-shadow` | `#2a2350` | Accent-tinted borders |

### Status — the only saturated colors in the system

| Status | Value |
|---|---|
| `done` | `#34d399` |
| `running` | `#38bdf8` |
| `escalated` | `#fbbf24` |
| `halted` | `#fb7185` |
| `failed` | `#f43f5e` |
| `pending` | `#64748b` |
| `blocked` | `#475569` |

**Rules**

- Status color MUST be used consistently across every representation of that state — dot, text, chip, pip, graph node border, timeline rail.
- A status color MUST NEVER be used decoratively on a non-status element.
- Terminal/inactive states (`pending`, `blocked`) MUST be desaturated slate, never a hue.
- Transparency suffixes are the only permitted tints: `1a` (chip fill), `22` (active fill), `40`/`55`/`66`/`88` (borders), `0d` (header wash).
- NEVER introduce a second accent hue. NEVER use more than two background colors in one region.
- Gradients: permitted **only** on the primary action button, `linear-gradient(140deg, var(--accent), var(--accent-deep))`, and the app mark. NEVER on backgrounds, cards, or text.

```css
:root {
  --bg:#0b0d12; --panel:#0e1016; --card:#12151d; --raised:#161a23;
  --hairline:#14181f; --border-subtle:#1c212c; --border:#232936; --border-strong:#2a3142;
  --text:#e6e9f0; --text-secondary:#c3c9d6; --text-muted:#8b93a7; --text-faint:#5a6274;
  --accent:#7c5cff; --accent-light:#a78bfa; --accent-hover:#c4b5fd;
  --accent-deep:#5a3fe0; --accent-shadow:#2a2350;
  --done:#34d399; --running:#38bdf8; --escalated:#fbbf24;
  --halted:#fb7185; --failed:#f43f5e; --pending:#64748b; --blocked:#475569;
}
```

---

## III. Typography

Two families only.

- **IBM Plex Sans** (400/500/600/700) — prose, labels, buttons, headings.
- **IBM Plex Mono** (400/500/600) — every machine value.

### The mono rule (load-bearing)

Anything the machine produced or the operator would type MUST be mono: IDs, slugs, phases, statuses, paths, branches, session IDs, config keys, counts, money, durations, timestamps. Anything written for a human MUST be sans. NEVER mix the two roles.

### Scale

| Size | Weight | Use |
|---|---|---|
| 26px | 600 mono | KPI figures |
| 17px | 600 mono | Drawer subject ID |
| 15px | 600 sans | View titles |
| 15px | 400 mono | Config values |
| 14px | 600 | Card titles, escalation subject |
| 13px | 600 sans | Section titles, nav, buttons |
| 13px | 400 mono | Record values, transcript-adjacent values |
| 12.5px | 400 mono | Transcript body (line-height 1.7) |
| 12px | 400 | Descriptions, secondary buttons |
| 11px | 400 | Table meta, hints, legends |
| 10px | 400 mono | Uppercase eyebrows, `letter-spacing:.5px` |

- Body copy NEVER below 11px; transcript/log text NEVER below 12.5px.
- Section eyebrows MUST be 10px mono, uppercase, `letter-spacing:.4–.6px`, `--text-faint`.
- Ordinals MUST be zero-padded (`01`, `007`).
- `text-overflow:ellipsis` + `white-space:nowrap` on every constrained identifier. NEVER let an ID wrap.

---

## IV. Geometry & Space

- **Radii:** 5–6px chips/pips · 7px small controls · 8–9px inputs, secondary buttons · 10px cards, primary buttons · 12px major panels · 50% dots.
- **Spacing** on a 2px grid; standard rhythm 4 · 6 · 8 · 10 · 12 · 14 · 18 · 20 · 22px. Page padding 22px. Card padding 18–20px. Table cells 13px vertical / 18px horizontal.
- **Gap over margin.** Sibling groups MUST use flex/grid + `gap`. NEVER space UI with inline whitespace or per-child margins.
- **Shadow is for elevation only** — drawers (`-20px 0 60px rgba(0,0,0,.5)`), toasts, and the accent glow on active nodes. NEVER on static cards.
- Borders, not shadows, separate resting surfaces.

---

## V. Core Components

**Status dot** — 7–9px circle in the status color; `scPulse 1.3s infinite` if and only if the entity is actively working.

**Chip** — `10px mono, 600, letter-spacing .4px, padding 3px 8px, radius 5px`, `color: X`, `background: X1a`, `border: 1px solid X40`.

**Phase pips** — a fixed-length equal-width track (`grid-template-columns:repeat(N,1fr)`, gap 3–4px, height 5–7px, radius 2px) showing the whole pipeline at once. Completed = `done`; current = status color, pulsing if running; future = `--border`. Every pip MUST carry a `title` naming its phase and state. Pip tracks MUST be identical in every context they appear.

**Data table** — 10px mono uppercase header; identifier column pairs a 13px mono ID over an 11px sans slug; numerics right-aligned mono; rows `cursor:pointer` with `--raised` hover.

**Record block** — inset `--bg` well for machine records: an accent eyebrow naming the artifact path, then a `grid` of 10px mono faint keys against 12px mono value pairs. This is the canonical way to show a persisted artifact.

**Event feed** — reverse-chronological rows of `time · status dot · mono ID · sans predicate`. Newest first, always.

**Timeline** — vertical rail of 22px status-bordered nodes (`✓` done, `●` active, `!` escalated, `✕` failed, ordinal pending), connecting line tinted `done` behind completed steps.

**Toast** — bottom-center, `--raised` on a 1px accent border, ~2.8s. Toasts MUST echo the underlying call and its arguments, not a vague success message.

**Drawer** — 460px right panel over `rgba(6,7,11,.6)`; scrim click closes.

---

## VI. Motion

Four keyframes; nothing else.

| Name | Timing | Use |
|---|---|---|
| `scPulse` | 1.3s infinite | Active work only |
| `scBlink` | 1.4s infinite | Live stream indicator |
| `scSlide` | .18s ease | Drawer entry |
| `scFade` | .12–.2s ease | Scrims, toasts |

- Motion MUST mean "this is live." NEVER animate on entry for flourish, and NEVER animate a resting element.
- Hover transitions ≤ .15s.

---

## VII. Interaction Law

1. **Nav is persistent and flat.** One left rail, one level, active item accent-filled with an inset accent ring. Counts of items needing attention MUST appear as a badge on the nav item.
2. **Global run state is always visible** — state chip, subject, budget/limit gauge, and breaker status persist in the topbar on every view.
3. **Limit gauges MUST show committed and reserved separately** — solid fill for committed, hatched for reserved-but-unspent — and MUST change color at threshold (safe → warning >80% → tripped).
4. **Recovery paths MUST be visually ranked.** The cheapest correct action is the gradient primary; the expensive/destructive alternative is a bordered secondary sharing the same row. Both MUST state their consequence in a mono hint (e.g. "keeps completed phases · reuses branch").
5. **Every override the API supports MUST be exposed** at the point of decision, labeled with its real option name (`:from`, `:prompt`), and MUST default to the value the system would choose unaided.
6. **Long-running state is simulated honestly.** Progress, spend, and queue release MUST advance from real rules, never a fake timer. The operator MUST be able to pause.
7. **Every entity is inspectable.** Clicking any row, node, or card opens the same detail surface. One entity, one detail view.
8. **Empty states are a status report**, not an invitation — state the healthy condition (`No open escalations` + why), never a call to action.

---

## VIII. Prohibitions

NEVER: light backgrounds · a second accent hue · background gradients · emoji · decorative illustration · rounded-card-with-left-accent-border · marketing copy · centered body text · font sizes below 10px · pure `#000` or `#fff` · status color used decoratively · a friendly rename of a real system identifier · a destructive action styled identically to a safe one · animation without a live referent.

