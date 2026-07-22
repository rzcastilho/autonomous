# Contract: Console Design System

The console's external interface is its **UI**. This contract fixes (1) the exact
visual tokens the redesign must reproduce (FR-019) and (2) the stable markup hooks
(class names, `data-*` attributes, state text) that the LiveView test suite and the
shared components depend on — the seam that guarantees behavior is unchanged (FR-020).

Authoritative visual source: `docs/control-plane-design-reference/ControlPlane.dc.html`
+ `support.js`. Where this contract and the reference disagree, the reference wins.

## 1. Color tokens

```text
--bg:            #0b0d12     /* app background */
--panel:         #0e1016     /* sidebar, cards, top bar, status bar */
--border:        #1c212c     /* hairline dividers */
--border-strong: #232936     /* scrollbar thumb / emphasized edges */
--text:          #e6e9f0     /* primary text */
--muted:         #5a6274     /* labels, mono captions, secondary text */
--accent:        #7c5cff     /* brand, active nav, primary button */
--accent-2:      #4b2fd6     /* logo gradient end */
--link:          #a78bfa     /* links */  (hover #c4b5fd)
--selection:     rgba(124,92,255,.35)
```

### Status colors (single source: `CoreComponents.@palette`)

```text
pending   #64748b      halted    #fb7185
blocked   #475569      failed    #f43f5e
running   #38bdf8      done      #34d399
escalated #fbbf24
```

Status pill style (existing convention, kept): `background: <color>20; color: <color>;
border: 1px solid <color>` (the `20` = ~12% alpha hex suffix).

### Cost-gauge fill thresholds (behavior unchanged; colors from palette family)

```text
tripped            → halted-red   (#fb7185 / #ef4444 family)
fill >= 90%        → halted-red
70% <= fill < 90%  → escalated-amber (#fbbf24)
fill < 70%         → done-green   (#34d399)
```

## 2. Typography

```text
@font-face: "IBM Plex Sans"  400,500,600,700  → priv/static/fonts/*.woff2  (self-hosted)
@font-face: "IBM Plex Mono"  400,500,600      → priv/static/fonts/*.woff2  (self-hosted)

--font-sans: "IBM Plex Sans", system-ui, sans-serif
--font-mono: "IBM Plex Mono", monospace
```

- Body uses `--font-sans`, antialiased.
- Mono captions/ids/labels (e.g. "CONTROL PLANE · v1", session ids, timestamps) use
  `--font-mono`, small (10–11px), `letter-spacing: .5px`, color `--muted`.
- **No** `fonts.googleapis.com` / `fonts.gstatic.com` request at runtime (FR-021).

## 3. Layout metrics

```text
Sidebar:        width 236px, flex 0 0 236px, bg --panel, border-right 1px --border,
                padding 18px 14px, full viewport height, non-scrolling column.
Logo mark:      30×30, radius 8px, linear-gradient(140deg, #7c5cff, #4b2fd6),
                inner 12×12 white 2px-border square rotated 45deg,
                shadow 0 0 0 1px #2a2350, 0 6px 16px rgba(124,92,255,.35).
Nav item:       full-width button, 16px leading glyph slot, active state = accent.
App frame:      display:flex; height:100vh; width:100vw; overflow:hidden.
Content column: flex:1; min-width:0 (so children truncate, not overflow).
Responsive:     @media (max-width:1120px) → Mission Control grid collapses to 1 column;
                feed becomes static, lists scroll within container (max-height).
Truncation:     long slugs/session ids → overflow hidden + text-overflow ellipsis.
Scrollbar:      10px, thumb #232936 with 2px --bg border, transparent track.
```

Nav glyphs (text symbols, no icon font — Assumptions): Mission `◧`, Pipeline `⊟`,
Trigger `▷`, Escalations `⚠`, Transcripts `≡`, Configuration `⚙`.

## 4. Stable markup hooks (MUST be preserved — behavior/test seam, FR-020)

The restyle MAY change surrounding structure but MUST keep these hooks so existing
tests and shared components keep working:

| Hook | Where | Asserted by / used for |
|---|---|---|
| `class="cost-gauge"` (+ `cost-gauge-fill`, `cost-gauge-label`) | top bar | `layout_test` gauge assertions (FR-003) |
| `class="badge-warn"` + escalation count text | Escalations nav item | `layout_test` badge assertions (FR-002) |
| `class="status-pill"` + `data-status="<status>"` | every status label | shared palette / color-coding (SC-001) |
| `data-phase="<phase>"` per cell | phase strip | `layout_test` phase-strip assertion (FR-006) |
| `class="nav-active"` on current item | sidebar | active-section marking (FR-001) |
| text `No active run` / `Active run` / `armed` / `tripped` | top bar | `layout_test` run-state assertions (FR-004) |
| `href="<path>"` for each of six routes | sidebar | nav routing (FR-001) |

Any test assertion that keys off *incidental* layout markup the redesign restructures
is updated in lockstep to assert on the corresponding hook above instead.

## 5. Asset serving contract

```text
priv/static/assets/console.css   served at  /assets/console.css   via Plug.Static
priv/static/fonts/*.woff2        served at  /fonts/*.woff2         via Plug.Static (new mount)
root.html.heex:  <link rel="stylesheet" href="/assets/console.css">
                 <link rel="preload" as="font" type="font/woff2" crossorigin ...>  (hero weights)
```

`Plug.Static` `only:` list extended from `~w(app.js)` to include `console.css`; a
second static mount serves `/fonts`. No esbuild/tailwind/npm step is introduced.

## 6. Invariants

- **INV-1**: One palette map drives every status color across all six pages + drawer.
- **INV-2**: No route, event name, LiveView `assign` key, or PubSub topic changes.
- **INV-3**: No runtime external network request for fonts or any other asset.
- **INV-4**: Every operator action available pre-redesign remains available (SC-005).
