# Contract: `SpeckitOrchestrator.RunManifest`

New pure module. Single-slot durable run record at
`<Config.transcript_root()>/run.json`. Mirrors the `Checkpoint`/`RunContext`
conventions: string-keyed JSON, best-effort write, three-way read, never
fabricates.

## `write/1`

```elixir
@spec write(map()) :: :ok
```

Best-effort; always returns `:ok` (a write failure never breaks the run —
mirrors `Checkpoint.write/1`). Accepts a map with:

- `features` — `[%{id, slug, path, prereqs}]` (from the `%Feature{}` list)
- `statuses` — `%{feature_id => status_atom_or_string}`
- `context` — `RunContext.t()` or its map (serialized via `RunContext.to_map/1`)
- `spend` — number (run-global committed spend)
- `updated_at` — caller-supplied stamp

Serializes atoms to strings. Creates the transcript root dir if absent. Writes
atomically-enough (single `File.write!`).

## `read/0`

```elixir
@spec read() :: {:ok, map()} | {:error, :no_manifest} | {:error, :corrupt}
```

Three-way: a decoded record, an absent slot (`:enoent`), or an undecodable/
malformed file. Never invents fields (Principle II).

## `clear/0`

```elixir
@spec clear() :: :ok
```

Deletes the slot; no-op on a missing file. Called at each new `run/1` to
supersede the prior manifest (single-slot rule, FR-005).

## `resumable?/0`

```elixir
@spec resumable?() :: boolean()
```

`true` when `read/0` yields a record holding at least one **non-terminal-and-final**
feature status — a `:running` (interrupted) or `:pending` (never released)
feature. Pure classification over the read record; starts no work (FR-008,
SC-006). A run whose every feature is `:done`/gate-diverted returns `false`
(nothing to auto-resume; diverts use `resolve/1`).

## `reconstruct/1` (helper, may be inlined in the facade)

```elixir
@spec reconstruct(map()) :: {[Feature.t()], %{String.t() => Feature.status()}}
```

From a read record, rebuild the `%Feature{}` list and the seed `statuses` map for
the `Coordinator`, applying the crash→resume status mapping (data-model State
transitions): terminal statuses kept; `:running`/`:pending` → `:pending`.

## Invariants

- One slot only. No run-id keying, no multi-file enumeration.
- Write is idempotent per state (last write wins; `spend` is monotonic so
  last-writer-wins is safe even under a brief race).
- No dependency on CLI/harness/Jido (Principle I).
