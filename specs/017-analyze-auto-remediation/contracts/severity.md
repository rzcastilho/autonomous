# Contract: `SpeckitOrchestrator.Severity`

Pure module. No IO, no CLI, no harness, no Jido. The ordered finding vocabulary
that FR-001a promotes into the contract.

## 1. Vocabulary and order

```text
:low  <  :medium  <  :high  <  :critical
  1        2          3          4
```

`"blocker"` is a case-insensitive synonym for `:critical`, preserved from
`AnalyzeResult`'s existing `@critical_severities`. Anything else is `:unknown`.

## 2. API

```elixir
@type severity :: :low | :medium | :high | :critical
@type parsed   :: severity() | :unknown

@spec values() :: [severity()]              # [:low, :medium, :high, :critical]
@spec rank(parsed()) :: 1..4 | nil          # :unknown -> nil
@spec parse(String.t() | atom()) :: {:ok, severity()} | :error
@spec parse_finding(map()) :: parsed()      # reads "severity"; :unknown on absent/garbled
@spec at_or_above?(parsed(), severity()) :: boolean()
@spec max(Enumerable.t()) :: parsed() | nil # nil for an empty enumerable
```

`parse/1` accepts `"High"`, `"high"`, `:high`, `"BLOCKER"`. It returns `:error`
(never raises, never `String.to_atom/1`) for anything else — the module is fed
model-authored JSON.

## 3. Threshold semantics (FR-001a)

`at_or_above?(s, t)` is `rank(s) >= rank(t)`, with an inclusive floor:

| threshold | matches |
|---|---|
| `:critical` | Critical only |
| `:high` | High, Critical |
| `:medium` | Medium, High, Critical |
| `:low` | Low, Medium, High, Critical |

**Unknown severities match nothing**, including threshold `:low` — see research
R3 for why, and for the alternatives rejected. `at_or_above?(:unknown, _) ==
false` is a documented, tested clause, not a fallthrough.

## 4. Guarantees

- Total order over the four values; `rank/1` is injective on them.
- `at_or_above?/2` is reflexive (`at_or_above?(:high, :high) == true`) — the
  threshold is a floor, not a strict bound.
- Adding a severity to the vocabulary is a contract change requiring a spec
  update; the module never widens the vocabulary from input.

## 5. `AnalyzeResult` accessors built on it

```elixir
@spec max_severity(AnalyzeResult.t()) :: Severity.parsed() | nil
@spec findings_at_or_above(AnalyzeResult.t(), Severity.severity()) :: [finding()]
@spec unknown_severities(AnalyzeResult.t()) :: [finding()]
```

`findings_at_or_above/2` preserves report order and returns findings
**verbatim** (severity, title, detail, and any extra keys the model emitted) —
the corrective instruction is grounded in what analyze actually reported, per
the spec's assumption.

`critical?/1` and `high?/1` are **not** reimplemented in terms of this module.
They keep their current independent implementations so that a run with the loop
disabled produces byte-identical gate signals (SC-007a).
