# Contract: the authoritative token set

**Feature**: `020-reconcile-console-design` | **Governing**: `docs/design-constitution.md`

The single `:root` block at the head of `priv/static/assets/console.css` is the
console's only token declaration and the **only** region of any console source in
which a color, radius, font-size, or spacing literal may appear. Everything else
— stylesheet rules, shared components, per-view markup — consumes it.

This file is the contract for that block: what it must contain, what it must not,
and what a maintainer edits.

---

## 1. Stylesheet header

The header MUST cite the governing contract and MUST NOT cite the superseded
feature-local one as governing *(FR-005, SC-005 acceptance 5)*:

```css
/* Speckit Orchestrator console.
   Governing contract: docs/design-constitution.md (normative by reference from
   .specify/memory/constitution.md Principle VII + Operator Surface Design).
   Historical record only, no longer governing:
     specs/011-control-plane-ui-redesign/contracts/design-system.md
   Deliberate divergence: --hatch-reserved, see specs/020-reconcile-console-design/plan.md
     § Complexity Tracking. */
```

`specs/011-control-plane-ui-redesign/contracts/design-system.md` MUST remain
byte-unmodified.

---

## 2. Contract colors — verbatim from §II

Copied name-for-name and value-for-value. A diff against the design
constitution's §II CSS block MUST be empty.

```css
:root {
  /* Surfaces — never interchangeable (§II) */
  --bg:#0b0d12; --panel:#0e1016; --card:#12151d; --raised:#161a23;

  /* Borders — role-ordered lightest→strongest (§II) */
  --hairline:#14181f; --border-subtle:#1c212c; --border:#232936; --border-strong:#2a3142;

  /* Text — four steps, no more (§II) */
  --text:#e6e9f0; --text-secondary:#c3c9d6; --text-muted:#8b93a7; --text-faint:#5a6274;

  /* Accent — one violet hue (§II) */
  --accent:#7c5cff; --accent-light:#a78bfa; --accent-hover:#c4b5fd;
  --accent-deep:#5a3fe0; --accent-shadow:#2a2350;

  /* Status — the only saturated colors in the system (§II) */
  --done:#34d399; --running:#38bdf8; --escalated:#fbbf24;
  --halted:#fb7185; --failed:#f43f5e; --pending:#64748b; --blocked:#475569;
```

### Retired names

These MUST NOT appear anywhere after reconciliation. They are **retired, not
renamed** — their use sites are re-pointed by role (see §6).

| Retired | Held | Why it cannot simply be renamed |
|---|---|---|
| `--muted` | `#5a6274` | Serves three contract roles at its 42 sites |
| `--accent-2` | `#4b2fd6` | Not a contract value at all; `--accent-deep` is `#5a3fe0` |
| `--link` | `#a78bfa` | Contract name is `--accent-light` |
| `--link-hover` | `#c4b5fd` | Contract name is `--accent-hover` |

`--border` and `--border-strong` keep their names but **change value**; every one
of their 50 combined sites is re-judged by role (§6).

---

## 3. Geometry and type tokens

Radii from §IV, resolved against §V where the two differ (see §7).

```css
  /* Radii (§IV; pip from §V) */
  --r-pip:2px; --r-chip:5px; --r-control:7px;
  --r-input:9px; --r-card:10px; --r-panel:12px; --r-dot:50%;

  /* Type scale (§III) */
  --fs-kpi:26px; --fs-subject:17px; --fs-title:15px; --fs-card-title:14px;
  --fs-section:13px; --fs-transcript:12.5px; --fs-body:12px;
  --fs-meta:11px; --fs-eyebrow:10px;

  /* Spacing rhythm, 2px grid (§IV) */
  --sp-4:4px; --sp-6:6px; --sp-8:8px; --sp-10:10px; --sp-12:12px;
  --sp-14:14px; --sp-18:18px; --sp-20:20px; --sp-22:22px;

  /* Families (unchanged) */
  --font-sans:"IBM Plex Sans",system-ui,sans-serif;
  --font-mono:"IBM Plex Mono",monospace;
```

**Rules**

- `--fs-eyebrow` (10px) is the floor and is permitted **only** for uppercase mono
  eyebrows with `letter-spacing:.4–.6px` and `--text-faint`. Prose MUST NOT go
  below `--fs-meta` (11px); transcript body MUST NOT go below `--fs-transcript`.
- Radii MUST come from this list. `3px`, `4px`, `11px`, `13px`, and `999px` are
  retired: pills move to `--r-chip` per §V's chip spec.
- Layout dimensions the contract does not fix (sidebar `236px`, drawer `460px`,
  gauge `280px`, column widths) MAY stay literal *(FR-004)*.

---

## 4. Derived tokens

The contract states these as literals in prose rather than in a token table. Each
cites its section; no other derived token may be added without a plan entry.

```css
  /* Derived — contract states these in prose */
  --scrim:rgba(6,7,11,.6);                                   /* §V drawer */
  --shadow-drawer:-20px 0 60px rgba(0,0,0,.5);               /* §IV */
  --shadow-toast:0 6px 24px rgba(0,0,0,.45);                 /* §IV toast elevation */
  --glow-accent:0 0 0 1px var(--accent-shadow),
                0 6px 16px rgba(124,92,255,.35);             /* §IV active-node glow */
  --gradient-primary:linear-gradient(140deg,var(--accent),var(--accent-deep)); /* §II */
  --selection:#7c5cff55;                                     /* §II `55` suffix */

  /* DELIBERATE DIVERGENCE — see plan.md § Complexity Tracking.
     §VII.3 mandates hatched reserved spend; §II/§VIII prohibit background
     gradients. The semantic MUST wins; this is the only gradient outside the
     primary button and the app mark. */
  --hatch-reserved:repeating-linear-gradient(45deg,
    var(--border-strong),var(--border-strong) 4px,
    var(--border) 4px,var(--border) 8px);
}
```

`--selection` replaces today's `rgba(124,92,255,.35)`: §II permits `55` as a
transparency suffix and permits no arbitrary alpha.

---

## 5. Consumption rules

- **Colors.** Every color in a stylesheet rule is `var(--…)` or
  `var(--…)` + a permitted suffix expressed through a status rule (§2 of
  `status-transport.md`). No `#hex`, `rgb()`, `hsl()`, or named color outside
  `:root`. *(FR-002)*
- **Transparency suffixes.** Only `1a` (chip fill), `22` (active fill),
  `40`/`55`/`66`/`88` (borders), `0d` (header wash). Today's `20` and `14`
  suffixes are retired. *(FR-009)*
- **Gradients.** `--gradient-primary` on the primary action button and the app
  mark only; `--hatch-reserved` on the gauge's reserved band only. Nowhere else.
  *(FR-012)*
- **Shadows.** `--shadow-drawer`, `--shadow-toast`, `--glow-accent` only. A
  resting surface is separated by border. *(FR-013)*
- **Server-rendered code.** No color, radius, font-size, or spacing value is
  emitted from Elixir at all. *(FR-002, FR-004a)*
- **Pure black/white.** `#000` and `#fff` are prohibited in every form,
  including inside `rgba()` where a token exists. `rgba(0,0,0,…)` survives only
  inside the three shadow tokens above, which the contract states verbatim.

---

## 6. Re-pointing by role (not by rename)

Every retired or revalued token site is resolved by the role it plays.

**Borders — §II**

| Role | Token |
|---|---|
| Row divider inside a card | `--hairline` |
| Structural region divider | `--border-subtle` |
| Default card/panel border | `--border` |
| Interactive / secondary-button border | `--border-strong` |

**Text — §II**

| Role | Token |
|---|---|
| Primary | `--text` |
| Values, body | `--text-secondary` |
| Descriptions, secondary labels | `--text-muted` |
| Mono metadata, uppercase eyebrows | `--text-faint` |

A mechanical rename is prohibited: it would shift every border and every text
node one step off its contract role while appearing to comply. Each site's
verdict is recorded in `compliance-inventory.md`.

---

## 7. Recorded doc conflict

`docs/design-constitution.md` §IV says "5–6px chips/pips"; §V says phase pips are
"radius 2px". **§V governs** — the component-specific spec is the more specific
rule and matches the shipped `.phase-cell`. Recorded in plan.md § Complexity
Tracking as a doc conflict for a later amendment to correct in the doc itself; it
is not resolved silently here.

---

## 8. Acceptance

| Check | Means |
|---|---|
| Every §II token present, contract name + contract value | guard `:missing_token`, `:token_value_mismatch` |
| No token holds another token's value | guard `:token_value_mismatch` |
| No retired token name referenced | guard `:retired_token` |
| No literal outside `:root` | guard `:color_literal`, `:offscale_radius`, `:offscale_font_size` |
| Only permitted suffixes | guard `:illegal_alpha_suffix` |
| Header cites the governing contract | guard `:governing_source` |
| 011 contract byte-unmodified | guard `:frozen_artifact` |
| Each site re-pointed by role, not rename | inventory verdict per site |
