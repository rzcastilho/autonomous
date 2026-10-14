# Data Model: Close the Conversation Recorder Gaps

Feature 043 · Phase 1. All changes are to the conversation **file** (format
`speckit.conversation`, version 1 → 2) and to pure in-memory view state. Mnesia
records are unchanged (FR-020).

## Conversation file header (revised)

```json
{"format": "speckit.conversation", "version": 2, ...unchanged 040 fields}
```

| Reader sees | Behaviour |
|---|---|
| `version` 1 | accepted; renders exactly as 042 (no new kinds/fields exist in it) |
| `version` 2 | accepted |
| `version` ≥ 3 | `{:error, {:unsupported_version, v}}` — refused by name, nothing rendered |

## Entry kinds (revised table)

`ConversationEntry.kinds/0` gains `:usage` and `:stderr`:
`start prompt assistant_text thinking tool_call tool_result system result usage stderr other end`.

### `result` (revised body)

| field | type | change |
|---|---|---|
| `subtype` | string \| null | unchanged |
| `result` | string \| null | unchanged |
| `num_turns`, `duration_ms`, `cost_usd` | number \| null | unchanged |
| `is_error` | boolean | **rule changed**: `raw.is_error == true` **or** SDK `data.is_error == true` (R1) |
| `error` | string \| null | **new, present only when `is_error`**: SDK `data.error` (fallback `raw.error`), masked; `null` when absent/blank |

Validation: a success result never carries `error` (v1-identical body, FR-003).

### `usage` (new kind)

One per `stream_event` frame whose `event.type` is `message_start` or
`message_delta`; all other stream events still produce no entry.

| field | type | notes |
|---|---|---|
| `event` | `"message_start"` \| `"message_delta"` | |
| `message_id` | string \| absent | `message_start` only (`event.message.id`) |
| `input_tokens` | integer \| absent | absent ⇒ contributes nothing |
| `output_tokens` | integer \| absent | cumulative within the message |
| `cache_read_input_tokens` | integer \| absent | recorded, not in the figure |
| `cache_creation_input_tokens` | integer \| absent | recorded, not in the figure |
| `parent_tool_use_id` | string \| absent | scope key (R2/R5) |

Only integer fields present in the event are written (absent, never 0).

### `stderr` (new kind)

Two shapes, one kind:

| shape | body | meaning |
|---|---|---|
| line | `{"line": "<masked text>"}` | one CLI error-stream line, arrival order |
| notice | `{"notice": "dropped", "dropped": n}` | head full, `n` middle lines discarded; written once at close, immediately before the held tail lines |

Ordering in the file for a flooded session:
`…head lines interleaved with frames… → [notice] → tail lines → end`.

### `parent_tool_use_id` (new optional field)

On `assistant_text`, `thinking`, `tool_call`, `tool_result`, `other` entries
built from an `assistant`/`user` frame, and on `usage`: present iff the frame's
`raw.parent_tool_use_id` is a non-empty string.

## Recorder state (revised, in-process only)

`ConversationRecorder` state gains `stderr: StderrBound.t()`.

### `StderrBound` (new pure struct)

| field | type | notes |
|---|---|---|
| `head_cap` | pos_integer | `Config.conversation_stderr_head/0`, default 1000 |
| `tail_cap` | pos_integer | `Config.conversation_stderr_tail/0`, default 1000 |
| `emitted` | non_neg_integer | head lines emitted so far |
| `tail` | `:queue` of string | held lines, ≤ `tail_cap` |
| `held` | non_neg_integer | size of `tail` |
| `dropped` | non_neg_integer | lines evicted from `tail` |

Transitions:

```
push(line):
  emitted < head_cap            → {:emit, line}, emitted+1
  held < tail_cap               → {:held}, enqueue, held+1
  otherwise                     → {:held}, enqueue, dequeue oldest, dropped+1
flush():  → {dropped, tail_lines_in_order}   (called once, at close)
```

Invariant: emitted + held + dropped = lines pushed; ≤ head+tail pushed ⇒ dropped = 0.

## SessionStatus (extended view state, pure)

| field | type | notes |
|---|---|---|
| `usage` | `%{scopes: %{scope => msg}, done: totals}` | R2 fold; `scope` = `parent_tool_use_id` or `:main`; `msg` holds latest per-field values of the current message |
| `input_tokens` | integer \| nil | derived: done + current, `nil` until first usage entry |
| `output_tokens` | integer \| nil | same |
| `result_error` | nil \| String.t() | set by an `is_error` result: its `error`, or `"no reason given"` |
| `activity` | adds `{:result_error, text}` | replaces `{:done}` for an error result |

Fold rules for `:usage`:

```
message_start(scope):  done += scopes[scope] (if any); scopes[scope] = fields of event
message_delta(scope):  scopes[scope] = Map.merge(scopes[scope] || %{}, fields of event)
                       (replace per field — cumulative, never added)
input/output = sum(done) + sum over scopes of current values
```

Footer outcome rule (R7): `:end` chip `done` + `result_error` set ⇒ chip
`failed`, text `<outcome> · result error`; otherwise unchanged.

## Classification (additions to the 042 placement table)

| kind / shape | placement | row class | fold | label |
|---|---|---|---|---|
| `stderr` line | `:row` | `:stderr` | `:line` | `stderr` |
| `stderr` notice | `:row` | `:marker` | `:line` | `stderr` (rendered text: `stderr · <n> lines dropped`) |
| `usage` | `:signal` | `:raw` | `:line` | `usage · <event>` |
| `result` with `is_error` | unchanged `:row_signal` `:marker` `:result_error` | | | marker text gains `— <error>` / `— no reason given` |

Every new entry is a row or a signal ⇒ 042 completeness invariant holds (SC-007).

## Block (ConversationRows, revised)

`Block` gains `repeat :: pos_integer()` (default 1) for `:stderr` blocks:
consecutive `stderr` line entries with equal `line` merge into the first
block's stream key; `repeat` counts them; `seqs` keeps every merged seq for the
receipt.
