# Implementation Plan: Operator Console UX Polish

**Branch**: `033-console-ux-polish` | **Date**: 2026-10-07 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/033-console-ux-polish/spec.md`

## Summary

Fix the 28 audit findings on the LiveView operator console without adding a
dependency, a build step, or persisted state. Most are template and CSS
changes. The rest is a small set of pure view modules that make each fix
testable outside a LiveView:

- `RunSettingsView`: an allowlisted settings record, with no `inspect/1`.
- `RunStateView`: run state to status-name mapping, plus status counts.
- `TranscriptMarkup`: an escape-first, in-tree markdown subset renderer.
- `StartConfirm`: the inline two-step supersede confirmation.
- `ConfigDiff`: unsaved-change tracking, cent-precise budget, apply echo.
- `phase_position/1`: the `phase · n/7` label.

The `__given__` leak has a precise root cause: misplaced `attr` declarations
at `run_detail_live.ex:408-410` make `settings_chips/1` a function component
(research R1).

Planning found one conflict with the spec. The shipped tokens cannot meet
WCAG AA as FR-038 was written. The operator chose to amend three token
values and to scope the non-text rule WCAG 1.4.11-style (research R8,
spec Clarifications). The design-contract guard gains four rules and no
relaxation (`contracts/design-guard-extensions.md`).

## Technical Context

**Language/Version**: Elixir 1.20.2 on OTP 28.5.0.6 (mise-pinned)

**Primary Dependencies**: Phoenix ~> 1.7, Phoenix LiveView ~> 1.0, Bandit, phoenix_pubsub. No new dependency (research R4).

**Storage**: N/A. No new or changed Mnesia tables. Reads existing run state through the `Autonomous` facade.

**Testing**: ExUnit, `Phoenix.LiveViewTest` with `lazy_html`, StreamData (property test for `TranscriptMarkup`), and the design-contract guard (`test/support/design_contract.ex`).

**Target Platform**: Operator browser (desktop 1440×900 primary, 390×844 status-check), served by the orchestrator node or its container.

**Project Type**: Server-rendered web console inside an OTP application.

**Performance Goals**: Transcript render under 50 ms for a 200 KB transcript (single linear pass). No added PubSub traffic: Trigger reuses the existing `:reconciled` tick.

**Constraints**:
- Hand-authored CSS, no Node/npm/bundler.
- Every visual literal lives in the `:root` token block.
- Status color travels only as a `data-status` name.
- Mono/sans roles.
- No friendly renames.
- `phase_strip/1` render stays byte-identical (015 golden test).
- Strict-run surfaces stay byte-identical for containment (030 contract).

**Scale/Scope**: 8 views, 3 components, 1 stylesheet (2461 lines), 6 new pure modules, 1 design-constitution value amendment.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | How |
|---|---|---|
| I. Pure core, isolated contracts | Pass | Core modules untouched. New logic is pure web-side modules with gate inputs passed in. |
| II. Fail loud | Pass | A budget with more than 2 decimals is refused, not rounded (R16). Unknown run states map visibly to `pending`, never crash or hide (R7). |
| III. Containment | Pass | No containment change. The permissive CONTAINMENT block is kept and de-duplicated. A strict run's surface stays byte-identical (R2). |
| IV. Cost-bounded | Pass | The gauge still separates committed and reserved, and the label now does too (R12). No ledger change. |
| V. Human in the loop | Pass | No gate change. Superseding a run gains an explicit confirmation that names the run (R10). |
| VI. Idiomatic Elixir | Pass | Pure transforms, multi-clause functions, `@spec` on public functions. LiveViews stay thin shells. |
| VII. Operator surfaces tell the truth | Pass, with amendment | Real identifiers are kept: chips show `:in_flight`. Receipts are kept: the URL holds `?run_id=` and the toast echoes the call. The nav stays one persistent rail at narrow widths. Motion is unchanged. Three token values change to meet contrast. That is an amendment of `docs/design-constitution.md` §II under Governance (see below), not a deviation. |
| Tech stack: no new dependency or build step | Pass | Markdown subset in-tree (R4). Clipboard copy is five lines in vendored `app.js` (R18). |
| Quality: guard never relaxed | Pass | Four new rules. Allowlist growth is named in the contract. |

**Governance action.** Amending `docs/design-constitution.md` §II values is an
amendment of the constitution's design surface (Operator Surface Design, "The
doc MUST be committed"). It lands in the same change with:

- a Sync Impact Report prepended to `.specify/memory/constitution.md`;
- a **PATCH** bump, 6.0.1 → 6.0.2. No principle or MUST changes. Three
  referenced values move to satisfy an accessibility floor the principles
  already imply ("legibility at a glance"). This follows 6.0.1's precedent of
  a clarification with no MUST added or relaxed.

**Post-design re-check (after Phase 1):** pass. The design adds no state, no
dependency, and no new status color. The rail stays persistent (§VII.1). The
confirmation is inline, not a modal (§VII.4 consequence hint). Breaker state
appears once (§VII.2).

## Project Structure

### Documentation (this feature)

```text
specs/033-console-ux-polish/
├── spec.md
├── plan.md              # this file
├── research.md          # R1–R19 decisions
├── data-model.md        # pure view projections, token table
├── quickstart.md        # validation guide
├── contracts/
│   ├── console-surfaces.md          # per-view observable contract
│   └── design-guard-extensions.md   # guard rule/allowlist changes
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks (not created here)
```

### Source Code (repository root)

```text
lib/autonomous/web/
├── run_settings_view.ex          # NEW  R1–R3
├── run_state_view.ex             # NEW  R7, FR-031
├── transcript_markup.ex          # NEW  R4–R5
├── start_confirm.ex              # NEW  R10
├── config_diff.ex                # NEW  R16
├── components/
│   ├── core_components.ex        # phase_position/1, cost_gauge label, status_chip for runs
│   ├── feature_drawer.ex         # phase_position, width min(460px,100vw)
│   ├── layouts.ex                # nav label, clock truncate, repo basename
│   └── layouts/
│       ├── root.html.heex        # favicon data:, drop preloads
│       └── app.html.heex         # compact rail, topbar wrap, copy button
└── live/
    ├── run_detail_live.ex        # attr fix, record block, chips, btn-link
    ├── runs_live.ex              # state chips, status counts, console-input
    ├── transcripts_live.ex       # run selector, TranscriptMarkup
    ├── trigger_live.ex           # console-input, groups, StartConfirm, PubSub
    ├── config_live.ex            # ConfigDiff, number budget, sticky bar, record block
    ├── mission_control_live.ex   # status strip, phase_position, event feed
    ├── pipeline_dag_live.ex      # grid cards, legend, wave label
    └── escalations_live.ex       # empty-state hierarchy, format_value

priv/static/assets/
├── console.css                   # tokens, .console-input, 760px block, components
└── app.js                        # phx:copy listener

docs/design-constitution.md       # §II three values + rationale
.specify/memory/constitution.md   # Sync Impact Report, 6.0.2

test/support/design_contract.ex   # 4 rules, allowlists, @contract_colors
test/autonomous/web/
├── design_contract_test.exs      # fires/does-not-fire pairs
├── run_settings_view_test.exs    # NEW
├── run_state_view_test.exs       # NEW
├── transcript_markup_test.exs    # NEW (incl. StreamData property)
├── start_confirm_test.exs        # NEW
├── config_diff_test.exs          # NEW
└── *_live_test.exs, layout_test.exs  # updated to contracts/console-surfaces.md
```

**Structure Decision**: Single OTP application. The new pure modules sit in
`lib/autonomous/web/` beside the components that consume them. They are web
projections, not pure core, so Principle I's core list is unchanged. The
design-guard `@surfaces` list globs `live/*.ex`, so the new top-level web
modules are added to it explicitly when they emit markup (only
`TranscriptMarkup` does).

## Delivery order

1. **Governance and guard first**: token amendment, constitution PATCH, and
   the guard rules. Red-green, so every later step is checked.
2. **US1 truthful data** (P1): `RunSettingsView`, `RunStateView`,
   `TranscriptMarkup`, then Run Detail, Runs and Transcripts.
3. **US2 Trigger** (P1): `.console-input` migration, option groups,
   `StartConfirm`.
4. **US3 narrow** (P1): 760px block, compact rail, stacked rows, drawer width.
5. **US4 above the fold** (P2): gauge label, clock, status strip,
   `phase_position`, feed.
6. **US5 Configuration** (P2): `ConfigDiff`, number budget, sticky bar,
   record block, titles.
7. **US6/US7 polish** (P3): Pipeline Chain, labels, sidebar path, empty
   state, favicon, preloads.
8. **Docs**: update `CLAUDE.md` Console paragraph (token amendment, new guard
   rules); `docs/runbook.md` gets a note that Trigger now confirms supersession.

## Complexity Tracking

| Deviation | Why needed | Simpler alternative rejected because |
|---|---|---|
| In-tree markdown renderer (~200 lines) instead of a library | FR-004/005 need formatting with inert HTML. Constitution requires dependency justification. | Earmark passes raw HTML by default. MDEx adds a Rust NIF. A JS renderer needs a build step or moves logic out of tested Elixir (R4). |
| Three token values changed in the design constitution | FR-038 AA contrast cannot be met by the shipped `--text-faint`, `--pending`, `--blocked` | Exempting them leaves eyebrows and slate chips below AA. A literal FR-038 (solid chip borders, raised borders) is a bigger amendment with no information gain (R8, operator decision). |
| Second media-query width (760px) beside 1120px | US3 needs a narrow layout. Custom properties cannot be used in `@media`. | A single shared breakpoint cannot serve both the 1120px mission-grid collapse and phone width. The guard pins the allowed widths instead (G-breakpoint). |
| Pipeline Chain vertical connector dropped in the grid | FR-027 needs the available width | A wrapped grid with drawn connectors needs absolute positioning per card. The existing "stacks on {base}" line already states the relation in text. |
