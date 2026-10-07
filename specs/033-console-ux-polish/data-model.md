# Data Model: Operator Console UX Polish (033)

This feature adds **no persisted state**, no Mnesia table, and no schema
migration. Every entity below is a display-side projection over data the
console already reads. Each is computed by a pure function in
`lib/autonomous/web/` so it is unit-testable without a LiveView (Principle I,
VI). The persisted run state stays the only source of truth (Technology Stack →
Frontend).

## 1. Settings row (`Autonomous.Web.RunSettingsView`)

Projection of the recorded run settings (`RunContext.to_map/1`,
`lib/autonomous/run_context.ex:127-144`, string keys in production, atom keys
in some tests) into an ordered list for a record block.

| Field | Type | Rule |
|---|---|---|
| `key` | `String.t()` | real config key, unchanged (FR-036) |
| `value` | `String.t()` | `format_value/1` output (research R3) |

- `rows(settings :: map()) :: [{String.t(), String.t()}]`
- Only keys in `RunContext`'s documented key list are emitted (allowlist).
  Any other key, including `:__given__` and anything `__`-prefixed, is dropped.
- `containment_profile` is never emitted; the CONTAINMENT block owns it (R2).
- Atom and string forms of one key collapse to one row (string wins).
- Order: the `RunContext` key list order, so the row order is stable.
- Invariant: `length(rows) == length(Enum.uniq_by(rows, &elem(&1, 0)))` (each
  setting exactly once, SC-002).

`format_value(term) :: String.t()` never calls `inspect/1` (R3 table).

## 2. Run state chip (`Autonomous.Web.RunStateView`)

| Function | In | Out |
|---|---|---|
| `status/1` | run state atom or outcome term | one of `CoreComponents.statuses/0` |
| `label/1` | same | real identifier text, e.g. `:in_flight` |
| `status_counts/1` | `run.feature_statuses` (`%{id => status}`) | `[{status_name, count}]`, zero counts omitted, in `statuses/0` order |

Mapping: research R7. Unknown terms map to `pending`, never raise.

## 3. Start confirmation (`Autonomous.Web.StartConfirm`)

Per-action state for the two Trigger Run start actions.

```text
state  :: :idle | {:armed, run_id}
action :: :backlog | :single_spec
event  :: :click | :cancel | {:active_run, run_id | nil} | :tab_switch
```

`next(state, event, active_run_id) :: {state, :dispatch | :none}`

| From | Event | Active run | To | Effect |
|---|---|---|---|---|
| `:idle` | `:click` | `nil` | `:idle` | `:dispatch` (FR-011) |
| `:idle` | `:click` | `id` | `{:armed, id}` | `:none` |
| `{:armed, id}` | `:click` | `id` | `:idle` | `:dispatch` |
| `{:armed, id}` | `:click` | `other` | `{:armed, other}` | `:none` (re-arm on the new run, never start against an unseen run) |
| `{:armed, _}` | `:click` | `nil` | `:idle` | `:dispatch` (no run left to supersede) |
| `{:armed, _}` | `:cancel` | any | `:idle` | `:none` |
| `{:armed, _}` | `{:active_run, nil}` | — | `:idle` | `:none` (edge case: run ended while armed) |
| `{:armed, id}` | `{:active_run, other}` | — | `{:armed, other}` | `:none` |
| any | `:tab_switch` | any | `:idle` | `:none` |

`TriggerLive` keeps one state per action in `assigns.confirm`
(`%{backlog: state, single_spec: state}`). `active_run_id` comes from
`Autonomous.current_run_id/0` gated on a live Coordinator or a non-empty
`Autonomous.workers/0` (research R10), refreshed on mount and on every
`{:console, :reconciled, _}`.

## 4. Pending configuration change (`Autonomous.Web.ConfigDiff`)

| Field | Type | Rule |
|---|---|---|
| `applied` | `%{field => value}` | read from `Config` at mount and after each successful apply |
| `edited` | `%{field => value}` | form params after `phx-change` |
| `changes` | `%{field => {old, new}}` | `diff(applied, edited)`, fields equal after normalization omitted |
| `dirty?` | `boolean()` | `changes != %{}` |

- Fields: `model_<phase>` for each routed phase, `budget_usd`, `pr_base`,
  `pr_remote` (the set `LiveConfig.apply/1` accepts, `lib/autonomous/live_config.ex:88-102`).
- `budget_usd` normalization: `parse_cents/1` accepts `^\d+(\.\d{1,2})?$`;
  anything else is `:invalid` (more than two decimals is refused, not rounded).
- A rejected apply keeps `edited` and `changes` (edge case), and errors are
  keyed by field.
- `apply_echo(changes, active_run_id) :: [String.t()]` builds the toast lines:
  line 1 `LiveConfig.apply(%{budget_usd: 50.0, model_plan: "opus"})` (changed
  keys only); line 2 only with an active run:
  `applies forward-only to <run_id> · not saved as default` (FR-024).

## 5. Phase position (`CoreComponents.phase_position/1`)

`phase_position(phases :: map()) :: {phase :: atom() | nil, n :: pos_integer(), total :: pos_integer()}`

- `total = length(Pipeline.phases())`.
- Current phase: the cell whose `state` is `:active`; else the last
  `:completed`; else the first phase with `n = 1`.
- Rendered as `clarify · 2/7` in mono beside `phase_strip/1`.

## 6. Transcript document (`Autonomous.Web.TranscriptMarkup`)

Input: the `body` string of `Autonomous.transcript/1`. Output:
`Phoenix.HTML.safe()`.

Block grammar (line-based, first match wins):

| Block | Start | End |
|---|---|---|
| fence | a line whose first non-blank characters are three backticks | next such line, or end of document |
| heading | `^#{1,6}\s` | end of line |
| list item | `^(\s*)([-*+]\|\d+[.)])\s` | next non-continuation line; nesting by indent width |
| paragraph | anything else non-blank | blank line |

Inline (inside heading, list item, paragraph only): `` `code` ``, `**strong**`,
`*em*`, `_em_`. An unmatched delimiter is literal text.

Invariants (property-tested):

1. Escape first: every text run goes through `Phoenix.HTML.html_escape/1`
   before any tag is emitted; the only tags in output are the renderer's own
   (`h1–h6 p ul ol li pre code strong em`).
2. No loss: stripping the renderer's tags from the output and unescaping gives
   back every non-markup character of the input in order.
3. Total: `render/1` never raises, for any binary.

## 7. Narrow-layout and token additions

No runtime data. Recorded here because they are new named values the guard
must know (research R5, R8, R11, R19):

| Token | Value | Family |
|---|---|---|
| `--text-faint` | `#7a8296` (was `#5a6274`) | contract color |
| `--pending` | `#94a3b8` (was `#64748b`) | contract color, status |
| `--blocked` | `#828ea3` (was `#475569`) | contract color, status |
| `--border-input` | `var(--text-faint)` | derived |
| `--measure-transcript` | `96ch` | layout |
| `--rail-compact` | `52px` | layout |
| `--card-min` | `280px` | layout |
| breakpoint | `760px` | guard allowlist (not a token; media queries cannot read custom properties) |
