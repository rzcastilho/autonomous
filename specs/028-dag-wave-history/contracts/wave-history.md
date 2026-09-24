# Contract: `SpeckitOrchestrator.WaveHistory` (pure)

`SpeckitOrchestrator.WaveHistory` is a pure core module. It must not depend
on Mnesia, `Coordinator`, `Ledger`, PubSub, or LiveView. Every input is an
argument. Every public function carries an `@spec`.

## `source_for(slug, history) :: source()`

```elixir
@type source ::
        {:live, summary :: map()}
        | {:recorded, summary :: map()}
        | :none
        | {:unavailable, reason :: term()}

@spec source_for(String.t(), {:ok, [map()]} | {:error, term()}) :: source()
```

`history` is the direct return of `SpeckitOrchestrator.run_history/1`, a list
ordered most recent first.

The rules are evaluated in order, and the first match wins:

| # | Input | Result |
|---|---|---|
| 1 | `{:error, reason}` | `{:unavailable, reason}` |
| 2 | Any summary with `state: :in_flight, scope: {:breakdown, ^slug}` | `{:live, summary}` |
| 3 | The first summary, in list order, with `scope: {:breakdown, ^slug}` | `{:recorded, summary}` |
| 4 | Otherwise | `:none` |

In rules 2 and 3, the following summaries are never matched:
- `%{damaged: true}` summaries, whose scope is unknown (FR-002);
- `scope: :ad_hoc`;
- any scope that is not `{:breakdown, _}`.

Rule 3 is state-agnostic: `:parked`, `:completed` and `:superseded` all
qualify (clarification Q1).

## `default_package(packages, history) :: String.t() | nil`

```elixir
@spec default_package([String.t()], {:ok, [map()]} | {:error, term()}) :: String.t() | nil
```

| # | Condition | Result |
|---|---|---|
| 1 | `packages == []` | `nil` (legacy layout) |
| 2 | An `:in_flight` summary with `{:breakdown, s}` where `s in packages` | `s` |
| 3 | The newest non-damaged `{:breakdown, s}` summary with `s in packages` | `s` |
| 4 | Otherwise (including `{:error, _}`) | `List.first(packages)` |

## `interrupt(row, run_state) :: row`

```elixir
@spec interrupt(map(), atom()) :: map()
```

| `run_state` | `row.status` | Result |
|---|---|---|
| `:in_flight` | any | `row` unchanged |
| anything else | `:running` | `%{row \| status: :interrupted, phases: Map.put(row.phases, open_phase, %{state: :interrupted})}` |
| anything else | any other | `row` unchanged |

`open_phase` is the phase after `row.current_phase` in `Pipeline.phases/0`,
or the first phase when `current_phase` is `nil`. If `current_phase` is the
final phase, `phases` is left unchanged and only `status` changes.

Earlier `:completed` cells are preserved as they are.

## `interrupt_all(per_feature, run_state) :: per_feature`

This is a convenience that maps `interrupt/2` over every row of a
`per_feature` map.

## Properties the tests must hold

- `source_for/2` never returns a summary whose `scope` is not
  `{:breakdown, slug}` for the given slug.
- `source_for/2` returns at most one run. Given two runs of the same wave, the
  one earlier in the list (the higher `run_id`) wins unless the other one is
  `:in_flight`.
- `interrupt/2` never produces a row with `status: :running` unless
  `run_state == :in_flight`.
- `interrupt/2` never adds an `:active` phase cell.
