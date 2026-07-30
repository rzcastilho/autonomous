# Implementation Plan: Reconcile the console with the design constitution

**Branch**: `020-reconcile-console-design` | **Date**: 2026-07-29 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/020-reconcile-console-design/spec.md`

## Summary

Constitution 2.2.0 adopted `docs/design-constitution.md` as a binding visual +
interaction contract and recorded the shipped console's divergence as debt that
"MUST be reconciled by a recorded feature". This is that feature, and it
discharges Principle VII in full — all four spec priorities, not just the token
debt the amendment enumerated.

The divergence is a second, conflicting design system: token **names** that
collide with contract names while holding different values (`--border` holds the
contract's `--border-subtle`, `--muted` holds `--text-faint`, `--accent-2`
`#4b2fd6` stands in for `--accent-deep` `#5a3fe0`), contract tokens present only
as repeated literals, the status palette defined in three places, zero keyframes
so "motion means live" is satisfied by having no motion, and several absolute
prohibitions in place.

**Technical approach.** One `:root` block in `priv/static/assets/console.css`
becomes the only region of any console source in which a color, radius,
font-size, or spacing literal may appear — 24 §II colors verbatim plus role-named
radius/type/spacing families and seven derived tokens the contract states in prose.
Every retired token's use site is re-pointed **by contract role**, never by
renaming, because the shipped names are each one step lighter than the contract's
and a rename would convert a loud divergence into a silent one. Status color stops
travelling through Elixir entirely: `CoreComponents` keeps labels and gains
`status_class/1`, markup emits `data-status`, and one seven-line CSS rule set maps
each status to a `--sc` custom property that every representation reads — which
retires all six color-bearing inline styles and both server-side palettes. The
four contract keyframes are defined and bound to live referents, with one
`prefers-reduced-motion` block and two contract-defined static markers carrying
active-vs-resting when motion stops. Divergence is then held out by a pure
scanner in `test/support/design_contract.ex` running in the default suite, paired
with a committed `compliance-inventory.md` for the rules a static check cannot
decide — the two together partitioning the contract with no gap.

No new dependency, no frontend build step, no new view, route, or data.

## Technical Context

**Language/Version**: Elixir `1.20.2-otp-28` via `.tool-versions`; every command
through `mise exec --` (bare PATH is a stale 1.19.5). `warnings_as_errors: true`.

**Primary Dependencies**: Phoenix `~> 1.7`, Phoenix LiveView `~> 1.0`, Bandit
`~> 1.0`, `phoenix_pubsub` — all already present. **Zero dependencies added**
(SC-008); `mix.exs`/`mix.lock` are unchanged by this feature.

**Storage**: N/A. No Mnesia table, schema version, or migration is touched. The
feature reads no state it does not already read and writes none (SC-009).

**Testing**: ExUnit. One new hermetic test
(`test/speckit_orchestrator/web/design_contract_test.exs`) over a new pure module
(`test/support/design_contract.ex`, test-env-only via `mix.exs:18`). Existing
console tests are updated where structure changes; **zero** of them currently pin
a color, glyph, or inline style (measured — `grep -rn '#[0-9a-f]\{6\}\|style=' test/`
returns nothing), so FR-025's churn is structural only.

**Target Platform**: Server-rendered LiveView console on a single-node,
machine-local BEAM; viewed in a modern desktop browser. `color-mix(in srgb, …)`
(Baseline 2023) carries the contract's hex alpha suffixes, which cannot be
concatenated onto a `var()`.

**Project Type**: Web console inside an existing OTP application — hand-authored
CSS + server-rendered components, no bundler.

**Performance Goals**: N/A — no runtime path changes. The guard is file reads and
regex over ~5.3k lines; it must not need a browser, a network call, or a build
step (FR-024).

**Constraints**: No Node/npm, no CSS framework, no bundler (constitution
Technology Stack → Frontend). Default suite stays hermetic. No new view, route,
or data (FR-010a). Information parity with today on every view (SC-009).

**Scale/Scope**: 8 LiveViews + 3 component modules + 2 layout templates (3305
LOC) + a 2050-line stylesheet with 267 classes. Measured baseline to drive to
zero: **99 color literals outside `:root`** + 4 `rgba()`, **14 hex literals in
server code**, **6 color-bearing inline styles**, **3 status palettes**, **50
retired-token use sites**, **0 keyframes**, **0 reduced-motion blocks**.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

Evaluated against `.specify/memory/constitution.md` v2.2.0.

| Gate | Verdict | Basis |
|---|---|---|
| **I. Pure Core, Isolated Contracts** | ✅ PASS | No pure-core module is touched. The one new module is a pure scanner in `test/support`, off the runtime path entirely; `status_class/1` is a pure total function on an atom. No decision surface gains I/O. |
| **II. Fail Loud at Boundaries** | ✅ PASS — strengthened | FR-023 adds a loud build failure for a class of divergence that previously produced only a review comment. The guard's surface list is **enumerated, not globbed**, with a coverage test — two prior features in this repo shipped glob defects in artifact gates, so a new console surface cannot escape by simply existing. `status_class/1` folds an unknown status to `pending` rather than raising: a console is an observability surface and must not crash a view over an unexpected status, and the loud-failure obligation sits on the store and pure core, not the renderer. |
| **III. Least-Privilege Containment** | ✅ N/A | The enforcement pack, scope guard, and per-phase permissions are untouched. |
| **IV. Cost-Bounded Autonomy** | ✅ PASS — strengthened | FR-016 fixes a live misreport: the gauge must render committed and reserved **distinctly**, because Principle IV accounts for both and a merged gauge misstates the breaker's headroom. The band moves from a hardcoded 90% guess to `Ledger.tripped?` — recorded state — plus the contract's 80% warning. No accounting logic changes. |
| **V. Human-in-the-Loop Escalation** | ✅ PASS — strengthened | FR-017/FR-018 rank `resume/2` against `resolve/1` and `continue_run/1` against `end_run/1` with mono consequence hints, and expose `:from`/`:prompt` under their real option names. Gate semantics, retry rules, and worktree retention are untouched. |
| **VI. Idiomatic Elixir/OTP** | ✅ PASS | The scanner is pure functions over a `%{path => source}` map — no GenServer, no process state, no I/O outside `load/1`. `status_class/1` and `label/1` are multi-clause with a total fallback and carry `@spec`. `gauge_color/2` becomes `gauge_band/2` returning an atom, moving a presentation decision out of a color string. `mix format` mandatory. |
| **VII. Operator Surfaces Tell the Truth** | ✅ PASS — this is the discharge | All four spec priorities land: one token set (FR-001–005), component/type compliance (FR-006–014), motion + interaction law (FR-015–022), automated guard (FR-023–027). The one deliberate divergence is recorded below. |
| **Technology Stack → Frontend** | ✅ PASS | Hand-authored CSS, server-rendered LiveView, vendored 7-line `app.js` untouched. No Node, no npm, no bundler, no CSS framework. `mix.exs`/`mix.lock` unchanged. |
| **Technology Stack → Persistence** | ✅ N/A | No table, transaction, storage type, or schema version touched. |
| **Operator Surface Design → precedence** | ✅ PASS | `docs/design-constitution.md` supplies every value. One doc-internal conflict (§IV vs §V on pip radius) is resolved in favour of the more specific §V and **recorded** below rather than resolved silently. |
| **Operator Surface Design → values in one place** | ✅ PASS | The `:root` block is the single declaration; the guard enforces that no surface holds a copy. |
| **Operator Surface Design → 011 subordinate** | ✅ PASS | `specs/011-control-plane-ui-redesign/contracts/design-system.md` stays byte-unmodified and is cited as history only; the guard's `:frozen_artifact` rule holds it. |
| **Quality & Test Discipline** | ✅ PASS | `mise exec --` throughout; `warnings_as_errors` respected; the guard is in the default suite and hermetic (no browser, network, store, or `--include integration`); the scanner's rules are unit-tested to the >90% bar with positive and negative cases each. |
| **Development Workflow** | ✅ PASS | One feature, one worktree, `feature/020-reconcile-console-design`; scaffold travels in; no `specify init` inside a worktree. |

**Post-design re-check (after Phase 1)**: unchanged — all gates still PASS. The
Phase 1 artifacts introduced no new dependency, no runtime module, no persisted
state, and no second source of values. One deliberate divergence was identified
during design and is recorded in Complexity Tracking; it was not present in the
pre-design assessment because it emerges only from reading §VII.3 against §II/§VIII
at implementation grain.

## Project Structure

### Documentation (this feature)

```text
specs/020-reconcile-console-design/
├── plan.md                      # This file
├── spec.md                      # Feature specification (input)
├── research.md                  # Phase 0: measured baseline + every decision
├── data-model.md                # Phase 1: token set, status transport, verification artifacts
├── quickstart.md                # Phase 1: runnable validation scenarios
├── compliance-inventory.md      # Phase 2 deliverable (FR-026/027) — NOT created by /speckit-plan
├── contracts/
│   ├── token-set.md             # The authoritative token declaration
│   ├── status-transport.md      # Server → stylesheet status contract (FR-004a/b)
│   └── design-guard.md          # The mechanical guard's closed rule set
└── tasks.md                     # Phase 2 output (/speckit-tasks — NOT created by /speckit-plan)
```

`compliance-inventory.md` is listed here because FR-026 makes it a **committed
artifact of this feature**, not a plan artifact: it records per-surface verdicts
that only exist once the surfaces are reconciled, so it is authored during
implementation and lands in this directory.

### Source Code (repository root)

```text
priv/static/assets/
├── console.css                  # REWRITTEN: single :root token block + role-repointed rules
└── app.js                       # UNCHANGED (7 lines, 0 literals) — in the guard's input domain

lib/speckit_orchestrator/web/
├── components/
│   ├── core_components.ex       # @palette loses colors → label/1 + status_class/1;
│   │                            #   status_pill → status-chip w/ data-status;
│   │                            #   gauge_color/2 → gauge_band/2; record_block/1 added
│   ├── feature_drawer.ex        # timeline + checkpoint/PR blocks → record-block treatment
│   ├── layouts.ex               # @nav_glyphs + nav_glyph/1 REMOVED (pictographs)
│   └── layouts/
│       ├── app.html.heex        # nav without glyphs; context strip health decolored
│       └── root.html.heex       # unchanged but scanned
└── live/
    ├── mission_control_live.ex  # parked-run decision ranked + consequence hints;
    │                            #   .field-error reuse replaced by data-state="parked"
    ├── pipeline_dag_live.ex     # legend swatch inline style → [data-legend-status];
    │                            #   active-node accent ring (reduced-motion marker)
    ├── escalations_live.ex      # status_color/1 REMOVED; 4 inline styles → data-status;
    │                            #   3 button pictographs removed; resume/resolve ranked
    ├── runs_live.ex             # chip + table compliance
    ├── run_detail_live.ex       # record blocks for run record / transcript paths
    ├── transcripts_live.ex      # scBlink live indicator bound to unterminated attempt
    ├── trigger_live.ex          # .field-error → record-block refusal treatment
    └── config_live.ex           # config values mono; .field-error treatment

test/
├── support/
│   └── design_contract.ex       # NEW: pure scanner (test env only, mix.exs:18)
└── speckit_orchestrator/web/
    ├── design_contract_test.exs # NEW: clean tree, coverage, doc transcription, 4 injections
    └── *_live_test.exs          # UPDATED where structure changed (FR-025)

docs/
└── design-constitution.md       # UNCHANGED — governing; the §IV/§V pip conflict is
                                 #   recorded here for a later amendment to fix in the doc

specs/011-control-plane-ui-redesign/contracts/design-system.md
                                 # BYTE-UNMODIFIED (FR-005; guard :frozen_artifact)

CLAUDE.md                        # UPDATED: Frontend/observability description gains the
                                 #   design contract, per the 2.2.0 Sync Impact Report's
                                 #   "Update when the reconciliation feature lands"
```

**Structure Decision**: single existing OTP project; no new directory and no new
top-level tree. The reconciliation is confined to the console surfaces enumerated
in [`data-model.md`](data-model.md) §4 plus two test files. The scanner lives in
`test/support/` rather than `lib/` because `elixirc_paths(:test)` is
`["lib", "test/support"]` (`mix.exs:18`) — that placement is what makes the lint
ship zero runtime code and add zero dependency (SC-008) while still failing the
**default** suite (FR-023).

## Complexity Tracking

Two entries. The first is a deliberate divergence from an absolute prohibition;
the second is a recorded resolution of a conflict internal to the governing doc.

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **Background gradient on the cost gauge's reserved band** — `--hatch-reserved: repeating-linear-gradient(45deg, …)`. §II/§VIII prohibit background gradients outside the primary button and app mark. | §VII.3 mandates "hatched for reserved-but-unspent", and Principle IV depends on it: the constitution says in so many words that "a gauge that merges them misreports the breaker's actual headroom". With no build step, `repeating-linear-gradient` is the only way to hatch. Where an interaction-law MUST carrying safety-relevant meaning collides with a color-decoration NEVER aimed at marketing gradients (its §I neighbours are hero sections and decorative illustration), the semantic requirement wins. Scoped to one token with one consumer and allowlisted by name in the guard. | *Two adjacent solid bars* — loses the overlap reading that shows reserved sitting on top of committed against one budget, which is the quantity the operator needs. *Reserved as an outline only* — at the small widths a real reservation produces, an outline is indistinguishable from the gauge's own border. *An SVG pattern* — same gradient primitive underneath, plus geometry moved into server-rendered markup, which FR-004a forbids. *Drop the hatch and merge* — prohibited by §VII.3 and by Principle IV. |
| **Phase pip radius resolved to §V's `2px` against §IV's "5–6px chips/pips"** — a conflict internal to `docs/design-constitution.md`. | The two sections disagree. §V is the component-specific spec for phase pips and states `radius 2px` explicitly; §IV states a range for the chip/pip *class*. The more specific rule governs, and §V's value matches the shipped `.phase-cell`, so nothing is changed by adopting it. Recorded rather than resolved silently because the Operator Surface Design section makes amending the doc a governance act: the doc itself should be corrected by a later PATCH amendment, and this entry is the pointer to that. | *Adopt §IV's 5–6px* — would change the shipped pip appearance on the authority of the *less* specific rule, and would leave §V still saying `2px`, so the conflict would survive either way. *Amend the doc inside this feature* — a doc amendment is a constitution amendment (Operator Surface Design) requiring its own Sync Impact Report and version bump; folding it into an implementation feature would bypass the Governance procedure this feature exists to honour. |

Everything else stays inside the contract. In particular, no off-palette shipped
value is kept: the `.drawer-pr` greens (`#6ee7b7`, `#1c5c3a`, `#0f2a1c`) and the
`.field-error` red (`#f43f5e14`) are **removed** rather than mapped, because both
are status-family colors on non-status elements — mapping them to a token would
preserve the prohibition (research §4b, §4c). The remaining 20 distinct
off-palette literals map cleanly to a contract token by role (research §1b).
