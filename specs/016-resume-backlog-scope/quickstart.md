# Quickstart: validating "Resume Preserves Backlog Scope"

**Feature**: `016-resume-backlog-scope`

Runnable validation scenarios. Contracts live in [`contracts/`](./contracts);
entity shapes in [`data-model.md`](./data-model.md). No implementation code here.

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors is ON
```

All Elixir commands go through `mise exec --` (constitution, Quality & Test
Discipline). Scenarios S1–S5 are hermetic; S6 drives a real target repo and is
opt-in.

## S1 — The defect, at the seam level (US1, SC-001)

Proves a per-feature resume keeps the whole recorded set.

```bash
mise exec -- mix test test/speckit_orchestrator/resume_scope_test.exs
```

Setup: a manifest recording `001 → 002 → 003` with `001` halted, a checkpoint for
`001`, and the Coordinator's `:runner` and `:manifest` seams faked.

Expect:

- the Coordinator's feature set is `["001", "002", "003"]`;
- the seeded statuses are `001: :pending` (target), `002`/`003` per reconciliation;
- exactly one dispatch on the first wave — `001`, at its checkpointed phase;
- as the fake runner reports `001 :done`, `002` is dispatched, then `003`;
- the final report's `done` list holds all three (FR-007).

## S2 — Nothing else is disturbed (US1, FR-002/005/006)

Same file. A manifest where `002` is `:done` and `003` is `:escalated`, resuming
`001`.

Expect: `002` is never dispatched; `003` stays `:escalated` and is never
dispatched; only `001` runs.

## S3 — The narrowing guard (US2, SC-004)

```bash
mise exec -- mix test test/speckit_orchestrator/run_manifest_test.exs
```

Against a temp `autonomous_root`:

| Write | Expect |
|-------|--------|
| `[001,002,003]` then `[001]` | second write refused; file still names three |
| `[001,002,003]` then `[001,002,004]` | refused — a swap loses `003` (identity, not count) |
| `[001,002,003]` then `[001,002,003,004]` | allowed — growth is not narrowing |
| `clear/0` then `[001]` | allowed — a fresh run supersedes (FR-013) |
| progress-only write (same ids, new statuses) | allowed (FR-014 unaffected) |

Every case returns `:ok` — a refusal is never an error to the caller.

Refusal event, asserted with `:telemetry_test.attach_event_handlers/2`:

```elixir
assert_receive {[:speckit, :run, :scope_narrowing_refused], _ref,
                %{dropped_count: 2}, %{dropped: ["002", "003"]}}
```

## S4 — Refusal reaches the operator (US2, FR-012)

```bash
mise exec -- mix test test/speckit_orchestrator/console_read_model_test.exs
mise exec -- mix test test/speckit_orchestrator/telemetry_test.exs
```

Expect: folding the refusal event pushes one `:warn` feed entry with
`feature_id: nil` naming the dropped ids, and leaves `model.features`
untouched; the default logger emits one warning line.

## S5 — Record recovery, preview then confirm (US3, SC-006)

```bash
mise exec -- mix test test/speckit_orchestrator/recovery/rebuild_test.exs
mise exec -- mix test test/speckit_orchestrator/record_recovery_test.exs
```

Setup: a record narrowed to `001` (`:done`) beside a three-feature backlog on
disk, with evidence for `001` (committed branch + `pr.json`) and none for
`002`/`003`.

Expect:

1. `recover_record()` returns a proposal naming all three — `001 :done`,
   `002`/`003` `:pending` — with two `:absent_from_record` discrepancies, and
   **the file on disk is byte-identical afterwards** (FR-019a);
2. `recover_record(confirm: true)` writes that record and returns
   `{:ok, :written, proposal}`;
3. a backlog missing a prereq yields `{:error, {:backlog, _}}` with no write;
4. a proposal with `:prereq_missing` yields `{:error, {:inconsistent, _}}` with
   no write (FR-020).

## S6 — End-to-end regression (SC-003) *(opt-in)*

```bash
mise exec -- mix test --include integration test/speckit_orchestrator/resume_backlog_e2e_test.exs
```

A temp git target repo seeded with a three-feature chained backlog, driven by
FakeSDK: `001` diverts at a gate, the operator resumes it once, and the run is
expected to reach `001 :done → 002 :done → 003 :done` with a final report
counting three. Pre-016 this run reports `Done: 1` and stops — that difference is
the whole feature.

## S7 — Operator surface (FR-021/022)

```bash
mise exec -- mix test test/speckit_orchestrator/web
```

Expect: the escalations resume panel states that resuming continues the whole
run; a resume attempted while another run is live surfaces the refusal instead of
starting work; mission control after a resume lists every restored feature,
including those still waiting on prerequisites.

## Full gate before hand-off

```bash
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
mise exec -- mix test --cover        # pure core > 90%
```
