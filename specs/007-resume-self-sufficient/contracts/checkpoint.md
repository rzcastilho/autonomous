# Contract: `SpeckitOrchestrator.Checkpoint` (extended)

Extends the 002 checkpoint contract. Only the **write input**, the **persisted
record**, and the **FeatureRunner integration** change. `read/1` and `delete/1`
outcome atoms are unchanged.

## `write/1` (extended input)

```elixir
@spec write(map()) :: :ok
def write(%{
  feature_id: String.t(),
  last_phase: atom(),
  status: atom(),
  reason: term(),
  session_id: String.t() | nil,
  slug: String.t(),                       # NEW — identity (FR-001)
  path: String.t(),                       # NEW — identity (FR-001)
  run_context: SpeckitOrchestrator.RunContext.t() | nil  # NEW — run shape (FR-006)
})
```

- Persists `slug` and `path` alongside the existing fields.
- Persists `RunContext.to_map(run_context)` under the record key `"context"` when
  `run_context` is non-`nil`; omits `"context"` when `nil` (older callers / no
  context threaded).
- **Best-effort preserved (FR-010)**: the added fields ride the same
  `rescue -> :ok`; an encode/IO failure still returns `:ok` and never breaks the
  run. Adding fields introduces **no new raising path**.
- **No secrets (FR-011)**: `run_context` is a `RunContext`, which structurally cannot
  hold a credential.
- Lossless round-trip for all fields including the new ones (`read` returns the same
  string/JSON values written).

## Persisted record (read shape)

`read/1` returns the decoded object; consumers now also read:

| Key | Present when | Consumer |
|-----|--------------|----------|
| `"slug"` | written by this feature onward | `resume/2` identity reconstruction |
| `"path"` | written by this feature onward | `resume/2` identity reconstruction |
| `"context"` | run context was threaded at write time | `resume/2` context reapply |

Old checkpoints (pre-007) lack all three; `resume/2` handles their absence via the
explicit/backlog identity path and the context fallback (FR-008). `read/1` outcomes
(`{:ok, map}` / `{:error, :no_checkpoint}` / `{:error, :corrupt}`) are unchanged and
still never fabricate the new keys on corruption.

## Integration — `FeatureRunner.run/2`

`FeatureRunner.run/2` gains an option:

- `:run_context` — a `RunContext.t()` captured by the facade for this run; defaults
  to `nil` (tests and non-context callers).

At the diverted-terminal write site (`feature_runner.ex:201`), the write map is
extended with `slug: feature.slug`, `path: feature.path`, and
`run_context: <the run_context opt>`. Control flow, gate outcomes, worktree
behavior, and the `:done → delete` branch are **unchanged** (FR-010). A checkpoint
failure never alters the run's terminal state.
