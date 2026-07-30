# Phase 0 Research: Reconcile the console with the design constitution

**Feature**: `020-reconcile-console-design` | **Date**: 2026-07-29

All Technical Context unknowns are resolved below. Every decision is grounded in
a measured fact about the shipped console, not an estimate; the measurement
commands are recorded so the baselines in `spec.md` (SC-002, FR-004a) stay
checkable.

---

## 0. Measured baseline

Taken on `020-reconcile-console-design` at plan time.

| Fact | Value | How measured |
|---|---|---|
| Stylesheet size | 2050 lines, 267 top-level classes | `wc -l`; `grep -cE '^\.[a-z]'` |
| Color literals in `console.css` | 109 total; 10 inside `:root`, **99 outside** | `grep -oE '#[0-9a-fA-F]{3,8}' \| wc -l` |
| `rgba()`/`hsl()` literals in `console.css` | 4 | `grep -cE 'rgba?\(\|hsla?\('` |
| Keyframes defined | **0** | `grep -nE '@keyframes\|animation:'` → no match |
| `prefers-reduced-motion` blocks | **0** | `grep -n 'prefers-reduced-motion'` |
| Color-bearing inline styles in server code | **6** | `grep -rn 'style=' lib/…/web/` |
| Hex literals in server code | 14 (8 palette entries + 4 gauge bands + 2 fallbacks) | `grep -rn '#[0-9a-fA-F]\{6\}' lib/…/web/` |
| Views + shared modules | 8 LiveViews, 3 component modules, 2 layout templates (3305 LOC) | `wc -l lib/…/web/**` |
| Console tests asserting a color/glyph/inline style | **0** | `grep -rn '#[0-9a-f]\{6\}\|style=' test/` → no match |
| `app.js` | 7 lines, 0 color literals | `wc -l`; `grep -c` |

Two consequences worth stating up front:

- **SC-002's "104 color literals" is 99 outside `:root` + 4 `rgba()` + 1 `#fff`
  used as a `background` (counted once in both sets).** The reconciled target is
  0 outside the token block either way; the plan does not restate the baseline
  arithmetic, it just drives it to zero.
- **FR-025 is nearly free.** No existing console test pins a color, a glyph, or
  an inline style. The test churn is limited to structural assertions that change
  shape (nav glyphs, empty-state icon, toast border classes) — found by running
  the suite, not by a survey.

---

## 1. Token layer: how one authoritative set is expressed with no build step

**Decision.** One `:root` block at the top of `console.css` is the single
authoritative token declaration and the **only** region of any console source in
which a color, radius, font-size, or spacing literal may appear. It carries five
families:

1. **Contract colors verbatim** — the 24 tokens of the design constitution's §II
   CSS block, copied name-for-name and value-for-value (4 surfaces, 4 borders,
   4 text steps, 5 accent steps, 7 statuses).
2. **Radius tokens** from §IV: `--r-chip: 5px`, `--r-pip: 2px`,
   `--r-control: 7px`, `--r-input: 9px`, `--r-card: 10px`, `--r-panel: 12px`,
   `--r-dot: 50%`.
3. **Type-size tokens** from §III's eleven-row scale, named by role:
   `--fs-kpi: 26px`, `--fs-subject: 17px`, `--fs-title: 15px`,
   `--fs-card-title: 14px`, `--fs-section: 13px`, `--fs-transcript: 12.5px`,
   `--fs-body: 12px`, `--fs-meta: 11px`, `--fs-eyebrow: 10px`.
4. **Spacing tokens** on §IV's rhythm: `--sp-1: 2px` … `--sp-22: 22px` for the
   nine named steps (4·6·8·10·12·14·18·20·22).
5. **Derived tokens the contract specifies as literals in prose** —
   `--scrim: rgba(6,7,11,.6)` (§V drawer), `--shadow-drawer: -20px 0 60px
   rgba(0,0,0,.5)` (§IV), `--shadow-toast`, `--glow-accent: 0 0 0 1px
   var(--accent-shadow), 0 6px 16px rgba(124,92,255,.35)` (§IV accent glow),
   `--gradient-primary: linear-gradient(140deg, var(--accent),
   var(--accent-deep))` (§II), and `--selection: #7c5cff55` (a permitted `55`
   suffix, replacing today's `rgba(124,92,255,.35)`).

**Rationale.** The constitution's Frontend section forbids a build step, so
CSS custom properties are the only mechanism available; they are also the only
one that satisfies FR-001's "one edit propagates" requirement *at runtime*,
including into `data-status`-keyed rules the server never sees. Naming radii and
type sizes as tokens is what makes FR-002's "radius, font-size and spacing from
the token set" mechanically checkable — with bare literals a guard cannot tell an
off-scale `13px` radius from a legitimate `13px` table cell padding.

**Alternatives considered.**
- *Sass/PostCSS variables* — rejected: introduces the exact toolchain the
  constitution's Frontend section bars.
- *Leave radii/type as literals, guard colors only* — rejected: FR-002 names
  radius and font-size explicitly, and the measured stylesheet has off-scale
  radii (`3px`, `4px`, `11px`, `13px`, `999px`) and sub-floor type (`9px` ×2)
  that a color-only guard would let stand.
- *Elixir-side token module rendering CSS at compile time* — rejected: puts
  presentation values in `lib/`, and the server would still have to emit them
  into markup, which FR-004a forbids.

### 1a. The name-collision re-pointing (the highest-risk change)

The shipped tokens are each **one step lighter** than the contract's same-named
tokens:

| Shipped | Value | Contract token holding that value | Shipped uses |
|---|---|---|---|
| `--border` | `#1c212c` | `--border-subtle` | 10 |
| `--border-strong` | `#232936` | `--border` | 40 |
| `--muted` | `#5a6274` | `--text-faint` | 42 |
| `--accent-2` | `#4b2fd6` | *(none — contract's `--accent-deep` is `#5a3fe0`)* | 4 |
| `--link` / `--link-hover` | `#a78bfa` / `#c4b5fd` | `--accent-light` / `--accent-hover` | 3 / 1 |

**Decision.** Re-point all 100 use sites **by contract role**, never by renaming
the token. Roles per §II:

- border: row divider inside a card → `--hairline`; structural region divider →
  `--border-subtle`; default card/panel border → `--border`; interactive or
  secondary-button border → `--border-strong`.
- text: primary → `--text`; values and body → `--text-secondary`; descriptions
  and secondary labels → `--text-muted`; mono metadata and uppercase eyebrows →
  `--text-faint`.

**Rationale.** A mechanical rename (`--border` → `--border-subtle`) would
preserve today's rendering but leave every border one step off its contract role
— it converts a loud divergence into a silent one, which is the failure mode
Principle VII exists to prevent. The spec's second edge case mandates the
role-based walk explicitly.

**Consequence for sequencing.** The 42 `var(--muted)` sites are the largest
single judgment batch and the one a grep cannot decide: the same token today
serves eyebrows (correctly `--text-faint`) and descriptions (should be
`--text-muted`). This is the primary driver of the compliance inventory (§6).

### 1b. Off-palette values and their contract mapping

Every literal outside `:root` maps to a contract token. The non-obvious ones:

| Literal | Sites | Where | Mapped to | Basis |
|---|---|---|---|---|
| `#8b93a7` | 13 | descriptions, metadata | `--text-muted` | exact contract value |
| `#12151d` | 10 | cards | `--card` | exact |
| `#2a3142` | 7 | interactive borders | `--border-strong` | exact |
| `#161a23` | 5 | secondary buttons, hover | `--raised` | exact |
| `#c3c9d6` | 4 | values | `--text-secondary` | exact |
| `#14181f` | 2 | row dividers | `--hairline` | exact |
| `#232936` | 2 | card borders | `--border` | exact |
| `#2a2350` | 2 | accent-tinted border | `--accent-shadow` | exact |
| `#171b25` | 2 | `.cost-gauge` bg, `.model-row` divider | `--raised` / `--hairline` | nearest role; off-palette by 2 units |
| `#a5b0c2` | 1 | `.btn-secondary` label | `--text-secondary` | nearest text step |
| `#4b2fd6` | 1 | `.dag-node-mark` gradient terminus | `--accent-deep` (`#5a3fe0`) | the collision the amendment named |
| `#6ee7b7`, `#1c5c3a`, `#0f2a1c` | 4 | `.drawer-pr` | *removed* — see §4c | `done`-adjacent greens on a non-status element |
| `#fff` | 7 | borders, a background, text | `--text` / `--card` / `--border-strong` by role | §VIII bans pure `#fff` |
| `#fbbf2420`, `#fb718520`, `#38bdf820`, `#34d39920` | 4 | chips | status + `1a` fill / `40` border | §II permits only `1a·22·40·55·66·88·0d` |
| `#f43f5e14` | 1 | `.field-error` | *removed* — see §4b | `14` is not a permitted suffix |

**Decision.** No literal is kept. The three `.drawer-pr` greens and the
`.field-error` red are removed rather than mapped, because both are status colors
on non-status elements (FR-012) — mapping them to a token would keep the
prohibition. Nothing lands in Complexity Tracking from this table.

---

## 2. Status color: one definition reached by server-rendered markup

**Decision.** The server emits the **status name**; the stylesheet owns every
color. Concretely:

- `CoreComponents.palette/0` stops carrying colors. It becomes a
  `status → label` map (labels are prose, and prose is not a contract value).
  A new `status_class/1` returns the canonical status atom as a string, folding
  `never_started → "blocked"` (spec assumption) so no eighth color exists.
- Every status-bearing element carries `data-status={...}` (already true of
  `status_pill`) or a `status-<name>` class, and `console.css` supplies
  color/fill/border for all seven under `[data-status="…"]` selectors — one rule
  set per status, consumed by dot, chip, phase pip, DAG node border, timeline
  node, gauge band, and legend swatch.
- The six color-bearing inline styles all disappear:

| Site | Today | Reconciled |
|---|---|---|
| `core_components.ex:39` chip fill + border | `style="background-color: #{color}20; …"` | `data-status`, CSS `1a`/`40` |
| `escalations_live.ex:372` card border | `style="border-color: #{c}40;"` | `data-status` on the card |
| `escalations_live.ex:374` card head wash | `style="background: #{c}0d;"` | `data-status` on the head |
| `escalations_live.ex:375` dot | `style="background-color: #{c};"` | `data-status` on the dot |
| `pipeline_dag_live.ex:287` legend swatch | `style="background-color: #{c};"` | existing `data-legend-status` |
| `core_components.ex:145` gauge fill color | `style="… background-color: #{c};"` | `data-band` class, §3 |

**Rationale.** FR-003 forbids a second definition "including one whose values
match", and FR-004a forbids emitting a color at all. A `data-status` attribute is
the smallest change that satisfies both: it already exists on `status_pill`, it
survives LiveView diffing, and it keeps the seven values in the one place a
maintainer edits.

**Alternatives considered.**
- *Keep the Elixir palette, read values from it in CSS* — impossible without a
  build step, and would still be a second definition.
- *CSS `attr()` for the color* — rejected: `attr()` outside `content` has no
  usable browser support, and it would require the server to emit a color.
- *Inline `var(--done)` instead of a hex* — rejected: still a color-bearing
  inline style, which FR-004a bans outright.

### 2a. Gauge band (the one computed value)

**Decision.** `gauge_color/2` becomes `gauge_band/2` returning
`:safe | :warning | :tripped`; the component emits `data-band={@band}` and the
stylesheet keys `--done` / `--escalated` / `--failed` off it. The **only**
surviving inline styles are the two fill widths (`width: N%`), which FR-004b
permits by name.

The contract's §VII.3 threshold is `warning > 80%`; today's code warns at 70%
and reds at 90%. **Decision: adopt the contract's 80% warning threshold**;
`tripped` is driven by `Ledger`'s actual `tripped?` flag plus the 100% ceiling,
not by a 90% guess, so the band reflects recorded breaker state (FR-020) rather
than a second opinion about it.

**Reserved-vs-committed** must be visually distinct (§VII.3, FR-016): solid fill
for committed, **hatched** for reserved. See §5 for the gradient-prohibition
tension this creates.

---

## 3. Motion: four keyframes, and reduced-motion without a fifth treatment

**Decision.** Define exactly `scPulse`, `scBlink`, `scSlide`, `scFade` with the
contract's timings, and attach them only where a live referent exists:

| Keyframe | Attached to | Live referent |
|---|---|---|
| `scPulse 1.3s infinite` | status dot / current phase pip / DAG node, **only** at `data-status="running"` | a feature actively working |
| `scBlink 1.4s infinite` | transcript live indicator, only while the phase attempt is unfinished | an unterminated transcript |
| `scSlide .18s ease` | drawer entry | the drawer entering |
| `scFade .12–.2s ease` | scrim, toast | scrim/toast entering |

Two removals fall out of "never animate a resting element": the
`.status-dot[data-ok="true"]` glow (`box-shadow: 0 0 6px #34d399`, line 408) is a
resting element wearing an elevation shadow *and* a status color — both go (§4a);
and no `:pending`/`:blocked`/terminal dot receives `scPulse`.

**Decision (FR-015a, reduced motion).** One `@media (prefers-reduced-motion:
reduce)` block sets `animation: none` on every rule that carries a keyframe. The
live-vs-resting distinction then rests on treatments the contract already
defines and that are present with motion enabled too:

- the **accent glow ring** on the active DAG node (§IV: "the accent glow on
  active nodes"), and
- the **current phase pip rendered in the status color** while future pips are
  `--border` (§V phase pips).

No new color, hue, or component is introduced, and the distinction never degrades
to status text alone — both markers are geometric/positional, readable at a
glance.

**Rationale.** The spec's clarification chose "static live marker" over a
motion-substitute; the two markers above are the only non-animated
active-entity treatments the contract already contains, so honouring the
preference costs nothing new.

**Alternatives considered.**
- *A dashed/striped border for reduced motion* — rejected: a new treatment the
  contract does not define, and hatching is already spoken for by the gauge.
- *Rely on the status chip's text* — rejected: FR-015a bans exactly this.
- *`@media` on each rule rather than one block* — rejected: makes "exactly four
  keyframes, all stoppable" harder for the guard to verify.

### 3a. `scBlink`'s live referent

The transcripts view reads durable transcripts from the store
(`SpeckitOrchestrator.run_detail/1`); it is not an incrementally-streamed
socket. **Decision:** the live indicator is bound to *the attempt not having
terminated* — a transcript whose phase attempt has no finish record is live and
blinks; a finished one does not. That is recorded state (FR-020), not a timer,
and it is the honest reading of "streaming transcript" for this console.

---

## 4. Judgment calls the contract forces (each lands in the inventory)

### 4a. Runtime/CLI health is not a run status

`.status-dot[data-ok="true"]` paints the context strip's `claude available` /
`runtime up` indicators in `done` green with a glow. Health is not one of the
seven run statuses, so this is a status color on a non-status element (FR-012)
plus a shadow on a resting surface (FR-013).

**Decision.** Drop the color and the glow. Health renders as its existing mono
value (`available` / `not found`, `up` / `down`) in `--text-secondary`, with the
dot in `--text-faint` when healthy and `--text-muted` when not. No information is
lost — the words already carried it (spec edge case: "removing a prohibited
treatment must re-express the information, not drop it").

### 4b. Validation refusals are not run statuses either

`.field-error` (used by trigger, config, and DAG forms) borders and colors itself
in `failed` red at a `14` alpha. A form refusal is not a feature's run state.

**Decision.** Re-express as the contract's **record block**: inset `--bg` well,
`--border-strong` border, an accent eyebrow naming the refusal, and the message
in mono `--text-secondary`. The parked-run banner in
`mission_control_live.ex:170` currently reuses `.field-error`; it *is* a run
state, so it moves to its own `data-state="parked"` rule that draws its color
from the run's status token legitimately.

**Rationale.** This is the sharpest reading of FR-012's "MUST NOT appear on any
non-status element". Recorded in the inventory with its verdict rather than
asserted, because it is precisely the kind of call a grep cannot make.

### 4c. `.drawer-pr` shows a persisted artifact

The PR block uses three off-palette greens (`#6ee7b7`, `#1c5c3a`, `#0f2a1c`) to
decorate a link — status-adjacent color on a non-status element, and a bespoke
box where FR-010a mandates the record-block treatment for a persisted artifact.

**Decision.** Rebuild as a record block: accent eyebrow naming the PR URL, mono
key/value grid, link in `--accent-light`. Same for the checkpoint and transcript
path blocks FR-010a names.

### 4d. Pictographs

`layouts.ex` nav glyphs (`◧ ⊟ ▷ ⚠ ▤ ≡ ⚙`) and the three button glyphs in
`escalations_live.ex` (`&#9654;` ▶, `&#8635;` ↻, `&#8801;` ≡) are decorative
pictographs. **Decision: removed**, per spec assumption — `nav_glyph/1` and
`@nav_glyphs` are deleted, buttons keep their real-identifier labels. The
timeline's `✓ ● ! ✕` marks are prescribed by §V and stay; they are the guard's
only pictograph allowlist.

`escalations_live.ex:554`'s `" ✓"` task-phase completion mark is a machine value
inside a mono label, not a decorative icon — **kept**, recorded in the inventory.

### 4e. Doc-internal conflict: pip radius

§IV says "5–6px chips/pips"; §V says phase pips are "radius 2px". **Decision:
§V wins** — the component-specific spec is the more specific rule, and the
shipped `.phase-cell` already uses `2px`. Recorded in Complexity Tracking as a
doc conflict to be corrected in `docs/design-constitution.md` by a later
amendment, not silently resolved.

The `999px` pill radius on `.status-pill`, `.run-state-*`, and `.breaker-chip`
is not a conflict — §V fixes the chip at `5px`, so those move to `--r-chip`.

### 4f. Sub-floor type

Two `font-size: 9px` sites violate §VIII's 10px floor. **Decision:** promote to
`--fs-eyebrow` (10px) if they are uppercase eyebrows, `--fs-meta` (11px)
otherwise; §III's "body copy never below 11px" makes 11px the answer for
anything that is prose.

---

## 5. The one deliberate divergence: hatched reserved spend

**Tension.** §VII.3 mandates "hatched for reserved-but-unspent". §II and §VIII
prohibit background gradients, and the only no-toolchain way to hatch is
`repeating-linear-gradient` — which the shipped `.cost-gauge-reserved` already
uses (line 219).

**Decision.** Keep the hatch, as `--hatch-reserved: repeating-linear-gradient(
45deg, var(--border-strong), var(--border-strong) 4px, var(--border) 4px,
var(--border) 8px)` declared in the token block, and allowlist exactly that one
token in the guard. **This is the feature's sole Complexity Tracking entry.**

**Rationale.** The prohibition targets decorative/marketing background gradients
(its §I neighbours are hero sections and marketing gradients); §VII.3's hatch is
a *semantic* requirement that Principle IV depends on — a gauge that merges
committed and reserved "misreports the breaker's actual headroom", which the
constitution says in so many words. Where an interaction-law MUST and a
color-decoration NEVER collide, the one carrying safety-relevant meaning wins,
and the divergence is recorded rather than argued each time.

**Alternatives considered.**
- *Two adjacent solid bars* — rejected: loses the overlap reading that shows
  reserved sitting on top of committed against one budget.
- *Reserved as an outline only* — rejected: at small widths an outline is
  indistinguishable from the gauge border.
- *An SVG pattern* — rejected: more markup, same gradient primitive underneath,
  and it would put geometry in server-rendered code.

---

## 6. Verification split: mechanical guard vs compliance inventory

**Decision.** A pure scanner module at `test/support/design_contract.ex`
(`SpeckitOrchestrator.Web.DesignContract`), driven by
`test/speckit_orchestrator/web/design_contract_test.exs`.

- **Location.** `test/support` is on `elixirc_paths` for `:test` only
  (`mix.exs:18`), so the lint ships no runtime code and adds no dependency
  (SC-008).
- **Shape.** `scan/1` takes `%{path => source}` and returns
  `[%Violation{rule, path, line, excerpt}]`. Pure, so the test proves SC-007's
  four injection cases against **crafted source strings** — no mutating and
  reverting real files, and the real-tree case is one more call with the real
  file map.
- **Rules (mechanically decidable):**

| Rule | Check |
|---|---|
| `:color_literal` | `#hex`/`rgb(`/`hsl(` outside the `:root` span, or anywhere in `lib/…/web/**` |
| `:inline_style_color` | `style=` attribute in HEEx whose value mentions a color property or interpolation, excepting `width:` |
| `:duplicate_status_value` | any of the 7 contract status values appearing outside the token block |
| `:unknown_keyframe` | `@keyframes` name not in the four; `animation:` naming an undefined keyframe |
| `:unstoppable_keyframe` | a rule with `animation:` not covered by the reduced-motion block |
| `:offscale_radius` / `:offscale_font_size` | `border-radius:`/`font-size:` with a literal instead of a token |
| `:sub_floor_type` | any type token or literal below 10px |
| `:pictograph` | a codepoint in the emoji/dingbat/geometric ranges outside the `✓ ● ! ✕` allowlist |
| `:pure_black_white` | `#000`/`#fff` in any form |
| `:centered_body_text` | `text-align: center` on a rule that also sets a body-copy font size |
| `:governing_source` | stylesheet header must cite `docs/design-constitution.md` |

- **Inventory** (`compliance-inventory.md`, committed in this spec dir) covers
  what the scanner cannot decide: the mono-vs-sans role split, the border/text
  role re-pointing of §1a's 100 sites, "status color on a non-status element" as
  a *semantic* judgment, shadow-for-elevation-only, empty-state wording,
  recovery-path ranking and consequence hints, and the §4a–4f calls above. One
  row per surface × element × rule × verdict.

**Rationale.** FR-026 mandates exactly two means with an explicit split, and
FR-024 mandates hermeticity. A pure scanner over an injected source map is the
only shape that is simultaneously hermetic, unit-testable to the >90% bar, and
able to prove its own failure modes without touching the tree.

**Alternatives considered.**
- *Stylelint / a CSS parser dep* — rejected: Node toolchain (barred) or a new
  Hex dep (SC-008 says zero).
- *A `mix` task* — rejected: FR-023 requires the **default test suite** to fail.
- *Wallaby/Playwright visual checks* — rejected: FR-024 bars a browser.
- *Inventory as a code comment block* — rejected: FR-026 requires a reviewable
  artifact; a comment is not reviewable independently of the code it annotates.

---

## 7. Resolved Technical Context

| Unknown | Resolution |
|---|---|
| Language/version | Elixir 1.20.2 / OTP 28 via `mise exec --` (unchanged) |
| New dependencies | **none** — CSS custom properties + ExUnit only |
| Frontend toolchain | **none added** — hand-authored CSS, vendored 7-line `app.js` untouched |
| Storage | untouched; this feature reads no new state and writes none |
| Testing | ExUnit; new pure `DesignContract` scanner in `test/support` |
| Reduced motion | one `@media` block + two contract-defined static markers (§3) |
| Status color transport | `data-status` / `status-<name>` classes; CSS owns all values (§2) |
| Gauge threshold | contract's 80% warning; `tripped` from `Ledger.tripped?` (§2a) |
| Deliberate divergences | exactly one — the reserved-spend hatch (§5) |
