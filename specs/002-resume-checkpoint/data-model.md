# Phase 1 Data Model: Resume Checkpoint Persistence

## Entity: Checkpoint record

A per-feature durable pointer describing where and why a feature run stopped. At
most one exists per feature at any time (keyed by feature id; a re-run overwrites).

### Storage

- **Format**: JSON document (UTF-8).
- **Path**: `<Config.transcript_root>/<feature_id>/checkpoint.json`.
- **Cardinality**: 0 or 1 per feature. Present only for a diverted (non-`:done`)
  terminal; absent for a never-run or `:done` feature.

### Fields

| Field         | JSON type | Source (at finalization)        | Notes |
|---------------|-----------|---------------------------------|-------|
| `feature_id`  | string    | `feature.id`                    | The feature the record belongs to; also the directory key. |
| `last_phase`  | string    | `agent.state.phase`             | The phase the feature reached when it terminated — the phase the pipeline diverted at (FR-003). Stored as the atom's string form (e.g. `"clarify"`, `"analyze"`). |
| `status`      | string    | loop return `status`            | Terminal status: one of `escalated`, `halted`, `failed`. Never `done` (a `:done` terminal deletes instead of writing). Stored as the atom's string form. |
| `reason`      | string    | loop return `reason` via `inspect/1` | The terminal reason, serialized with `inspect/1` so a compound value (tuple, etc.) round-trips as a readable string without a write failure (FR-004). |
| `session_id`  | string \| null | `agent.state.session_id`   | The Claude session id of the run (may be `nil` if no phase established one → JSON `null`). |

### Validation rules

- **Write**: no validation gate — best-effort. Any value serializes: `last_phase`
  and `status` via atom→string, `reason` via `inspect/1`, `session_id` string-or-null.
  A serialization/IO failure is rescued to `:ok` (FR-008); the record is simply not
  written.
- **Read → valid record**: the file exists and decodes to a JSON object containing at
  minimum the written keys → returned as a map with the fields above.
- **Read → absent**: no file at the path → `{:error, :no_checkpoint}` (FR-006 b).
- **Read → corrupt**: the file exists but does not decode into a valid record
  (malformed JSON, truncated, not an object) → `{:error, :corrupt}` (FR-006 c) —
  distinct from absent, never fabricated fields.

### State transitions (per feature over its lifecycle)

```text
(no file)
   │  feature diverts at a phase (escalated / halted / failed)
   ▼
checkpoint.json { last_phase, status, reason, session_id }
   │
   ├─ feature re-runs, diverts again ──► overwrite with new phase/status (edge: overwrite)
   │
   └─ feature re-runs, reaches :done ──► delete (FR-005) ──► (no file)
```

A first run that reaches `:done` with no prior checkpoint performs a delete on an
absent file — a no-op that MUST NOT error (FR-005 acceptance 2).

## Read-result shape (module return contract)

- `{:ok, %{"feature_id" => ..., "last_phase" => ..., "status" => ..., "reason" => ..., "session_id" => ...}}`
  — string-keyed map as decoded from JSON (lossless round-trip of what was written).
- `{:error, :no_checkpoint}` — absent.
- `{:error, :corrupt}` — present but unparseable.

## Relationships

- Lives beside per-phase durable transcripts written by `Transcripts`
  (`<transcript_root>/<feature_id>/NN-<phase>.md`) — same per-feature durable
  directory, keyed by the same `feature_id`.
- Consumed by no runtime code in this feature (FR-010). The future resume feature
  (backlog 002+) is the intended reader of `read/1`.
