# Contract: `SpeckitOrchestrator.RunContext`

New pure module. Holds the six run-shaping settings, captures them from effective
run opts, serializes them for the checkpoint, and merges recorded values back into
resume opts under a fixed precedence. No IO, no CLI, no Jido (Principle I).

## Struct

```elixir
defstruct pr_workflow: nil, max_concurrency: nil, budget_usd: nil,
          plan_stack: nil, pr_base: nil, pr_remote: nil
```

A `nil` field means "not set here" (used by the partial-decode / merge path). A
fully-captured context has all six set.

## `capture/1`

```elixir
@spec capture(keyword()) :: t()
def capture(opts)
```

- For each field, resolve `Keyword.get(opts, <opt_key>, Config.<accessor>())`.
- Called by the facade at `run/1` time on the **effective** opts, so the captured
  value is the one the run actually uses (not a later-drifted env).
- Pure w.r.t. inputs; reads `Config` (Application env) — acceptable, this is the
  capture boundary.

## `to_map/1`

```elixir
@spec to_map(t()) :: %{String.t() => term()}
def to_map(ctx)
```

- Returns a JSON-ready, string-keyed map of exactly the six settings.
- Contains only run-shaping primitives (bool/number/string/list-of-string) — **never
  a secret** (FR-011). No field exists that could carry one.

## `from_map/1`

```elixir
@spec from_map(map() | nil) :: t()
def from_map(map_or_nil)
```

- `nil` or `%{}` → struct with all fields `nil` (old checkpoint; edge: no context).
- Partial map → only present keys populated; missing keys stay `nil` (edge: partial).
- **Never raises** on unexpected/missing keys — tolerant decode (FR-008).
- Ignores unknown keys; does not coerce types beyond JSON's own (bool/number/string).

## `merge/2`

```elixir
@spec merge(keyword(), t()) :: {keyword(), [atom()]}
def merge(opts, recorded)
```

Applies precedence **explicit resume opt > recorded context > (absent ⇒ `run/1`
falls to live Config/default)** and reports fallbacks:

- Returns `{merged_opts, fell_back_keys}`.
- For each of the six keys:
  - if `opts` already has the opt key → keep the caller's value (explicit override
    wins — FR-007), not a fallback.
  - else if `recorded` has a non-`nil` value → inject it into `merged_opts`.
  - else → leave the key absent (so `run/1` uses `Config`) **and** add it to
    `fell_back_keys`.
- `merged_opts` is passed straight to `run/1`; the six recorded settings therefore
  reach `run/1` as explicit opts, which is what makes recorded beat live Config
  without changing `run/1`.
- `fell_back_keys` drives the FR-008 observability log at the resume boundary.

**Guarantee**: `merge/2` never overrides a caller-supplied opt and never injects a
`nil`. Ordering of `opts` vs `recorded` inputs does not change the result
(order-independent — FR-003 spirit).
