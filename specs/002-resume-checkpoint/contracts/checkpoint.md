# Contract: `SpeckitOrchestrator.Checkpoint`

The module's public surface. This is an internal Elixir API contract (the project
is an OTP control plane, not a network service), consumed at the `FeatureRunner`
finalization point and — later, out of this feature's scope — by the resume flow.

## `write/1`

```elixir
@spec write(map()) :: :ok
def write(%{feature_id: String.t(), last_phase: atom(), status: atom(),
            reason: term(), session_id: String.t() | nil})
```

- Serializes the record to JSON and writes it to
  `<Config.transcript_root>/<feature_id>/checkpoint.json`, creating the per-feature
  directory if needed.
- `reason` is serialized with `inspect/1` before encoding (a tuple/compound value
  MUST NOT cause a failure — FR-004).
- **Best-effort**: any error (unwritable path, IO error, encode failure) is rescued;
  the function still returns `:ok` and the run is unaffected (FR-008 / SC-004).
- Overwrites any existing checkpoint for the feature (edge: overwrite).
- Always returns `:ok`.

**Postconditions (happy path)**: a subsequent `read(feature_id)` returns
`{:ok, record}` whose fields equal what was written (lossless round-trip — SC-003),
with `last_phase`/`status` as strings, `reason` as the `inspect/1` string,
`session_id` as string-or-null.

## `read/1`

```elixir
@spec read(String.t()) ::
        {:ok, map()} | {:error, :no_checkpoint} | {:error, :corrupt}
def read(feature_id)
```

Three distinct, mutually exclusive outcomes (FR-006):

| Filesystem state                                   | Result |
|----------------------------------------------------|--------|
| `checkpoint.json` exists, decodes to a JSON object | `{:ok, map}` — string-keyed decoded record |
| No `checkpoint.json` for the feature               | `{:error, :no_checkpoint}` |
| `checkpoint.json` exists but fails to decode into a valid record (malformed / truncated / not an object) | `{:error, :corrupt}` |

- MUST NOT fabricate fields on corrupt (Constitution II).
- MUST distinguish corrupt from absent — the two error atoms are never interchanged.

## `delete/1`

```elixir
@spec delete(String.t()) :: :ok
def delete(feature_id)
```

- Removes the feature's `checkpoint.json` if present (FR-007).
- Deleting a non-existent checkpoint is a no-op that returns `:ok` (FR-005
  acceptance 2 — a `:done` feature with no prior checkpoint must not error).
- Best-effort on error; always returns `:ok`.

## Integration contract — `FeatureRunner.run/2`

After the phase `loop/7` returns `{status, reason, agent}` (beside the existing
`handle_worktree/3` call, `feature_runner.ex:74-81`):

- On a **non-`:done`** terminal (`:escalated` / `:halted` / `:failed`):
  `Checkpoint.write(%{feature_id: feature.id, last_phase: agent.state.phase,
  status: status, reason: reason, session_id: agent.state.session_id})`.
- On a **`:done`** terminal: `Checkpoint.delete(feature.id)`.
- This wiring MUST NOT change any control flow, gate outcome, or worktree behavior
  (FR-010) — it only produces/removes the record. A checkpoint failure MUST NOT
  alter the run's terminal state.
