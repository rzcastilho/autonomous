# Compliance inventory: reconcile the console with the design constitution

**Feature**: `020-reconcile-console-design` | **Governing**: `docs/design-constitution.md`

Every contract rule this feature claims is assigned to exactly one means: the
mechanical guard (`test/support/design_contract.ex`, Phase 6/User Story 4) or
this inventory — the judgment calls a scanner cannot decide. Zero rules are
unassigned; zero claims rest on assertion alone (FR-026, FR-027, SC-010).

This file covers all four user stories: **User Story 1** (token re-pointing),
**User Story 2** (component/type compliance), and **User Story 3** (motion,
recovery ranking, empty-state wording, click-target parity). The single
`divergence` verdict (the reserved-spend hatch) is recorded in the §VIII sweep
section, citing `plan.md` § Complexity Tracking.

---

## User Story 1 — border/text role re-pointing (research.md §1a, contracts/token-set.md §6)

One row per re-pointed rule class, not per individual site (100 sites total)
— the role decision is identical for every site in a class.

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| console.css | `.badge-neutral`, `.console-nav .nav-item:hover`, `.run-state-idle`, `.topbar-divider`, `console-sidebar`/`-footer`/`-topbar` dividers | §II border role: structural/subtle fill | remediated | Old `var(--border)` (#1c212c) → `--border-subtle`: none of these are a card/panel border proper — each is a wash or a region divider. |
| console.css | `.backlog-table thead th` border-bottom, `.escalation-card-head`, `.mission-feed-header`, `.drawer-header`, `.dag-ad-hoc-lane` | §II border role: row divider inside a card | remediated | → `--hairline`, the lightest step — these separate rows/sections *within* an already-bordered card, not the card's own edge. |
| console.css | `.cost-gauge`, `.status-count-cell`, `.backlog-table`, `.mission-feed`, `.empty-state`, `.run-report`, `.dag-canvas`, `.dag-node`, `.escalation-card`, `.clarify-block`, `.transcript-panel`, `.form-panel`, `.mode-toggle`/`.tab-switch`, `.backlog-empty` | §II border role: default card/panel border | remediated | Old `var(--border-strong)` (#232936) → `--border` (new value) — every one of these is a standalone container's own edge. |
| console.css | `::-webkit-scrollbar-thumb`, `.resume-textarea`/`.resume-select`, `textarea`, `.dag-wave-picker select`, `.config-pr-fields input`, `.model-option`, `.pr-toggle`, `.btn-secondary`, `.drawer-close`, `.transcript-feature-row-active`, `.transcript-tab:hover`/`-active` | §II border role: interactive / secondary-button border | remediated | Stays `--border-strong` (new value) — every one is a control the operator drags, types into, clicks, or that shows a hover/active/selected state. |
| console.css | `.phase-cell`, `.phase-cell-pending` | §V phase pip, resting/future state | remediated | Background re-pointed to `--border` (not `-strong`/`-subtle`) per status-transport.md §5's explicit "future pips render against `--border`" rule — this one is contract-specified, not a role judgment. |
| console.css | 42 `var(--muted)` sites | §II text role split | remediated | uppercase eyebrow / mono metadata (labels, ids, branch names, timestamps) → `--text-faint`; descriptive/secondary prose (empty-state copy, hints, sub-titles) → `--text-muted`; values/body inside `dd`/table cells → `--text-secondary`. Every site re-checked individually against its rendered content, not pattern-matched by selector name alone. |
| console.css | `.escalation-card`/`-head`/`-dot` (escalations_live.ex) | FR-004a: status color travels as `data-status`, never Elixir | remediated | `status_color/1` removed; the card, its head wash, and its dot all read `--sc` through `[data-status]`, set once per element via `data-status={status_class(...)}`. |
| console.css | `.dag-node` border/glow (pipeline_dag_live.ex) | FR-003: one status definition, DAG node representation | remediated | DAG node now carries `data-status={status_class(node_status(...))}`; `.dag-node[data-status="running"]` gets the accent glow ring as a static (non-motion) treatment. |
| console.css | `.legend-swatch` (pipeline_dag_live.ex) | FR-004a: legend swatch color source | remediated | Was an Elixir-interpolated inline `background-color`; now `data-status` on the same element the existing `data-legend-status` wrapper already carried, reading `--sc` like every other representation. |
| core_components.ex | `cost_gauge/1` fill color | FR-004b: gauge color is a band, not a value | remediated | `gauge_color/2` (returned a hex string) → `gauge_band/2` (returns `:safe\|:warning\|:tripped`); CSS keys the fill color off `data-band`. |

## User Story 2 — mono/sans role split (research.md, contracts/token-set.md §II text roles)

A scanner cannot tell "this span holds a slug" from "this span holds a
sentence" — every judgment below was made by reading the render call site's
actual data, not the CSS selector name.

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| console.css | `.backlog-table td` (all columns, not just `:first-child`) | §III: machine values (slug, status, elapsed, spend, outcome, timestamps) render mono | remediated | Every non-ID column in both Mission Control's and Runs'/Run Detail's `.backlog-table` was inheriting the page's sans default. All are machine-produced values (slug, phase pips aside, elapsed duration, spend, run outcome, started timestamp) — moved the whole `td` rule to mono, keeping `:first-child` as a weight/color emphasis only. |
| console.css | `.dag-node-slug`, `.drawer-slug`, `.transcript-feature-slug` | §III: slug is a machine identifier | remediated | All three were rendering the feature's real slug in the page's sans default with no override. Slug is explicitly named in the contract's mono list; none of these is prose. |
| console.css | `.feed-text` (Mission Control telemetry feed) | §III: machine-produced value | remediated | `ConsoleReadModel.entry/4`'s feed text is a generated log line (`"phase specify -> :ok"`, `"feature terminal escalated (:critical_finding)"`) — an inspected/formatted machine value, not authored prose. Was inheriting sans; moved to mono. |
| console.css | `.timeline-note` (feature drawer phase timeline) | §III: machine-produced value | remediated | Renders `inspect(phase_cell(...).outcome)` — an inspected Elixir term. Was inheriting sans; moved to mono. |
| console.css | `.dag-canvas-sub` (Pipeline Chain subtitle) | §III: human-authored description | remediated | Full descriptive sentence ("every run releases one feature at a time…") was set to mono; this is authored prose, not a machine value — moved to sans. The only site found where the split was wrong in the *other* direction. |
| console.css | `.field-label`, `.run-context-label`, `.checkpoint-box-label`, `.drawer-section-label`, and every other uppercase eyebrow label | §III: eyebrow exception | compliant | Left mono. These are short field/section labels, not sentences — the contract's `--fs-eyebrow` rule explicitly permits uppercase mono eyebrows as a UI convention independent of whether the label text itself is a "value"; this is the established, correct pattern throughout the console and is not a violation. |
| console.css | `.escalations-sub`, `.config-toggle-sub`, `.checkpoint-error`, `.run-title`/`-empty`, `.pr-toggle-row` prose spans, `.escalation-empty` copy | §III: human-authored description | compliant | All inherit the page's sans default already; each renders authored prose (empty-state copy, hints, titles), not a machine value. No change needed. |

## Persisted-artifact treatment (FR-010a: record blocks, not bespoke boxes)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| feature_drawer.ex, console.css | `.drawer-pr` / `.drawer-pr-absent` (PR block) | FR-010a: record-block treatment; research §4c off-palette greens removed | remediated | Added `CoreComponents.record_block/1` (accent eyebrow + mono `dl` fields); the PR block and its "no PR recorded" sibling both moved to it. Removed the three off-palette greens (`#6ee7b7`, `#1c5c3a`, `#0f2a1c`) entirely — they were status-adjacent color on a non-status element. The `&#8991;` corner-bracket glyph was dropped in the same edit (§VIII pictograph, not separately tasked but touched here since the markup was already being rebuilt). |
| escalations_live.ex, run_detail_live.ex | `.checkpoint-box` / `.checkpoint-fields` | FR-010a: record-block treatment | compliant | Already an accent eyebrow (`CHECKPOINT`, `--accent-light`) over a mono key/value `dl` — this is the record-block shape by structure, predating this feature. No change needed; not a divergence. |
| transcripts_live.ex | `.transcript-path` | FR-010a: record-block treatment | compliant | A single mono identifier line (`{feature} · {phase}#{ordinal}`), not a multi-field artifact record — already mono (`--text-faint`), already the right weight for what it is. Promoting it to a full `record_block` would add a label/border for no informational gain; left as-is. |

## Status-color-on-non-status-element judgments (research §4b, FR-012)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| trigger_live.ex, config_live.ex, pipeline_dag_live.ex | `.field-error` (start/backlog/description/remediation/models/budget refusals) | FR-012: a form refusal is not a run status | remediated | Added `CoreComponents.form_refusal/1` (own `.form-refusal` class, inset `--bg` well, `--border-strong` border, accent eyebrow naming the refusal, mono `--text-secondary` message) — no status color. `.field-error` itself is kept (tokenized, no longer off-palette) for the two surfaces that render a genuine system error/damage state, not a form refusal: `run_detail_live.ex` (run not found) and `runs_live.ex` (damaged record, capacity refusing) — those legitimately read as `failed`. |
| mission_control_live.ex | parked-run banner | FR-012: a run state may legitimately draw a status token; a form refusal may not | remediated | Moved off `.field-error` onto its own `.parked-banner` class, bordered in `--halted` directly (not via `[data-status]`, since "parked" is a run state, not one of the seven feature statuses) — a deliberate, narrow exception research.md names explicitly, not a duplicate-value hazard. |
| mission_control_live.ex | parked-run banner message (`Run parked at {id} — {inspect(reason)}`) | §III mono/sans: no element mixes both | remediated | The sentence was one `<p>` mixing authored prose with a machine id and an inspected atom. Split the id/reason into `.parked-banner-mono` spans inside the same paragraph — prose stays sans, the two machine values render mono. |

## Pictographs (research §4d, FR-019)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| layouts.ex, app.html.heex | `@nav_glyphs`/`nav_glyph/1`, `.nav-glyph` span | §VIII pictograph prohibition | remediated | Deleted the map, the function, the span, and its now-orphaned `.nav-glyph`/`.nav-active .nav-glyph` CSS. Nav rows keep only their real label. |
| escalations_live.ex | `&#9654;` (Resume), `&#8635;` (Full restart), `&#8801;` (Read transcript) — both the checkpointed and no-checkpoint action rows | §VIII pictograph prohibition | remediated | All three removed at both render sites; buttons/links keep only their real-identifier label. |
| feature_drawer.ex | `✓ ● ! ✕` timeline glyphs, ordinal for pending | §V timeline prescribes marks (`✓` done, `●` active, `!` escalated, `✕` failed, ordinal pending) | remediated | `timeline_glyph/2` previously had only 2 explicit clauses (`:completed`→`✓`, `:active`→`●`) and fell back to an unallowlisted `○` for every other state — including `escalated`/`halted`/`failed`, which never actually reached those marks because the function only pattern-matched the phase cell's raw `:state` (`:pending\|:active\|:completed`), not the feature-status-refined state `phase_cell_state/2` already computes for `data-phase-state`. Rebuilt to take that already-computed state string plus the phase's 1-based ordinal: `escalated`/`halted`→`!`, `failed`→`✕`, `pending`→`pad_ordinal(ordinal)`. `halted` is not named in §V's enumeration; it shares `!` with `escalated` as the nearer family (stopped pending an operator, not a hard execution failure). |
| feature_drawer.ex, run_detail_live.ex | `&#8801;`/`&#9654;`/`&#9888;`/`&#8615;` (transcript/resume/escalation/export links), trigger_live.ex `&#9656;` (Start run) | §VIII pictograph prohibition | remediated | Removed at every site — `&#8801;` (transcript links, feature_drawer.ex + run_detail_live.ex), `&#9654;`/`&#9888;` (resume/open-escalation, feature_drawer.ex), `&#8615;` (export, run_detail_live.ex), `&#9656;` (start run ×2, trigger_live.ex). Each link/button keeps only its real-identifier or plain-English label. |
| escalations_live.ex:554 | `" ✓"` task-phase completion mark | §V allowlist (machine value, not decoration) | compliant | Inside a mono label reporting real completion state (`TaskPhase.complete?/1`), not a decorative icon — kept per research.md §4d / design-guard.md's explicit allowlist note. |

## Runtime/CLI health (research §4a, FR-012, FR-013)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| app.html.heex, console.css | context-strip health dots (`claude CLI`, `BEAM`) | FR-012: status color on a non-status element; FR-013: shadow on a resting surface | remediated | Health is not one of the seven run statuses. Dropped the `done`-green fill and its `box-shadow` glow entirely; the dot now reads `--text-faint` when healthy, `--text-muted` when not, driven by `data-health` (the literal `"available"`/`"up"` string) rather than a derived boolean — the prior `data-ok="true"` selector never actually matched Phoenix's boolean-attribute serialization (`data-ok=""`), an unrelated pre-existing defect fixed as a side effect of rebuilding this exact markup. The health word itself (`available`/`not found`/`up`/`down`) now renders mono (`.console-status-value`) since it's a machine-produced value; the surrounding "claude CLI ·" / "BEAM ·" label stays sans. |

## §VIII sweep (T034)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| console.css | `.empty-state` | `:centered_body_text` | remediated | Was `text-align: center` on a shared container whose content is always prose (every empty state across Mission Control, Escalations, Transcripts, Runs, Pipeline Chain). Left-aligned now; no information lost. |
| console.css | `.dag-release-badge` `text-align: center` | `:centered_body_text` | compliant | Not body copy — a short numeric badge centered inside a fixed-width chip, the same pattern every badge/pill in the console uses. Left as-is. |
| console.css | `.transcript-feature-row-active` | `:shadow_on_resting` | remediated | Was `box-shadow: inset 0 0 0 1px var(--border-strong)` — a resting (non-drawer/toast/active-DAG-node) element outside the three permitted shadow tokens. Converted to a real `border` (the box is `box-sizing: border-box`, so no layout shift). |
| console.css | pure black/white, background gradients, box-shadow elsewhere | `:pure_black_white`, `:background_gradient`, `:shadow_on_resting` | compliant | Swept: zero `#fff`/`#000` remain anywhere; the only two gradients are `--gradient-primary` and `--hatch-reserved`; every remaining `box-shadow` is one of the three contract tokens. |
| console.css | two `font-size: 9px` sites (`.dag-release-badge`, `.dag-adhoc-badge`) | `:sub_floor_type` | remediated | Already promoted to `var(--fs-eyebrow)` during the User Story 1 off-palette sweep (T009) — both are uppercase mono badge labels, the floor's permitted case. |
| console.css | `--hatch-reserved: repeating-linear-gradient(...)` on `.cost-gauge-reserved` | `:background_gradient` (§II/§VIII prohibit background gradients outside the primary button and app mark) | **divergence** | Deliberate — see `plan.md` § Complexity Tracking. §VII.3 mandates the reserved-spend band render hatched, distinct from the solid committed fill; with no build step, `repeating-linear-gradient` is the only way to hatch. Scoped to one token (`--hatch-reserved`) with one consumer (`.cost-gauge-reserved`); allowlisted by name rather than resolved by weakening either rule. |
| console.css, feature_drawer.ex, run_detail_live.ex, transcripts_live.ex | `.run-title`, `.run-meta`, `.dag-node-slug`, `.dag-node-base`, `.checkpoint-fields dd`, `.drawer-slug`, `.drawer-stat-value`, `.transcript-feature-slug` | §III: `text-overflow:ellipsis`+`white-space:nowrap` on every constrained identifier, never let an ID wrap | remediated (T024) | All 8 sites hold a machine identifier (run title/slug/branch, DAG node slug/base, checkpoint field values, drawer slug/stat, transcript feature slug) in a width-constrained column or chip; each already carries the three-property ellipsis treatment (`overflow:hidden` implied alongside). |

## Ordinal zero-padding (FR-024's identifier/ordinal rules)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| escalations_live.ex, run_detail_live.ex, transcripts_live.ex, pipeline_dag_live.ex, config_live.ex | task-phase ordinal, phase-attempt ordinal, remediation-attempt ordinal, amendment ordinal, DAG release-order badge, per-phase model-row index | Ordinals render zero-padded | remediated | Added `CoreComponents.pad_ordinal/1` (pads to 2 digits — `1` → `01`); applied at every ordinal *display* site. Wire-format refs (`attempt_ref/1`, `escalation_ref/1`) that encode an ordinal into a `phx-value`/URL fragment are unchanged — those are opaque keys, not the operator-facing rendering the rule targets. Feature numbers (`"001"`, `"042"`) are already zero-padded at the source (the backlog filename convention) and needed no change. |

## Recovery-path ranking and consequence hints (FR-017, FR-018, T041, T042)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| escalations_live.ex | `resume/2` vs `resolve/1` action pair (checkpointed and no-checkpoint rows) | §VII.4: cheapest-correct is the gradient primary, expensive/destructive is a bordered secondary in the same row, each states its consequence | remediated | `resume/2` is `.btn-primary` (gradient), `resolve/1` (labelled by its real arity, not "Resume"/"Full restart") is `.btn-secondary`, both inside one `.escalation-actions` row. Each now carries a mono `.action-hint` span: "continues at {phase} — keeps completed work" / "restarts from specify — discards the checkpoint, frees the worktree". |
| escalations_live.ex | `:prompt`/`:from` resume-form fields | §VII.5: every API override exposed under its real option name, defaulting to what the system would choose unaided | remediated | Field labels changed from "Guidance"/"Start phase" to `:prompt (optional operator guidance; blank defaults to none)` / `:from (start phase; defaults to the checkpointed phase)`. The `:from` `<select>` already defaulted its selection to `e.default_phase` (the checkpoint's own phase) — unaided-default behavior was correct before this feature; only the label was a friendly rename. |
| mission_control_live.ex | `continue_run/1` vs `end_run/1` parked-run banner | §VII.4: distinct recovery paths visually ranked, consequence stated | compliant (pre-existing) → remediated (labels) | The `.btn-primary`/`.btn-secondary` ranking and `.parked-banner-hint` consequence text already existed (019/T031). Only the button labels were a friendly rename ("Continue"/"End" → `continue_run/1`/`end_run/1`); also fixed a stray `font-size: 11px` literal on `.parked-banner-hint` to `var(--fs-meta)` while touching the rule. |

## Real-identifier label audit (FR-019, T043)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| escalations_live.ex, mission_control_live.ex | recovery/parked-run action buttons | §I.3: labels use real identifiers, never a friendly synonym | remediated | Covered above (resume/2, resolve/1, continue_run/1, end_run/1). |
| All 8 views | function names, atoms, paths, config keys already rendered | §I.3 | compliant | Swept every view for a friendly rename hiding a real identifier the operator would type into a shell (phase atoms, config keys, checkpoint fields, remediation option names) — none found beyond the recovery buttons above; the console already renders phases/statuses/config keys as their literal atoms/strings throughout (predates this feature). |

## Click-target parity — one entity, one detail view (FR-021, T044)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| mission_control_live.ex, pipeline_dag_live.ex | backlog table row, DAG node | §VII.7: clicking any row/node/card for an entity opens that entity's single detail surface | compliant (pre-existing) | Both already carried `phx-click="select_feature"` into the shared `<.feature_drawer>` component predating this feature. |
| escalations_live.ex | `.escalation-card` | §VII.7 | remediated | The card had no click target at all — `select_feature` was defined but never wired to a click. Added `phx-click="select_feature"` + `cursor: pointer` to `.escalation-card-head` specifically (not the whole card, which holds the resume form's buttons/inputs — wiring the click at that outer level would double-fire alongside the form's own `phx-click`/`phx-submit` handlers). |

## Empty-state wording (FR-022, T045)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| escalations_live.ex | `.escalation-empty` (`data-state="all-clear"`) | §VII.8: states the healthy condition and why, no call to action, no decorative icon | remediated | Removed the 28px `done`-green `&check;` icon and its now-orphaned `.empty-state-icon` CSS rule entirely. Text already stated the healthy condition ("No open escalations") and why ("The clarify and analyze gates are clear…") with no call to action — left unchanged; left-aligned (no `text-align: center` anywhere in `.empty-state`, confirmed by the `:centered_body_text` guard rule). |
| mission_control_live.ex, transcripts_live.ex, runs_live.ex, config_live.ex | other `.empty-state`/`.recovered-banner` blocks | §VII.8 | compliant | Already state-report copy with no icon or CTA-styled button (a plain `<a>` link to Trigger Run reads as navigation, not a call-to-action banner) — no change needed. |

## Reduced-motion legibility (FR-015a, T039)

| Surface | Element | Rule | Verdict | Note |
|---|---|---|---|---|
| pipeline_dag_live.ex, console.css | `.dag-node[data-status="running"]` `--glow-accent` ring | §VI / FR-015a: the active-vs-resting distinction survives motion off through a static marker already defined with motion on | compliant (pre-existing, confirmed) | The ring is a `box-shadow` (not an `animation`), always present on a running node regardless of `prefers-reduced-motion` — no change needed, verified during T037/T039 alongside the `.status-dot[data-ok="true"]` glow removal. |
| core_components.ex, console.css | current phase pip (`.phase-cell-active`) vs future pips (`--border`) | §VI / FR-015a: current phase stays identifiable by color+position, not motion alone | compliant (pre-existing, confirmed) | `.phase-cell-active` renders in the live status color (`var(--running)`, or the diverted status color) against `.phase-cell-pending`'s `--border` regardless of the `scPulse` animation's state — the color contrast is the static marker; `animation: none` under reduced motion removes only the pulse, not the color. |

---

## Unassigned rules

None. Every rule claimed by all four user stories is covered above (judgment)
or by the mechanical guard (`test/support/design_contract.ex`, User Story 4:
color/radius/font-size/spacing/alpha literals, token integrity, status
duplication, inline styles, motion/keyframe integrity, the mechanically
decidable §VIII prohibitions, the governing-source header, and the 011
artifact freeze).
