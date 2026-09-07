# Contract: Spec number allocation

Covers FR-001 – FR-005 and FR-003a. Internal Elixir API — the orchestrator
exposes no external interface for this.

## 1. Pure surface — `SpeckitOrchestrator.SpecNumber`

No IO. Input is a list of bare directory names; the caller does the listing.

```elixir
@spec parse(String.t()) :: {:ok, pos_integer()} | :error
@spec highest([String.t()]) :: pos_integer() | nil
@spec allocate([String.t()], String.t()) ::
        {:ok, pos_integer()} | {:error, {:spec_dir_exists, String.t()}}
@spec dir_name(pos_integer(), String.t()) :: String.t()
@spec branch_name(pos_integer(), String.t()) :: String.t()
```

### `parse/1`

Conforming shape `^(\d+)-(.+)$`. Compared numerically.

| Input | Output |
|---|---|
| `"001-core-ledger"` | `{:ok, 1}` |
| `"0002-x"` | `{:ok, 2}` |
| `"015-billing"` | `{:ok, 15}` |
| `"autonomous"` | `:error` |
| `"015"` | `:error` |
| `"015-"` | `:error` |
| `"abc-x"` | `:error` |
| `""` | `:error` |

### `highest/1`

`nil` when no entry conforms. Non-conforming entries are skipped, never raised
on (FR-003).

### `allocate/2`

```
n = (highest(entries) || 0) + 1
if Enum.any?(entries, &match?({:ok, ^n}, parse(&1))) do
  {:error, {:spec_dir_exists, <that entry>}}
else
  {:ok, n}
end
```

- Empty / all-non-conforming listing ⇒ `{:ok, 1}` (FR-002, US1 scenario 5).
- Gaps are never filled: `["001-a", "007-b"]` ⇒ `{:ok, 8}`.
- The refusal is unreachable for a well-formed listing — highest-plus-one cannot
  collide — so reaching it means the base moved beneath the run or the existing
  numbering is damaged. It is a hard error, not a retry-with-next-free-number
  (FR-003a, US1 scenario 7). The offending entry is named in the error term.

`allocate/2` takes `slug` only so the error can be reported with the full
intended directory name at the call site; it does not influence the number.

## 2. IO surface — `SpeckitOrchestrator.Worktree.spec_dirs/2`

```elixir
@spec spec_dirs(Path.t(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
def spec_dirs(repo, base)
```

`git -C <repo> ls-tree --name-only <base> specs/` — the base is a git ref
(`"HEAD"`, `"main"`, `"feature/014-x"`, a sha). Output lines are
`specs/<entry>` (and `specs/<entry>/` for trees on some git versions); the
function returns bare entry names with the `specs/` prefix and any trailing
slash stripped, deduplicated.

- Reads the **ref**, not the base repo's working tree (research R1).
- `{:ok, []}` when `specs/` does not exist on the ref — git exits 0 with no
  output. Only a git invocation failure returns `{:error, _}`.

## 3. Allocation flow (`SpeckitOrchestrator`, the executor seam)

Runs once per feature, before `Worktree.create/2`, in the runner task:

```
recorded = Store.spec_number(run_key, feature.id)      # nil when absent / no store

case recorded do
  n when is_integer(n) ->
    # FR-004: reuse. NO existence check — an existing directory here is the
    # expected case for a resume/retry/restart.
    {:ok, %{feature | spec_number: n}}

  nil ->
    with {:ok, entries} <- Worktree.spec_dirs(repo, base),
         {:ok, n}       <- SpecNumber.allocate(entries, feature.slug),
         :ok            <- Store.Writer.record_spec_number(run_key, feature.id, n) do
      {:ok, %{feature | spec_number: n}}
    end
end
```

Failure at any step ⇒ the feature is notified `:failed` with the reason and
**no worktree is created and no phase runs** (FR-003a "refuses before the first
phase runs"). Reasons reaching `notify/3`:

| Reason | Cause |
|---|---|
| `{:spec_number, {:spec_dir_exists, entry}}` | FR-003a refusal |
| `{:spec_number, {:git_failed, code, output}}` | `spec_dirs/2` failed |
| `{:spec_number, {:not_recorded, reason}}` | store write failed |

A run with no store (`run_key == nil` — dry runs, unit tests) skips the read and
the write and allocates in memory; it still refuses on FR-003a.

## 4. Store surface

```elixir
# SpeckitOrchestrator.Store
@spec spec_number(Writer.run_key() | nil, binary()) :: pos_integer() | nil

# SpeckitOrchestrator.Store.Writer
@spec record_spec_number(run_key(), binary(), pos_integer()) :: :ok | {:error, term()}
```

`record_spec_number/3` is one transaction: read the `feature_run` row for
`feature_id`, write it back with `spec_number` set. `{:error, {:absent, key}}`
when the row does not exist. It does **not** overwrite a non-nil
`spec_number` — a second allocation for a feature that already has one is a
programmer error and aborts with `{:already_allocated, feature_id, n}`
(FR-004's "MUST NOT allocate a second number").

## 5. Name composition

Every name is composed from `Feature.spec_id/1` and `feature.slug`:

| Consumer | Value |
|---|---|
| `Worktree.locate/2` `:path` | `<worktree_root>/<spec_id>-<slug>` |
| `Worktree.locate/2` `:branch` | `feature/<spec_id>-<slug>` |
| `SpecDir` candidate 1 | `<worktree>/specs/<spec_id>-<slug>` |
| `PhaseRequest` prompt | `SPECIFY_FEATURE_DIRECTORY=specs/<spec_id>-<slug>` |

`Worktree.locate/2` keeps `feature_id: feature.id` — the struct field is the
canonical identity and is used for logging and store lookups, not for paths.

## 6. Ordering is untouched (FR-006)

`Release.order/1`, `Release.next/3`, and `Backlog`'s sort all read `number`.
`spec_number` appears in none of them, and no ordering test changes.
