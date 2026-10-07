# Contract: Console Surfaces (033)

The console's external interface is what an operator sees and does. This
contract fixes the observable behaviour each view must have after 033. Tests
assert on the `data-*` hooks named here, never on CSS classes alone.

Notation: **MUST** items map to the spec FR in brackets.

## Global chrome (`layouts/app.html.heex`, `layouts.ex`)

| Element | Contract |
|---|---|
| Nav labels | `Mission Control`, `Pipeline Chain`, `Trigger Run`, `Escalations`, `Runs`, `Transcripts`, `Configuration`. Each equals its view's `page_title` [FR-028]. |
| Nav at ≤760px | Same items, same order, single level, persistent. Each item renders a short mono label, `aria-label` and `title` set to the full label. The active item keeps `nav-active`. Badges stay visible [FR-015]. |
| Short labels | `MC` `PC` `TR` `ES` `RU` `TX` `CF`. These abbreviate nav labels, not system identifiers, so §I.3 does not apply. |
| Topbar gauge | `data-band` ∈ `safe warning tripped`. Visible label `$<committed> + $<reserved> / $<budget>`, mono, outside the bar. No `armed`/`tripped` word inside the gauge [FR-017]. |
| Breaker chip | Unchanged; the one place the breaker word appears. |
| Clock | `#console-clock` text matches `^\d{2}:\d{2}:\d{2} UTC$` [FR-018]. |
| Sidebar repo | `data-repo-path` = full path. Visible text = `Path.basename/1`, one line, ellipsized. `title` = full path. A copy button `data-copy` copies the full path [FR-029]. |
| Head | `<link rel="icon" href="data:,">`. No `rel="preload"` font links [FR-034]. |

## Mission Control

| Element | Contract |
|---|---|
| Status strip | One row `data-status-strip`. One cell per status in `@status_order`, `data-status={name}`, count in mono. Zero counts carry `data-zero` [FR-019]. |
| Feature row | Phase pips (`phase_strip/1`, byte-identical) plus `data-phase-position` text `<phase> · <n>/<total>` [FR-020]. |
| Feature row ≤760px | id, status chip, phase position and spend visible; slug and elapsed hidden; no horizontal page scroll [FR-016]. |
| Feed row | `time`, `.status-dot[data-status]`, mono `data-feature-id` text, sans predicate. Newest first [FR-021]. |

## Pipeline Chain

| Element | Contract |
|---|---|
| Cards | Grid, ≥2 columns at 1440px. No positional ordinal element. Feature id is the only identifier [FR-027]. |
| Legend | One item per status present in the chain, plus the ad-hoc item only when an ad-hoc feature is present [FR-027]. |
| Wave picker | Visible `<label for>` on its `<select>` [FR-027]. |

## Trigger Run

| Element | Contract |
|---|---|
| Controls | Every `select` and text-like `input` has class `console-input` [FR-009]. |
| Option groups | Three `<fieldset data-option-group>`: `auto_remediation`, `interactive_clarify`, `containment_profile`. Each has a visible title. One control per row. Labels are the real option names [FR-013]. |
| Clarify dependents | `answer_timeout_min` and `max_rounds` are absent from the DOM while `interactive_clarify` is off; present, with their defaults, once on [FR-012]. |
| Backlog summary | Labels: `Breakdown package`, `Source`, `Feature count`, `DAG validated`, `Run shape`, `Budget`. `Source` shows the path relative to the served repo, no leading `…`, full path in `title` [FR-032]. |

### Start actions [FR-010, FR-011]

Both `start_backlog` and `start_single_spec` follow `StartConfirm` (data-model §3).

| Condition | Button | Hint | Extra control |
|---|---|---|---|
| no active run | normal label | none | none |
| active run, idle | normal label | none | none |
| active run, armed | `Supersede <run_id> and start`, `data-confirm-armed` | mono: `drains and supersedes <run_id>` | `Cancel` (`phx-click="cancel_start"`), secondary style |

- The second click while armed dispatches exactly as today.
- The server re-checks `active_run_id` on every click. A client cannot dispatch
  from `:idle` while a run is active.
- No `data-confirm` attribute and no modal anywhere.

## Escalations

| Element | Contract |
|---|---|
| Empty state | `.empty-state-title` uses `--fs-card-title` weight 600; body uses `--fs-body` `--text-muted` [FR-030]. Copy unchanged. |
| Context chips | Values rendered by `RunSettingsView.format_value/1`, never `inspect/1`. |

## Runs

| Element | Contract |
|---|---|
| State chip | `<span class="status-chip" data-status={RunStateView.status(state)}>` with text `RunStateView.label(state)` (e.g. `:in_flight`) [FR-008]. |
| Feature column | `data-status-counts`: one `dot + mono count` per non-zero status, in `statuses/0` order. No per-feature chip list [FR-031]. |
| Filters | `console-input` (was `resume-select`). |

## Run Detail

| Element | Contract |
|---|---|
| Settings | One `<.record_block label="run settings">` of `RunSettingsView.rows/1`. No `__given__`, no `%{`, no `"`-quoted string values [FR-001–003]. |
| Containment | `containment_profile` appears only in the CONTAINMENT block, only when permissive, with its `docs/enforcement.md` pointer [FR-002]. |
| State / outcome | Status chips via `RunStateView` [FR-008]. |
| Phase rows | Standard data-table cell padding. Transcript toggle is `.btn-link` [FR-033]. |
| Inline transcript | Rendered by `TranscriptMarkup.render/1` [FR-004]. |

## Transcripts

| Element | Contract |
|---|---|
| Run selector | `<select name="run_id" class="console-input">` of the 20 most recent runs; default = active run, else latest. Change → `push_patch` to `?run_id=` [FR-007]. |
| Body | `.transcript-body` holds `TranscriptMarkup.render/1` output, mono, `--fs-transcript`, `max-width: var(--measure-transcript)` [FR-004–006]. |

## Configuration

| Element | Contract |
|---|---|
| Dirty state | Form root has `data-dirty="true"` iff `ConfigDiff.dirty?`. Sticky action bar shows `<n> unsaved`, `Apply`, `Reset` (`phx-click="reset"`) [FR-022]. |
| Budget | `<input type="number" name="budget_usd" step="0.01" min="0" class="console-input">` is the authority; the range slider mirrors it. No inline `oninput` [FR-023]. |
| Apply toast | Line 1 echoes `LiveConfig.apply(%{...})` with every changed key. Line 2 only with an active run: `applies forward-only to <run_id> · not saved as default` [FR-024]. |
| Field errors | `budget_usd`, `pr_base`, `pr_remote` and models each show `.form_refusal` next to the field; `data-dirty` stays true on rejection. |
| Instance info | Served repository and instance node in one `<.record_block>` [FR-025]. |
| Section titles | No title overlaps a border; visible titles use `.config-toggle-title`, legends are `sr-only` [FR-026]. |

## Casing rule [FR-028]

- Status and state values are always the atom text, mono (`:done`, `:in_flight`).
- View names (nav labels and page titles) are proper names in title case
  (`Pipeline Chain`). All other prose labels, section titles and buttons are
  sentence case (`DAG validated`, `Supersede r000004 and start`).
- Config keys and option names appear exactly as typed (`auto_remediation_threshold`).
