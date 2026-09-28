# Data Model: Interactive Clarify Answering

## Pure structs (no Mnesia, no Jido — Principle I)

### `InteractiveClarify.Settings`

| field | type | rule | default |
|---|---|---|---|
| `enabled?` | boolean | anything else raises `ArgumentError` | `false` |
| `answer_timeout_s` | pos_integer | `60..86_400`, else `{:invalid_answer_timeout, v}` | `1_800` |
| `max_rounds` | pos_integer | `1..5`, else `{:invalid_max_rounds, v}` | `3` |

- `from_context/1` accepts a `RunContext`, a string/atom-keyed map, or nil.
  An absent key falls back to the default. A present but invalid key
  errors and is never clamped.
- `RunContext` keys: `interactive_clarify`, `clarify_answer_timeout_s`,
  `clarify_max_rounds`.

### `NeedsHuman.Question`

| field | type | notes |
|---|---|---|
| `id` | `String.t()` | `"Q1"`..`"Qn"`, contiguous from 1 |
| `text` | `String.t()` | the heading line after `Qn:` |
| `context` | `String.t() \| nil` | the `**Context**:` body |
| `options` | `[String.t()]` | split on `·` / newline-bullets; may be `[]` |
| `recommended` | `String.t() \| nil` | the `**Recommended**:` body |

`NeedsHuman.parse_questions/1` returns `{:numbered, [Question.t()]} |
{:freeform, String.t()}`. If it cannot parse every item, or the ids are not
contiguous, it returns `:freeform` for the whole block. It never returns a
partial parse.

### `InteractiveClarify.AnswerSet`

| field | type |
|---|---|
| `answers` | `%{qid => {:typed, String.t()} \| {:default, String.t()}}` for numbered; `%{"*" => {:typed, text}}` for freeform |

`build(parsed, raw)` returns `{:ok, t} | {:error, {:missing_answer, qid} |
:empty_answer}`. `render(t, round)` returns the prompt block (research R7).

### Decision table: `InteractiveClarify.decide/3`

| transition from `Pipeline.next/3` | `enabled?` | rounds_used < max | result |
|---|---|---|---|
| anything ≠ `{:escalated, :needs_human}` | any | any | `:pass` |
| `{:escalated, :needs_human}` | false | any | `:pass` (today's escalation) |
| `{:escalated, :needs_human}` | true | yes | `:await` |
| `{:escalated, :needs_human}` | true | no | `{:escalated, {:needs_human, :rounds_exhausted}}` |

`on_exit/1` maps a wait exit to its escalation reason:

| exit | reason |
|---|---|
| `:answer_timeout` | `{:needs_human, :answer_timeout}` |
| `:breaker` | `{:needs_human, :breaker}` |
| `:drained` | `{:needs_human, :drained}` |
| `:restart` | `{:needs_human, :restart}` |

## Feature lifecycle

```text
:pending → :running ─┬─ (clarify NEEDS HUMAN, mode on, rounds left) → :awaiting_answers
                     │        :awaiting_answers ─ answered ─→ :running (clarify re-run)
                     │        :awaiting_answers ─ timeout | breaker | drained | restart ─→ :escalated
                     └─ (existing transitions) → :done | :escalated | :halted | :failed
```

- `:awaiting_answers` is non-terminal. `Feature.terminal?/1` returns false,
  and `Writer.@terminal_statuses` does not change.
- `Release.next/3` treats `:awaiting_answers` exactly like `:running`, so
  nothing else is released.
- Round counting: `rounds_used` counts rounds opened **within one
  `FeatureRunner.run/2` invocation**, and `max_rounds` bounds that count.
  `seq` is monotonic per `{run_key, feature_id}` across invocations
  (resumes), so records never collide.

## Mnesia: `speckit_clarify_round` (new, schema v6, `disc_copies`)

| attribute | type | notes |
|---|---|---|
| `key` | `{repo_id, run_id, feature_id, seq}` | primary key |
| `run_key` | `{repo_id, run_id}` | secondary index |
| `feature_id` | `String.t()` | |
| `seq` | pos_integer | monotonic per run+feature |
| `round` | `1..max_rounds` | ordinal within the runner invocation |
| `max_rounds` | pos_integer | snapshot of the setting |
| `questions_raw` | `String.t()` | the `## NEEDS HUMAN` block verbatim |
| `questions` | `{:numbered, [map]} \| {:freeform, text}` | the parse, stored as plain maps |
| `started_at` | `DateTime.t()` | |
| `deadline_at` | `DateTime.t()` | `started_at + answer_timeout_s` |
| `outcome` | `:open \| :answered \| :timed_out \| :breaker \| :drained \| :interrupted` | |
| `answers` | map \| nil | the `AnswerSet.answers`, stored as plain data |
| `answered_at` | `DateTime.t() \| nil` | |
| `answered_via` | `:console \| :iex \| nil` | |
| `applied_at` | `DateTime.t() \| nil` | set when the clarify re-run consumes the answers |
| `closed_at` | `DateTime.t() \| nil` | set by any non-answer exit |

**Invariants** (every write is transactional):

- There is at most one `:open` row per `{run_key, feature_id}`.
- `:open` moves to exactly one of the other outcomes, once. `answer_round/3`
  and `close_round/3` both require `outcome == :open`. The loser gets
  `{:error, {:stale_round, outcome}}`.
- `answer_round/3` also requires the submitted `seq` to equal the row's
  `seq` and `now < deadline_at`.
- When a row becomes `:open`, the feature's `FeatureRun.status` becomes
  `:awaiting_answers` in the same transaction
  (`Writer.record_feature_awaiting/3`).

**Migration** `{6, "create speckit_clarify_round", &create_clarify_round/0}`
uses a frozen attribute list. It is a create, not a transform, so no
existing row is touched. `current_version/0` becomes 6.

## Changed records

| record | change |
|---|---|
| `FeatureRun.status` | adds `:awaiting_answers` (no shape change) |
| `FeatureRun.terminal_reason` | may now hold `{:needs_human, sub}` with sub ∈ `:rounds_exhausted \| :answer_timeout \| :breaker \| :drained \| :restart`. Mode off still writes bare `:needs_human` |
| `Escalation.reason` / `evidence` | same reason terms; `evidence` carries `%{questions: raw, rounds_used: n}` on `:rounds_exhausted` |
| `RunSettings.settings` | three new string keys (free-form map, no migration) |
| `Checkpoint` | unchanged shape; written with `status: :escalated, reason: :needs_human, phase: :clarify` at wait entry (R12) |

## Coordinator report

A new key `clarify_rounds: %{feature_id => [%{round, seq, outcome, asked_at,
answered_at | closed_at}]}` holds only features that opened at least one
round. It is `%{}` when the mode is off.
