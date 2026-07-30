# Contract: Mnesia Schema

**Feature**: `018-unified-run-persistence`

The authoritative table definitions. `SpeckitOrchestrator.Store.Schema` holds
this as data (a list of table specs); `Store.Boot` creates from it,
`Store.Migrations` evolves it, and `Store.Mnesia` is the **only** module that
calls `:mnesia`.

## Location, node, and boot

| Concern | Contract |
|---------|----------|
| Directory | `Config.store_dir/0`, default `<Config.autonomous_root()>/mnesia`. Never inside a target repo tree (FR-005). |
| Node | Whatever `node()` is (`:nonode@nohost` under `mix run` / `iex -S mix`). Recorded in `speckit_meta`. |
| Ownership check | `node()` must appear in `:mnesia.table_info(:schema, :disc_copies)` **and** match `speckit_meta`'s `:node` row. Mismatch ⇒ `{:error, {:schema_node_mismatch, expected, found}}` and startup aborts. Never create a fresh schema over a foreign one. |
| Start order | `Store.Boot.start!/0` runs before any child spec in `Application.start/2`; a failure returns `{:error, reason}` from `start/2` so the app does not boot (FR-009). |
| Writability proof | A transaction writing `speckit_meta`'s `:write_probe` row must succeed at boot. |

Boot sequence (research R4): mkdir → set `:mnesia` dir → `create_schema` if
absent → `:mnesia.start()` → verify ownership → read/apply schema version →
create missing tables → `wait_for_tables` → write probe.

## Storage-type rules

- `disc_copies` for every run-control table: small, hot, RAM-resident so a
  history listing is interactive (SC-009).
- `disc_only_copies` for `speckit_transcript` only: bulk content stays off the
  BEAM heap, and a history listing never loads it (FR-036, constitution).
- `ordered_set` is **not supported** on `disc_only_copies` (verified). Only
  `speckit_run` uses `ordered_set`, and it is `disc_copies`.

## Tables

Attribute lists are ordered; attribute 1 is the primary key. `idx` marks a
secondary index.

### 1. `speckit_meta` — `disc_copies`, `set`

`[:key, :value]` — keys `:schema_version`, `:node`, `:created_at`,
`:write_probe`.

### 2. `speckit_seq` — `disc_copies`, `set`

`[:repo_id, :next_seq, :origin, :local_path]`

Bumped with a transactional read-modify-write under a write lock
(`:mnesia.read(:speckit_seq, repo_id, :write)`). **Never**
`:mnesia.dirty_update_counter/3` — the constitution bars dirty writes.

### 3. `speckit_run` — `disc_copies`, **`ordered_set`**

```
[:key, :repo_id(idx), :run_id, :state, :outcome, :outcome_index(idx),
 :started_at, :ended_at, :duration_ms, :spend_usd, :record_complete?,
 :halt_reason, :scope, :layout, :superseded_by, :schema_version]
```

`key = {repo_id, run_id}`; `run_id = "r" <> String.pad_leading(seq, 6, "0")`.
Ordered-set key order is chronological order (FR-033) — history listing reads
this table in reverse key order and never sorts by a timestamp.

### 4. `speckit_run_settings` — `disc_copies`, `set`

`[:run_key, :settings, :captured_at]`

### 5. `speckit_settings_amendment` — `disc_copies`, `set`

`[:id, :run_key(idx), :ordinal, :changes, :effective_at, :effective_after]`

### 6. `speckit_feature_run` — `disc_copies`, `set`

```
[:key, :run_key(idx), :feature_id(idx), :slug, :path, :prereqs, :status,
 :terminal_reason, :worktree_path, :branch, :pr_description,
 :started_at, :ended_at]
```

### 7. `speckit_phase_attempt` — `disc_copies`, `set`

```
[:attempt_id, :run_key(idx), :feature_key(idx), :phase, :ordinal, :step,
 :label, :started_at, :ended_at, :duration_ms, :outcome, :model,
 :cost_usd, :cost_kind, :substep, :session_id, :error]
```

`attempt_id = {repo_id, run_id, feature_id, phase, ordinal}`.

### 8. `speckit_checkpoint` — `disc_copies`, `set`

```
[:key, :run_key(idx), :phase, :last_completed_phase, :status, :reason,
 :session_id, :implement_chunk, :analyze_remediation, :updated_at]
```

One row per `{repo_id, run_id, feature_id}`, superseded in place; deleted when
the feature reaches `:done`.

### 9. `speckit_escalation` — `disc_copies`, `set`

```
[:id, :run_key(idx), :feature_id(idx), :kind, :phase, :severity, :reason,
 :evidence, :raised_at, :resolution]
```

### 10. `speckit_remediation_attempt` — `disc_copies`, `set`

```
[:id, :run_key(idx), :feature_key(idx), :ordinal, :findings, :max_severity,
 :outcome, :cost_usd, :attempt_limit, :threshold, :model, :attempt_id]
```

### 11. `speckit_cost_entry` — `disc_copies`, `set`

`[:id, :run_key(idx), :amount_usd, :kind, :recorded_at]` — `id` is the
`attempt_id` the charge belongs to.

### 12. `speckit_transcript` — **`disc_only_copies`**, `set`

`[:attempt_id, :body, :bytes, :written_at]`

Same key as its phase attempt (FR-035). `body` is stored verbatim as a binary —
no encoding, no truncation, no transformation (FR-029a).

## Transaction boundaries

One transaction per durable boundary — every row listed together, or none of
them (FR-006):

| Boundary | Rows |
|----------|------|
| **run start** | `seq` bump · prior `in_flight` run → `superseded` (+ its non-terminal features → `:ended_by_supersession`) · new `run` · `run_settings` · every `feature_run` |
| **phase attempt end** | `phase_attempt` · `cost_entry` · `checkpoint` (superseded) · `transcript` |
| **remediation attempt end** | `remediation_attempt` · `cost_entry` · `phase_attempt` · `transcript` |
| **feature start** | `feature_run` status → `:running`, first-start `started_at`, prior `terminal_reason`/`ended_at` cleared |
| **feature terminal** | `feature_run` · `checkpoint` (deleted on `:done`) · `escalation` when diverted |
| **run drained** | `run` state/outcome/`ended_at`/`duration_ms`/`spend_usd` |
| **escalation resolved** | `escalation.resolution` only |
| **prune** | every row of each removed run, across all tables, in one transaction |

## Read discipline

- Transactional reads for anything feeding a resume, a gate, a cost decision, an
  export, or a prune.
- `:mnesia.dirty_read/2` permitted **only** for the console's non-authoritative
  liveness display, never for a write and never for the above.

## Schema versioning

`speckit_meta[:schema_version]` is an integer. `Store.Migrations.all/0` is an
ordered `[{version, description, fun}]` list applied at boot inside
transactions, using `:mnesia.transform_table/3` for attribute changes.

| Recorded version | Action |
|------------------|--------|
| `nil` (fresh schema) | create all tables at `current_version`, write it |
| `< current` | apply intervening migrations in order, then write `current` |
| `== current` | proceed |
| `> current`, or unrecognized | **abort startup loud** — never auto-coerce, never downgrade |

## Damaged-state reporting

`Store.Records.decode/2` returns:

| Return | Meaning |
|--------|---------|
| `{:ok, struct}` | complete row |
| `{:error, {:damaged, key, reason}}` | present but undecodable — reported to the caller, never defaulted (FR-008, SC-011) |

Absence is the caller's `{:error, :absent}`, distinct from damage. No read path
substitutes a default or infers a missing value.

## Capacity

| Quantity | Source |
|----------|--------|
| transcript bytes | `:mnesia.table_info(:speckit_transcript, :memory)` — bytes for a DETS table (verified) |
| whole-store bytes | sum of `File.stat!/1` sizes across the store dir |
| ceiling | `Config.store_capacity_bytes/0`, default `1_500_000_000` |
| headroom | `Config.store_headroom_bytes/0`, default `150_000_000` |

Neither figure requires reading table contents. Policy is
`Store.Capacity.check/1` (pure) — see `contracts/capacity.md`.
