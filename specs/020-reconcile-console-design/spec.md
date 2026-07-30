# Feature Specification: Reconcile the console with the design constitution

**Feature Branch**: `020-reconcile-console-design`

**Created**: 2026-07-29

**Status**: Draft

**Input**: User description: "Reconcile the UI with design constitution"

## Context

Constitution 2.2.0 added Principle VII (Operator Surfaces Tell the Truth) and the
Operator Surface Design section, adopting `docs/design-constitution.md` as a
binding visual + interaction contract. The shipped console predates that
amendment and diverges from it. The amendment recorded the divergence as known
debt and required that it "MUST be reconciled by a recorded feature" — this is
that feature.

The divergence is not cosmetic drift; it is a **second, conflicting design
system** living alongside the contract:

- Token **names** collide with contract names while holding *different* values:
  `--border` holds the contract's `--border-subtle` value, `--border-strong`
  holds the contract's `--border` value, `--muted` holds the contract's
  `--text-faint` value, `--accent-2` (`#4b2fd6`) stands in for `--accent-deep`
  (`#5a3fe0`). A surface that asks for `--border` today gets one step too light.
- Contract tokens that exist only as **repeated literals**: `--card` (`#12151d`),
  `--raised` (`#161a23`), `--hairline` (`#14181f`), `--border-strong`
  (`#2a3142`), `--text-secondary` (`#c3c9d6`), `--text-muted` (`#8b93a7`),
  `--accent-shadow` (`#2a2350`), and all seven status colors.
- The **status palette is duplicated in three places** — the CSS literals, the
  shared component palette, and a per-view copy — so one status can drift from
  itself between representations, which is precisely what Principle VII forbids.
- Two different primary-button gradients ship (`#4b2fd6` terminus in one place,
  `#5a3fe0` in another), pure `#fff` appears as a border, a background and a text
  color, and the stylesheet's own header names the superseded, now-subordinate
  feature-local contract as its source of truth.
- Zero keyframes are defined, so "motion means live" is satisfied by having no
  motion at all: an actively-running entity's status dot is visually identical to
  a resting one, and a resting dot instead carries a decorative glow.
- Absolute prohibitions are present: centered body text in empty states, a status
  color used decoratively (a 28px `done`-green check glyph as an empty-state
  icon), status colors on non-status elements (toast borders), and pictographic
  nav glyphs.

## Clarifications

### Session 2026-07-29

- Q: Which priorities does this feature deliver? → A: All four — P1 tokens + P2 component/type compliance + P3 motion/interaction law + P4 automated guard (full Principle VII discharge in one feature)
- Q: How is compliance verified for the rules a grep cannot decide (mono/sans role split, decorative status color, shadow use, empty-state wording)? → A: Mechanical guard for what greps decide, plus a committed per-surface compliance inventory (element → contract rule → verdict) reviewable as an artifact
- Q: How does a server-rendered element get a status color without owning a copy of it? → A: Status-scoped classes only — server code emits the status name, the stylesheet owns every color/alpha; no color-bearing inline style survives anywhere
- Q: Under a reduced-motion preference, how does live-vs-resting survive without animation? → A: Static live marker — the animation stops, an existing non-animated treatment (active-node accent ring / filled pip) keeps "active" readable at a glance
- Q: Where a contract component or signal has no implementation today, does reconciliation add it? → A: Yes — adopt the contract's form for anything the console already shows (persisted artifact → record block, live stream → blink indicator, pip → phase+state title). No new views, no new data.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One authoritative token set (Priority: P1)

An operator opens any console view. Every color, and every value the contract
fixes, resolves to a single definition whose name and value match
`docs/design-constitution.md`. A maintainer changing a contract value edits one
place and every surface — stylesheet rule, shared component, per-view markup —
follows, because none of them carries its own copy.

**Why this priority**: This is the recorded debt, and it is the foundation: the
component, motion and interaction rules below are all expressed in these tokens.
It also removes the active hazard — same token name, different value — that makes
every later change unsafe.

**Independent Test**: Load each console view and confirm no color, radius or font
size is produced by a literal outside the single token declaration; confirm each
contract token exists under its contract name with its contract value; confirm a
status renders the same color in every representation of that state because all of
them read one definition.

**Acceptance Scenarios**:

1. **Given** the contract's token tables, **When** the console's token
   declaration is compared against them, **Then** every contract token is present
   under its contract name with its contract value, and no token holds a value
   belonging to a different contract token.
2. **Given** a status (e.g. `escalated`), **When** it is rendered as a dot, a
   chip, a phase pip, a DAG node border and a timeline node, **Then** all five
   resolve to the same single status definition.
3. **Given** a maintainer changes one status value in the single source, **When**
   the console is reloaded, **Then** every representation of that status changes
   with it and none keeps the old value.
4. **Given** any console surface, **When** it needs a color, radius, font size or
   spacing step the contract fixes, **Then** it consumes the token rather than a
   literal.

---

### User Story 2 - Surfaces obey the color, type and component specs (Priority: P2)

An operator scanning the console reads it as one system: four text steps used by
role, machine values in mono and prose in sans, chips and dots and phase pips
built to the contract's specs, and no element borrowing a status color or a
prohibited style for decoration.

**Why this priority**: With one token set in place, this is what makes the surface
actually truthful at a glance — a status color that means nothing, or a machine
value in a prose font, misleads even when the tokens are correct.

**Independent Test**: Walk every console view and check each rendered element
against the contract's §II–§V specs — surface/border/text roles, mono-vs-sans
role split, chip fill and border alphas, status dot spec, phase pip track, data
table, record block, event feed, timeline, toast, drawer — with no absolute
prohibition present anywhere.

**Acceptance Scenarios**:

1. **Given** a chip, **When** it renders, **Then** its fill is the status color at
   the contract's chip-fill alpha and its border is the status color at the
   contract's border alpha — not an opaque border.
2. **Given** any text node, **When** it is classified, **Then** machine-produced
   or operator-typed values (IDs, slugs, phases, statuses, paths, branches,
   counts, money, durations, timestamps) render mono and human prose renders
   sans, with no element mixing the two roles.
3. **Given** a constrained identifier in a narrow column, **When** it exceeds its
   width, **Then** it ellipsizes on one line rather than wrapping.
4. **Given** a phase pip track, **When** it appears in any context, **Then** it is
   an equal-width fixed-length track identical in every context, and each pip
   carries a title naming both its phase and its state.
5. **Given** any surface, **When** it is inspected for the absolute prohibitions,
   **Then** none is present: no pure `#000`/`#fff`, no background gradient, no
   second accent hue, no centered body text, no status color on a non-status
   element, no decorative pictograph, no shadow on a resting surface, no type
   below the contract's floor.
6. **Given** an ordinal (feature number, attempt, phase index), **When** it
   renders, **Then** it is zero-padded.
7. **Given** a persisted artifact shown on a surface (a checkpoint, a transcript
   path, a run record), **When** it renders, **Then** it uses the contract's
   record-block treatment rather than a bespoke box.

---

### User Story 3 - Motion and the interaction law (Priority: P3)

An operator can tell live from resting at a glance, and at a decision point sees
recovery paths ranked with their consequences and every override the API accepts
under its real option name.

**Why this priority**: These rules govern the moment the system defers to the
human — the highest-stakes rules in Principle VII — but they depend on the tokens
and components above being right first.

**Independent Test**: Observe a run with one active and several resting features
and confirm animation appears only on the active referent; open each recovery
decision point and confirm the ranking, consequence hints and override controls;
confirm the budget gauge distinguishes committed from reserved and changes color
at threshold; confirm every empty state reads as a status report.

**Acceptance Scenarios**:

1. **Given** the console, **When** its animations are enumerated, **Then** exactly
   the contract's four keyframes exist and nothing else animates.
2. **Given** a feature actively working, **When** its status dot renders, **Then**
   it pulses; **Given** a feature in a resting or terminal state, **When** its dot
   renders, **Then** it does not pulse and carries no glow.
3. **Given** a streaming transcript, **When** it is live, **Then** a blink
   indicator marks it; **When** the stream ends, **Then** the indicator stops.
4. **Given** a diverted feature, **When** its recovery actions render, **Then**
   the cheapest correct action (`resume/2`) is the primary and the expensive
   alternative (`resolve/1`) is a visually subordinate control in the same row,
   each stating its consequence in a mono hint.
5. **Given** a parked run, **When** its decision renders, **Then**
   `continue_run/1` and `end_run/1` are visually ranked and consequence-labelled,
   never one ambiguous button.
6. **Given** a recovery decision, **When** it renders, **Then** every override the
   API accepts (`:from`, `:prompt`) is exposed under its real option name,
   defaulting to what the system would choose unaided.
7. **Given** a run with committed and reserved spend, **When** the gauge renders,
   **Then** committed and reserved are distinguishable and the gauge's color
   reflects its threshold band (safe → warning → tripped).
8. **Given** no open escalations, **When** the escalations view renders, **Then**
   it states the healthy condition and why, with no call to action and no
   decorative icon.
9. **Given** any row, node or card for an entity, **When** it is clicked, **Then**
   the same detail surface for that entity opens.

---

### User Story 4 - Divergence cannot come back (Priority: P4)

A maintainer adding a surface that hard-codes a color, invents a fifth keyframe,
or trips an absolute prohibition gets a failing build rather than a review
comment, and anyone reading the console's stylesheet is pointed at the governing
contract rather than the superseded feature-local one.

**Why this priority**: Without this, the reconciliation decays exactly the way the
original design system did. It is last because the guard cannot pass until P1–P3
land.

**Independent Test**: Introduce each class of divergence in turn (a raw color
literal, a duplicated status value, a fifth keyframe, a prohibited style) and
confirm the default test suite fails and names the offending location; revert and
confirm it passes.

**Acceptance Scenarios**:

1. **Given** a surface with a raw color literal outside the single token
   declaration, **When** the default test suite runs, **Then** it fails and names
   the file and location.
2. **Given** a second definition of a status color anywhere outside the single
   source, **When** the suite runs, **Then** it fails.
3. **Given** a keyframe that is not one of the contract's four, **When** the suite
   runs, **Then** it fails.
4. **Given** a clean tree, **When** the suite runs, **Then** the compliance check
   passes and adds no dependency on a browser, a network call or a build step.
5. **Given** the console stylesheet, **When** its header is read, **Then** it
   cites `docs/design-constitution.md` as governing, and the feature-local 011
   contract is referenced only as a historical record.

---

### Edge Cases

- **A shipped value has no contract counterpart** (an off-palette surface, border
  or text color used once). It MUST be mapped to the contract token closest in
  role, and any value kept deliberately outside the contract MUST be recorded in
  Complexity Tracking with its reason. It MUST NOT survive as an unexplained
  literal.
- **A token name changes meaning, not just value.** Because the shipped `--border`
  and `--border-strong` are each one step lighter than the contract's same-named
  tokens, use sites MUST be re-pointed by the role they play (row divider vs
  region divider vs card border vs interactive border), not by keeping the old
  name. A mechanical rename would shift every border by one step.
- **A status the contract does not name** (`never_started`) MUST render as a
  contract status whose meaning it shares, not as a new color.
- **A server-rendered element needs a status color** to draw a border or fill. It
  MUST name the status and let the stylesheet supply the color (FR-004a); a palette
  copy in view or component code is a violation even when its values happen to
  match, and so is emitting the color inline from a shared copy.
- **A status-derived value is computed per render** (the gauge's threshold band).
  The *band* MUST be expressed as a status/threshold class, not a computed color;
  only the fill width may be inline (FR-004b).
- **Existing tests assert literal colors, class names or glyphs.** They MUST be
  updated to assert the reconciled contract, and a test pinning a value the
  contract prohibits MUST NOT be preserved for compatibility.
- **Removing a prohibited pictograph removes information.** The information it
  carried MUST be re-expressed compliantly (a badge, a chip, a label), not
  dropped.
- **Reduced-motion preference.** Where the operator's environment asks for reduced
  motion, every contract keyframe MUST stop and the live-vs-resting distinction
  MUST survive as a static marker — the contract's existing non-animated
  treatments for an active entity (accent ring on the active node, the current pip
  in the status color) carry it. No new color, hue or component is introduced for
  this case, and the distinction MUST NOT degrade to status text alone.
- **A view is added while this feature is in flight.** It MUST be built against
  the contract tokens, per the constitution's standing rule that recorded debt is
  not a licence to add new divergence.

## Requirements *(mandatory)*

### Functional Requirements

**Single source of values (P1)**

- **FR-001**: The console MUST declare exactly one authoritative token set, whose
  names and values match `docs/design-constitution.md` §II (four surfaces, four
  borders, four text steps, five accent steps, seven status colors), with no name
  reused for a different value.
- **FR-002**: Every console surface — stylesheet rule, shared component, per-view
  markup — MUST obtain color, radius, font-family, font-size and spacing values
  from the single token set. A literal color, size or radius outside that
  declaration MUST NOT exist, and no server-side helper may emit one at all
  (FR-004a).
- **FR-003**: Each of the seven status colors MUST have exactly one definition, in
  the token set, reached by every representation of that status (dot, chip, phase
  pip, node border, timeline rail, gauge band, legend swatch). No second copy —
  including one whose values match — may exist in server-rendered code.
- **FR-004**: Values the contract does not fix (layout dimensions, view-specific
  proportions) MAY remain literal; every value the contract does fix MUST NOT.
- **FR-004a**: Server-rendered markup MUST express a status by emitting the status
  itself (a status-scoped class or data attribute), never by emitting the color it
  resolves to. Every color, fill alpha and border alpha for a status MUST live in
  the stylesheet, keyed off that status. No color-bearing inline style may remain
  on any console surface (baseline: 6 such sites — chip fill/border, escalation
  card border, card head wash, escalation dot, DAG legend swatch, gauge band).
- **FR-004b**: An inline style MAY carry only a value computed per-render that the
  contract does not fix — the budget gauge's committed and reserved fill widths
  are the sole such case. It MUST NOT carry a color, radius, font or spacing value.
- **FR-005**: The console stylesheet MUST cite `docs/design-constitution.md` as
  its governing contract;
  `specs/011-control-plane-ui-redesign/contracts/design-system.md` MUST remain
  unmodified and MUST NOT be cited as governing.

**Color, type, geometry, components (P2)**

- **FR-006**: Surface, border and text tokens MUST be applied by their contract
  role: app canvas / panel chrome / card / raised-and-hover for surfaces; row
  divider / region divider / card border / interactive border for borders;
  primary / value-and-body / description / mono-metadata for text.
- **FR-007**: Machine-produced or operator-typed values MUST render in the mono
  family; human prose MUST render in the sans family; no element may mix the two
  roles. Type sizes and weights MUST come from the contract's scale, and no text
  may fall below its floor.
- **FR-008**: Every constrained identifier MUST ellipsize on a single line; an
  identifier MUST NOT wrap. Ordinals MUST be zero-padded.
- **FR-009**: Chips MUST use the contract's fill and border alphas over the status
  color, and only the contract's permitted transparency suffixes may be used.
- **FR-010**: Status dots, chips, phase pips, data tables, record blocks, event
  feeds, timelines, toasts and drawers MUST match their contract §V specs,
  including the phase pip track being an equal-width fixed-length track, identical
  in every context, with each pip titled by phase and state.
- **FR-010a**: Where the contract specifies a component or signal for something a
  console surface already shows but the surface expresses it another way, the
  contract's form MUST be adopted rather than recorded as divergence. Named cases:
  a persisted artifact (checkpoint, transcript path, run record) MUST use the
  record-block treatment — an accent eyebrow naming the artifact path over mono
  key/value pairs; a streaming transcript MUST carry the blink live indicator; a
  phase pip MUST carry a title naming both its phase and its state. This adds no
  new view, no new route and no new data — only the contract's form for state the
  console already presents.
- **FR-011**: Toasts MUST echo the underlying call and its arguments rather than a
  vague success message, and MUST NOT take a status color as their border.
- **FR-012**: A status color MUST NOT appear on any non-status element, and no
  second accent hue may be introduced. Gradients are permitted only on the primary
  action button and the app mark, from a single contract-defined pair.
- **FR-013**: Shadow MUST be used for elevation only (drawer, toast, accent glow
  on an active node); a resting surface MUST be separated by border, not shadow.
- **FR-014**: No prohibition from the contract's §VIII may be present on any
  console surface.

**Motion and interaction law (P3)**

- **FR-015**: The console MUST define exactly the contract's four keyframes and
  MUST NOT animate anything without a live referent. An actively-working entity
  MUST be visually distinguishable from a resting one, and a resting element MUST
  NOT animate or glow.
- **FR-015a**: Under a reduced-motion preference every keyframe MUST stop, and the
  active-vs-resting distinction MUST persist through a static marker built from
  treatments the contract already defines — never through a new color, hue or
  component, and never reduced to status text alone.
- **FR-016**: Global run state — run state chip, subject, budget gauge, breaker
  status — MUST remain visible on every view, and the gauge MUST render committed
  and reserved spend distinctly and change band color at threshold.
- **FR-017**: Distinct recovery paths (`resume/2` vs `resolve/1`,
  `continue_run/1` vs `end_run/1`) MUST be visually ranked — cheapest correct
  action primary, expensive or destructive alternative subordinate in the same row
  — and each MUST state its consequence in a mono hint.
- **FR-018**: Every override the corresponding API accepts (`:from`, `:prompt`)
  MUST be exposed at the point of decision under its real option name, defaulting
  to the value the system would choose unaided.
- **FR-019**: Labels MUST use the system's real identifiers (function names,
  atoms, paths, config keys); a friendly rename of a real identifier MUST NOT
  appear.
- **FR-020**: Every asserted state MUST be traceable to a visible artifact (a
  path, a transcript, or a record ID), and progress MUST advance from recorded
  state, never from a timer standing in for it.
- **FR-021**: Clicking any row, node or card for an entity MUST open that entity's
  single detail surface.
- **FR-022**: Every empty state MUST state the healthy condition and why, with no
  call to action and no decorative icon.

**Guarding the reconciliation (P4)**

- **FR-023**: The default test suite MUST fail when a console surface introduces a
  color/size/radius literal outside the token declaration, a color-bearing inline
  style, a second definition of a status color, a keyframe outside the contract's
  four, or a mechanically detectable §VIII prohibition, and MUST name the offending
  file and location.
- **FR-024**: The compliance check MUST run hermetically in the default suite — no
  browser, no network, no build step, no new frontend toolchain.
- **FR-025**: Existing console tests MUST be updated to assert the reconciled
  contract; no test may pin a value the contract prohibits.
- **FR-026**: Every contract rule this feature claims to satisfy MUST be verified
  by one of exactly two means, and the split MUST be explicit: the mechanical
  guard (FR-023) for rules a static check decides, or a committed **compliance
  inventory** for rules it cannot. The inventory MUST record, per console surface,
  each element subject to a judgment rule, the contract rule it is judged against,
  and the verdict — so "0 prohibitions remain" is a checkable claim against a
  reviewable artifact rather than an assertion.
- **FR-027**: The compliance inventory MUST cover every rule not mechanically
  guarded, with no rule left unassigned to either means. It MUST name the surface
  and element precisely enough to re-check, and MUST record any deliberate
  divergence with its Complexity Tracking reference.

### Key Entities

- **Design token**: a named value from `docs/design-constitution.md` §II/§III/§IV
  (surface, border, text step, accent step, status color, radius, spacing step,
  type size). Has exactly one definition and one contract role.
- **Status**: one of the contract's seven run states, each owning exactly one
  color used identically in every representation.
- **Console surface**: a rendered operator view or shared component that consumes
  tokens and is subject to the contract.
- **Compliance check**: the automated guard that inspects console surfaces for
  divergence and fails the build. Covers the mechanically decidable rules.
- **Compliance inventory**: the committed artifact recording, per surface and
  element, each judgment rule the guard cannot decide and its verdict. It is the
  evidence behind every "0 remaining" claim the guard does not cover, and the
  place a deliberate divergence is declared.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of the contract's tokens exist under their contract names with
  their contract values, and 0 tokens hold a value belonging to a different
  contract token.
- **SC-002**: 0 color, radius or contract-fixed size literals remain outside the
  single token declaration across the stylesheet, the shared components and every
  view (baseline: 104 color literals in the stylesheet, 3 duplicated status
  palettes in server-rendered code, and 6 color-bearing inline styles).
- **SC-003**: Each of the 7 statuses resolves to exactly 1 definition, verified
  across every representation it has.
- **SC-004**: An operator can distinguish an actively-working entity from a
  resting one at a glance on every view where both appear, with motion enabled and
  with motion reduced; today they are visually identical in both cases.
- **SC-005**: 0 instances of any §VIII prohibition remain on any console surface,
  each prohibition evidenced either by the mechanical guard or by a verdict in the
  compliance inventory.
- **SC-006**: Every recovery decision point presents its distinct paths ranked and
  consequence-labelled, and exposes 100% of the overrides its API accepts.
- **SC-007**: Injecting any of the four guarded divergence classes fails the
  default suite in 4 out of 4 cases, and a clean tree passes.
- **SC-008**: The reconciliation adds 0 runtime dependencies and 0 frontend build
  steps, and the default suite stays hermetic.
- **SC-009**: Every console view continues to present the same information and
  routes it presents today — no capability is lost to the reconciliation.
- **SC-010**: 100% of the contract rules this feature claims are assigned to
  exactly one verification means — mechanical guard or compliance inventory — with
  0 rules unassigned and 0 claimed on assertion alone.

## Assumptions

- **Scope is the operator console**: the web views, the shared components, the
  hand-authored stylesheet and the vendored client script. The iex-rendered status
  report and the documentation are out of scope for the visual contract; they
  remain bound only by the "real identifiers" rule, which they already satisfy.
- **No redesign**: information architecture, routes, view structure and features
  stay as shipped. This feature changes how surfaces comply with the contract, not
  what they show. Where the contract's values differ from today's, the console's
  appearance will shift — that is the intent, not a regression. Adopting a contract
  component the console lacks (FR-010a) is compliance, not redesign: it re-forms
  state already on screen and adds no view, route or data.
- **No new toolchain**: no CSS framework, no bundler, no Node/npm step — the
  constitution's Frontend section forbids it, so reconciliation happens in
  hand-authored CSS and server-rendered components.
- **The feature-local 011 design contract is historical**: not rewritten, not
  deleted, no longer governing.
- **`never_started` renders as `blocked`**, the contract status whose meaning it
  shares, rather than introducing an eighth color.
- **Pictographic nav glyphs are removed**, not restyled: the prohibition on emoji
  and decorative illustration is absolute, and the nav's attention count already
  has a compliant badge. The timeline's `✓ ● ! ✕` node marks are prescribed by the
  contract and stay.
- **All four stories are in scope for this feature**: it discharges Principle VII
  in full, not just the token debt the amendment's debt note enumerated. The P1–P4
  priorities are a *delivery order* — each is independently shippable and
  independently testable, so the work can land incrementally and each increment
  leaves the console in a coherent state — but none is deferred to a later
  feature. A story is complete or the feature is not.
- **Deliberate divergence is allowed but never silent**: anything kept out of
  contract compliance MUST be recorded in the plan's Complexity Tracking with its
  reason, per Governance.
