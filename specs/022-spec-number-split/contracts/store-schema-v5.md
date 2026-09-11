# Contract: Store schema v5

Covers FR-007. One appended attribute on `speckit_feature_run`, backfilled from
data already in the row.

## 1. Table shape

```
:speckit_feature_run
  :key, :run_key, :feature_id, :slug, :path, :number, :group, :created_at,
  :status, :terminal_reason, :worktree_path, :branch, :pr_description,
  :started_at, :ended_at, :pr_url, :advanced_with_findings,
  :spec_number                                                   # v5, appended
```

`type: :set`, `storage: :disc_copies`, `index: [:run_key, :feature_id]` —
unchanged.

`Migrations.current_version/0` → `5`.

## 2. Migration entry

```elixir
{5, "append feature_run.spec_number (backfilled from :number)", &add_spec_number/0}
```

A **transform**, not a refusal: every v4 row is readable and every v4 feature
built in a directory named for its wave number, so backfilling `spec_number`
from `:number` records what actually happened rather than inventing data
(FR-007, spec Edge Cases → "Records written before this change").

```elixir
@feature_run_v4_attributes [
  :key, :run_key, :feature_id, :slug, :path, :number, :group, :created_at,
  :status, :terminal_reason, :worktree_path, :branch, :pr_description,
  :started_at, :ended_at, :pr_url, :advanced_with_findings
]

# Position of :number in a v4 tuple: +1 for the record tag at element 0.
@number_index Enum.find_index(@feature_run_v4_attributes, &(&1 == :number)) + 1

defp add_spec_number do
  transform_table(
    :speckit_feature_run,
    &Tuple.insert_at(&1, tuple_size(&1), elem(&1, @number_index)),
    Schema.table(:speckit_feature_run).attributes
  )
end
```

The v4 attribute list is pinned as a module literal and the index is derived
from it — never hardcoded — so a later append cannot silently shift which field
this migration reads. This mirrors the existing `@feature_run_v3_attributes`
precedent.

## 3. Guarantees

- **Idempotent by version.** `apply_pending/1` runs migration 5 only for a
  directory recorded at v4 or lower; a v5 directory skips it.
- **Nothing dropped or truncated** (Constitution → Persistence). The transform
  appends; no existing field moves position or changes value.
- **Unknown/newer versions still fail loud.** `Store.Boot`'s existing check is
  untouched — a directory recorded at v6 aborts startup.
- **The v2 refusal migration is untouched.** A pre-019 directory still aborts by
  name; it never reaches migration 5.
- **A v1/v2 → v5 path does not exist**, by the same clean break 019 recorded.

## 4. Write path

Only one writer, once per feature per run:

```elixir
@spec record_spec_number(run_key(), binary(), pos_integer()) :: :ok | {:error, term()}
```

- Reads the row `:write`-locked, writes it back with `spec_number` set.
- `{:error, {:absent, key}}` when the row does not exist.
- `{:error, {:already_allocated, feature_id, n}}` when `spec_number` is already
  non-nil — FR-004 forbids a second allocation, so this is an abort rather than
  an overwrite.

`open_run/2` and `add_features/2` continue to write `spec_number: nil`: the
number is allocated when the feature starts, not when the run opens.

## 5. Read path

```elixir
@spec Store.spec_number(Writer.run_key() | nil, binary()) :: pos_integer() | nil
```

`nil` for an unallocated feature, for an absent row, and for a run with no store
(`run_key == nil`). Callers distinguish "not allocated" from "no store" by
context — the executor treats both as "allocate now"; surfaces render both as
`not allocated`.

`Store.Query.run_detail/1` and the recovery rebuild path (`Recovery`'s
store-record → `%Feature{}` mapping) both carry `spec_number` through, so a
resumed or recovered feature reuses its recorded number (FR-004, SC-004).

## 6. Export

`Store.Export` serialises whole rows, so `spec_number` appears in the
Mnesia-free export with no change to the export code beyond the field itself
being present (Constitution → Persistence: "a run's record MUST be exportable in
a format readable without Mnesia").
