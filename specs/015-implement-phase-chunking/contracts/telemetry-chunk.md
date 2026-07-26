# Contract: chunk telemetry + console rendering

**Kind**: observability extension (existing telemetry → projection → LiveView path).
**Files**: `telemetry.ex`, `console_read_model.ex`, `console_projection.ex`,
`web/components/core_components.ex`, `web/live/mission_control_live.ex`,
`web/live/pipeline_dag_live.ex`
**Satisfies**: FR-015, FR-016, FR-017, FR-018, FR-019, FR-025a, SC-003

---

## 1. New telemetry events

Emitted by `ChunkRunner` via `:telemetry.span([:speckit, :chunk], …)`, appended
to `Telemetry.events/0` so `ConsoleProjection` picks them up with no change to
its attach logic.

| Event | Measurements | Metadata |
|---|---|---|
| `[:speckit, :chunk, :start]` | `%{system_time}` | `%{feature_id, phase: :implement, scope, ordinal, total, number, title, attempt, sessions_used, ceiling, model}` |
| `[:speckit, :chunk, :stop]` | `%{duration}` | above + `%{outcome, cost, completed_before, completed_after}` |
| `[:speckit, :chunk, :exception]` | `%{duration}` | above + `%{kind, reason}` |
| `[:speckit, :chunk, :resolved]` | `%{}` | `%{feature_id, match_kind, ordinal, number, title, requested}` |

`scope ∈ [:task_phase, :sweep, :whole_list]`. `ordinal`/`total`/`number`/`title`
are `nil` for `:sweep` and `:whole_list`.

The existing `[:speckit, :phase, :start/:stop]` span for `:implement` is
**kept**, wrapping the whole step: the console's implement cell keeps its
existing cost/outcome semantics and every existing telemetry test stays green
(FR-008, FR-019).

---

## 2. Read-model fold (`ConsoleReadModel.apply_event/4`)

Pure, unit-tested with synthetic events — same style as the existing clauses.

| Event | Effect on the feature slice | Feed entry |
|---|---|---|
| `:chunk, :start`, `scope: :task_phase` | `chunk` set from metadata | `attempt == 1`: boundary entry (§3); `attempt > 1`: `:warn` — `task-phase 3/5 "…" continuing (attempt 2)` (FR-017) |
| `:chunk, :start`, `scope: :sweep` | `chunk` set, `scope: :sweep` | `:warn` — `sweep session over N remaining tasks` |
| `:chunk, :start`, `scope: :whole_list` | `chunk` set, `scope: :whole_list` | `:info` — `implement started` (unchanged wording vs today, FR-019) |
| `:chunk, :stop` | `chunk.outcome`; slice `spend + cost` | `:info`/`:warn` — `task-phase 3/5 "…" → ok (11→14 tasks)`; `:warn` on `:exhausted` |
| `:chunk, :exception` | `chunk.outcome = :error` | `:error` |
| `:chunk, :resolved`, `match_kind != :number` | — | `:warn` — `resumed task-phase located by title — task list was renumbered` (FR-025a) |
| `:feature, :terminal` | `chunk = nil` | unchanged |

Per-chunk `cost` is added to the slice's `spend`, exactly as `[:speckit, :phase,
:stop]` does today. The implement `[:speckit, :phase, :stop]` cost is the sum of
its chunks, so **the phase-level cost must not be double-counted**: the
implement phase-stop clause adds `max(0, phase_cost - chunk_costs_seen)`. A test
asserts total feature spend equals the ledger's for a chunked run.

---

## 3. Boundary entry (FR-016)

On a `:chunk, :start` with `attempt == 1` and `scope: :task_phase`, when the
slice already carries a completed `chunk`:

```
task-phase 2/5 "Foundational (Blocking Prerequisites)" complete → 3/5 "User Story 1 …"
```

The first task-phase of a step (no previous chunk) emits
`task-phase 1/5 "Setup" started`. This is one feed entry per boundary,
identifying both sides — exactly FR-016.

---

## 4. Rendering

**`phase_strip/1`** (`core_components.ex`) — the implement cell gains an
optional sub-label:

```
implement
  3/5 · User Story 1
```

Rendered **only** when `chunk != nil and chunk.scope == :task_phase`. For
`:sweep`: `sweep · 2 left`. For `:whole_list` and for `nil`: the cell renders
**exactly as today** — no `1/1`, no empty separator (FR-019, SC-005). A
LiveView test asserts byte-identical markup for the unstructured case against
the pre-change render.

Attempt > 1 adds ` (attempt 2)`; `sessions_used`/`ceiling` render as `7/14` in
the feature drawer only (FR-013b), not in the strip.

SC-003 (visible within 5s of a boundary): satisfied by the existing
`ConsoleProjection` broadcast-on-event path plus its 2s reconcile tick — chunk
events broadcast a `:feature_updated` diff on the same clause the phase events
use, so the strip repaints on the boundary itself.

**Inactive runs (FR-018)** — `ConsoleReadModel.overlay_last_known_statuses/3`
reads `checkpoint["implement_chunk"]` and seeds `chunk` for the reconstructed
slice, so a dead run's implement cell still shows its last known task-phase.
Absent key ⇒ `chunk: nil` ⇒ today's rendering.

---

## 5. Test obligations

- Pure read-model tests for each row of §2, including double-count avoidance.
- Boundary entry names both task-phases (FR-016).
- Continuation entry is `:warn` and names the attempt (FR-017).
- `scope: :whole_list` produces no task-phase indicator anywhere in the rendered
  strip (FR-019, SC-005) — asserted as markup equality with the pre-change
  render.
- `overlay_last_known_statuses/3` with an `implement_chunk` checkpoint ⇒ slice
  carries `chunk`; without ⇒ `nil` (FR-018).
- `Telemetry.events/0` includes the four new names, and
  `attach_default_logger/0` handles them without a `FunctionClauseError` (its
  catch-all clause already covers this — asserted, not assumed).
