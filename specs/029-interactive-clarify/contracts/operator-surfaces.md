# Contract: Operator surfaces

These surfaces are governed by constitution Principle VII and
`docs/design-constitution.md`. The design guard (`design_contract_test.exs`)
must stay green (SC-008).

## Status token (design-constitution amendment)

| name | token | value | meaning |
|---|---|---|---|
| awaiting answers | `--awaiting` | `#fb923c` | Waiting on a human answer; in flight, spending nothing. |

The token is added to:

- the design-constitution status table and fenced `:root` block ("seven"
  becomes "eight")
- `console.css` `:root` and `[data-status="awaiting_answers"] { --sc:
  var(--awaiting); }`
- `design_contract.ex` `@contract_colors`, `@status_hexes` and
  `@status_names`
- `CoreComponents`: `@labels[:awaiting_answers] = "awaiting answers"`, the
  `status_class/1` guard and `statuses/0`

There is no keyframe and no animation on this status. Elixir sends only the
`data-status` name, never a value.

## Every status surface (FR-014)

| surface | shows |
|---|---|
| Mission Control row + status-count strip | pill, `round n/m`, waited, left. The row opens `/escalations#awaiting-<id>` |
| Pipeline DAG node + legend | pill colour. The legend iterates `statuses/0` |
| Runs list, Run Detail card, feature drawer | pill + waited/left |
| `print_status/0` | STATUS `awaiting_answers` + `awaiting:` line |
| run report (`Report`) | `clarify:` block when rounds exist |
| `workers/0` | listed as in flight (unchanged shape) |

Waited and left are derived from the open round's `started_at` and
`deadline_at`, using the existing elapsed-tick mechanism, not a new timer
standing in for state.

## Escalations view: "Awaiting answers" section (US1, US3)

This section renders above the diverted list, only when
`pending_questions/0` is non-empty. It is marked `data-awaiting-answers`, and
each feature block is `id="awaiting-<id>"`.

- **Header:** feature id (mono), slug (sans), `round n of m`, waited and time
  left.
- **Numbered questions:** each `Qn` gets a block with `data-question="Qn"`:
  - the question text
  - its context
  - options as chips
  - a `<textarea name="answers[Qn]">`
  - if `recommended` is set, a "Use recommended" button
    (`phx-click="use_default"`) that fills the textarea, and a note that a
    blank field takes the default
- **Freeform:** the raw block in `<pre>`, plus one `<textarea
  name="answers[*]">`.
- **Form:** `phx-submit="answer"`, hidden `feature_id` and `seq`, one submit
  button "Submit answers — re-runs clarify". The button states its
  consequence, per Principle VII.
- **Refusals:** errors (`:missing_answer`, `:empty_answer`, `:stale_round`,
  `:not_awaiting`) render via `<.form_refusal>`. `:stale_round` names the
  current outcome ("round already answered", "answer window expired", …).
- **Live updates:** the view updates on `{:console, :feature_updated, _}` with
  no manual refresh. The existing catch-all `handle_info` already refreshes.
- **Resume form:** it is not rendered for an awaiting feature, because the
  feature is not diverted. If one is reached anyway,
  `{:awaiting_answers, id}` renders "Feature is awaiting answers — answer
  above".

## Trigger form (US4)

The new controls copy the auto-remediation block:

- a switch (`phx-click="toggle_interactive_clarify"`,
  `data-interactive-clarify`)
- `<form id="interactive-clarify-form" phx-change="update_clarify">`
  containing:
  - `answer_timeout_min`: number 1..1440, `data-clarify-timeout`
  - `max_rounds`: number 1..5, `data-clarify-rounds`

Both inputs are `disabled` while the switch is off. On submit, the form
validates with `InteractiveClarify.Settings.validate/1` and refuses out of
range with `<.form_refusal>` before the run starts. `start_opts/1` converts
minutes to `clarify_answer_timeout_s`.

## Run Detail: round history (FR-015)

Each feature card gets a block `<div :if={f.clarify_rounds != []}
data-clarify-rounds>`. It has one row per round (`data-round={seq}`):

- round n/m, asked at
- questions (collapsed `<details>`)
- answers (each marked `typed` or `accepted recommended`), answered at and
  via, **or** the outcome chip (`timed out`, `breaker`, `drained`,
  `interrupted`)

A final row appears for `{:needs_human, :rounds_exhausted}`, taken from the
escalation evidence.

The settings chips already render `detail.settings`, so the three new keys
appear with no code change.
