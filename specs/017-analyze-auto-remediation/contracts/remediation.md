# Contract: `SpeckitOrchestrator.Remediation` (pure decision surface)

Pure module, the analyze-loop analogue of `Pipeline.next/3` and
`Chunking.next/2`. No IO, no harness, no process state. Every signal it reads is
extracted upstream by `AnalyzeRunner` and passed in as an argument (Principle I).

## 1. Settings

```elixir
defmodule SpeckitOrchestrator.Remediation.Settings do
  defstruct enabled?: true, threshold: :high, attempt_limit: 2, model: nil

  @type t :: %__MODULE__{
          enabled?: boolean(),
          threshold: Severity.severity(),
          attempt_limit: 1..5,
          model: String.t()
        }
end
```

### `validate/1` — the single validator (FR-011, FR-010e, research R13)

```elixir
@spec validate(map() | keyword()) ::
        {:ok, t()}
        | {:error, {:invalid_threshold, term()}}
        | {:error, {:invalid_attempt_limit, term()}}
        | {:error, {:unknown_model, term()}}
```

Rules, checked in this order:

1. `enabled?` — anything other than a boolean is a programmer error (raises);
   the console only ever passes a boolean.
2. `threshold` — `Severity.parse/1` must succeed. `"high"`, `:high` and `"HIGH"`
   all normalize to `:high`; anything else → `{:invalid_threshold, value}`.
3. `attempt_limit` — must be an **integer** in `1..5`. `0`, `6`, `"2"`, `2.0`
   and `nil` all → `{:invalid_attempt_limit, value}`. A limit of zero is *not*
   an off-switch (FR-004a).
4. `model` — `nil` resolves to `Config.model_for(:analyze)`; a non-nil value
   goes through `Config.remediation_model(:analyze, value)`, so only the aliases
   the pinned SDK catalog accepts survive (FR-009a).

`validate/1` never clamps, never substitutes a default for a bad value, and
never partially applies (FR-011).

### `from_context/1`

```elixir
@spec from_context(RunContext.t() | map() | nil) :: {:ok, t()} | {:error, term()}
```

Tolerant decode with the same shape-tolerance `RunContext.stacked?/1` already
has (struct, string-keyed map from a manifest, or `%{}` from a bare test
Coordinator). An absent field falls back to that field's default; this is the
**only** fallback — a *present but invalid* field still errors.

## 2. `next/2` — the decision table

```elixir
@type state :: %{
        settings: Settings.t(),
        attempts_used: non_neg_integer(),
        analyze_runs: pos_integer(),
        last_result: AnalyzeResult.t() | nil,
        last_outcome: :ok | :error
      }

@type signals :: %{
        optional(:outcome)     => :ok | :error,       # of the step just finished
        optional(:result)      => AnalyzeResult.t() | nil,
        optional(:step)        => :analyze | :remediation,
        optional(:breaker?)    => boolean()
      }

@spec next(state(), signals()) ::
        {:gate, state()}
        | {:gate, {:exhausted, pos_integer()}, state()}
        | {:remediate, [finding()], state()}
        | {:halted, :breaker, state()}
        | {:failed, :remediation_failed, state()}
```

Evaluated top-to-bottom; the first matching row wins.

| # | Condition | Result | Requirement |
|---|---|---|---|
| 1 | `settings.enabled? == false` | `{:gate, state}` | FR-010 |
| 2 | `signals.outcome == :error` and `signals.step == :analyze` | `{:gate, state}` — a failed/unparseable analyze is a phase failure, never a loop entry | Edge Cases |
| 3 | `signals.outcome == :error` and `signals.step == :remediation` | `{:failed, :remediation_failed, state}` — stop now, do not consume remaining attempts | FR-008 |
| 4 | `signals.breaker? == true` | `{:halted, :breaker, state}` — the finished step is already accounted; nothing new starts | FR-009 |
| 5 | `findings_at_or_above(result, threshold) == []` | `{:gate, state}` | FR-001, FR-016 |
| 6 | `attempts_used >= settings.attempt_limit` | `{:gate, {:exhausted, attempts_used}, state}` | FR-004, FR-006 |
| 7 | otherwise | `{:remediate, findings, %{state \| attempts_used: attempts_used + 1}}` | FR-003 |

Row order carries meaning and is asserted by tests:

- **2 before 4** — a phase that failed is a failure, not a breaker halt.
- **3 before 4** — a remediation failure is named as such even if the breaker
  tripped in the same window (FR-008's "stops immediately" is about the loop,
  and the operator needs the specific cause).
- **5 before 6** — a converged final analyze run advances the feature even on
  the last allowed attempt; exhaustion only matters when findings remain.
- **6 before 7** — `attempts_used` can never exceed `attempt_limit` (SC-003).

`{:gate, …}` is terminal for the loop: there is no transition out of it, and the
caller evaluates `Pipeline.next(:analyze, outcome, signals)` immediately after.

## 3. `instruction/2` — the corrective instruction

```elixir
@spec instruction([finding()], keyword()) :: String.t()
```

Options: `:attempt`, `:limit`, `:threshold`, `:feature`.

Composition (pure; the pack is read by the caller, not by this function):

```text
<priv/prompts/analyze_remediation.md>

---
Attempt <k> of <n>. Severity threshold: <threshold>.
Findings to resolve (verbatim, as reported by analyze):

<pretty-printed JSON array of the at-or-above-threshold findings>
```

Guarantees:

- Findings are passed **verbatim** — severity, title, detail and any extra keys
  the model emitted — never summarized or reworded (spec Assumptions).
- Below-threshold findings are **not** included: the instruction is scoped to
  what actually triggered it.
- The string is deterministic for a given input (no timestamps, no ordering
  nondeterminism) so it can be asserted in tests and diffed across attempts.

## 4. `terminal_reason/2` — exhaustion decoration (FR-006, research R11)

```elixir
@spec terminal_reason(Pipeline.transition(), state()) :: Pipeline.transition()
```

- Loop disabled, or `attempts_used == 0` → the transition **unchanged**
  (SC-007a: byte-identical to pre-017).
- `attempts_used > 0` and the transition is `{:halted, :critical_finding}` →
  `{:halted, {:critical_finding, :auto_remediation_exhausted}}`.
- `attempts_used > 0` and the transition is `{:escalated, :high_findings}` →
  `{:escalated, {:high_findings, :auto_remediation_exhausted}}`.
- Any other transition (including `{:cont, :implement}` after a converged loop)
  → unchanged. A loop that *succeeded* leaves no mark on the reason; its record
  is the attempt history.

## 5. Non-goals

- No retry of a gate diversion. `next/2` is never called again once `{:gate, _}`
  is returned; `AnalyzeRunner` structurally cannot re-enter (FR-007).
- No cross-feature state. One loop state per feature run; concurrent features
  share nothing (spec Edge Cases).
- No budget arithmetic. The loop asks `breaker?` and nothing else; reservation
  and commit rules stay entirely in `Ledger` (FR-009).
