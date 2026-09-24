# Contract: Facade API (iex + console entry points)

The public surface lives on `SpeckitOrchestrator`. Every console action goes
through these same functions (one path, Principle VII "show the receipt").

## Run options (FR-001, FR-017)

`run/1`, `run_spec/2`, `resume/2`, `resume_run/1` and `continue_run/1`
accept three new options:

| option | type | range | default |
|---|---|---|---|
| `:interactive_clarify` | boolean | — | `false` (Config) |
| `:clarify_answer_timeout_s` | integer | 60..86 400 | 1 800 |
| `:clarify_max_rounds` | integer | 1..5 | 3 |

- `run/1` validates them in preflight. A bad value returns `{:error,
  {:preflight, [{:invalid_answer_timeout, v}]}}` (or `:invalid_max_rounds`)
  **before** any store write.
- A non-boolean `:interactive_clarify` raises `ArgumentError`.
- The resume family merges them explicit opt > recorded > Config.

## `pending_questions/0,1`

```elixir
@spec pending_questions(keyword()) :: [pending()]
@type pending :: %{
  feature_id: String.t(),
  spec_label: String.t() | nil,
  seq: pos_integer(),
  round: pos_integer(),
  max_rounds: pos_integer(),
  questions: {:numbered, [NeedsHuman.Question.t()]} | {:freeform, String.t()},
  started_at: DateTime.t(),
  deadline_at: DateTime.t()
}
```

- The function reads the current repo's current run: `:open` round rows via a
  transactional read.
- It returns `[]` when nothing waits. It never raises on an absent run.

## `answer/3,4`

```elixir
@spec answer(feature_id :: String.t(), seq :: pos_integer(),
             answers :: %{String.t() => String.t()} | keyword() | String.t(),
             opts :: keyword()) ::
  :ok
  | {:error, :not_awaiting}
  | {:error, {:stale_round, :answered | :timed_out | :breaker | :drained | :interrupted | :superseded_round}}
  | {:error, {:missing_answer, String.t()}}
  | {:error, :empty_answer}
```

1. The function builds an `AnswerSet` from the round's stored parse
   (R9) and fails before any write.
2. It calls `Writer.answer_round/3` (a guarded transaction). `seq` must be
   the open round's `seq`.
3. When the answer is committed, it sends the wake-up
   `{:clarify_answered, key}` to the repo's registered worker(s).
4. `opts[:via]` is `:console | :iex` (default `:iex`) and is recorded as
   `answered_via`.

A second submission for the same `seq` returns `{:error, {:stale_round,
:answered}}` and does nothing (SC-006).

## Resume guard

While the in-flight feature is `:awaiting_answers`, `resume/2`,
`continue_run/1` and `resume_run/1` (without `:force`) return:

```elixir
{:error, {:awaiting_answers, feature_id}}
```

With `force: true`, the call drains the waiting worker, which escalates with
`{:needs_human, :drained}`, and then proceeds as today.

## Status

- `status/0`: `per_feature[id].status` may be `:awaiting_answers`. The
  snapshot gains `awaiting: %{id => %{round, max_rounds, started_at,
  deadline_at}}`.
- `workers/0,1`: unchanged shape. A waiting worker is listed.
- `print_status/0`: STATUS prints `awaiting_answers`. An `awaiting:` line
  appears only when non-empty:
  ```
  awaiting: 007 round 1/3 waited 4m 26m left
  ```
