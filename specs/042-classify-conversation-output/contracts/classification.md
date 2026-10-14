# Contract: Pure classification API (042)

All modules are pure (FR-024), live under `lib/autonomous/web/`, carry
`@spec`s, and take `%Autonomous.ConversationEntry{}` values exactly as 040
produces them (live) or decodes them (saved). Field names read: `research.md`
R1. Placement table: `data-model.md` (normative).

## `Autonomous.Web.ConversationClass`

```elixir
@type placement :: :row | :signal | :row_signal | :header_signal
@type row_class :: :prose | :context | :thinking | :call | :result | :marker | :divider | :end | :raw
@type fold :: :open | :line | :preview5
@type t :: %{placement: placement(), row_class: row_class(), fold: fold(), label: String.t(), flag: nil | atom()}

@spec classify(ConversationEntry.t()) :: t()
@spec visible?(t(), all_frames? :: boolean()) :: boolean()
@spec sub_kind(ConversationEntry.t()) :: String.t() | nil   # body.subtype | body.raw.type
```

Guarantees:
- Total: every entry (including unknown kind/sub-kind and decoded-unknown
  `:other` with `body.kind`) gets a result; nothing raises.
- Unknown → `%{placement: :row, row_class: :raw, fold: :line, label: "<kind> · <sub-kind>"}`
  (sub-kind omitted when nil).
- `visible?(c, true) == true` for every entry.

## `Autonomous.Web.ToolSummary`

```elixir
@spec summary(name :: String.t() | nil, input :: map() | nil) :: String.t()
```

`summary("Bash", %{"command" => "mix test\nmix format"}) == "Bash(mix test …)"`;
`summary("Skill", %{"skill" => "speckit-plan"}) == "Skill(speckit-plan)"`;
`summary("Mystery", %{"b" => 1, "a" => "x"}) == "Mystery(x)"`;
`summary("Mystery", %{}) == "Mystery"`. Never longer than name + 202 chars.

## `Autonomous.Web.ConversationRows` (revised)

```elixir
@spec new(keyword()) :: ctx()                       # opts: all_frames: boolean()
@spec rows([ConversationEntry.t()], ctx(), keyword()) :: {[block()], ctx()}   # opts: expand: boolean()
@spec expand(ConversationEntry.t(), ctx()) :: block() | nil   # full block for an entry's seq (result → owning call block)
```

Guarantees:
- Returned blocks are those to `stream_insert` in order; a call block may be
  returned again later (pairing, `unfinished`) under the same `key`.
- Hidden entries (per `visible?`) produce no block but still advance pairing
  context (a hidden entry never breaks call/result pairing).
- `rows(all, new())` and folding the same entries one at a time yield the same
  final set of blocks keyed by `key` (stream equivalence — basis of SC-004).
- With `all_frames: true`: `count(unique keys) == count(entries) − count(results paired into a call block)` (SC-002).

## `Autonomous.Web.SessionStatus`

```elixir
@spec new() :: t()
@spec apply(t(), ConversationEntry.t()) :: t()       # no-op when seq <= last_seq
@spec apply_all(t(), Enumerable.t()) :: t()
@spec mark_lower_bound(t()) :: t()
@spec activity_text(t()) :: String.t() | nil
@spec status_name(t(), live? :: boolean()) :: String.t() | nil   # data-status name
@spec elapsed_s(t(), DateTime.t()) :: non_neg_integer() | nil
@spec count_text(non_neg_integer(), boolean()) :: String.t()
```

Guarantees:
- Idempotent per seq: `apply(apply(s, e), e) == apply(s, e)`.
- After `end`: `activity`, `ended_at` and `outcome` never change.
- `open_tasks >= 0`; `cost_usd`/`duration_ms` are nil until a `result`.
- `apply_all(new(), entries)` over a saved file equals the live fold over the
  same entries (SC-004).

## Read helpers (IO boundary, not pure)

```elixir
# Autonomous.ConversationFile
@spec fold(Path.t(), acc, (ConversationEntry.t(), acc -> acc), keyword()) ::
        {:ok, acc} | {:error, ConversationFile.read_error()}
# opts: through_seq: non_neg_integer() — stop after this seq (never read past it)
# streams line by line; malformed line before through_seq → {:error, {:malformed, line}}

# Autonomous.Conversation
@spec file_path(String.t()) :: {:ok, Path.t()} | :not_live
# absolute path of an in-flight conversation's file, from its registry identity
```
