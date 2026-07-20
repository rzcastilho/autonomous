# Quickstart: Resume Checkpoint Persistence

Validation guide proving the checkpoint record is produced, deleted, and read back
per the [spec](./spec.md). See [contracts/checkpoint.md](./contracts/checkpoint.md)
for the API and [data-model.md](./data-model.md) for the record shape.

## Prerequisites

- Toolchain via mise (`.tool-versions` pins `1.20.2-otp-28`). Run every command
  through `mise exec --`.
- Deps fetched: `mise exec -- mix deps.get`.
- Clean compile under `warnings_as_errors`: `mise exec -- mix compile`.

## Automated validation (primary)

Run the module's unit suite (hermetic — uses an ExUnit `tmp_dir` as the transcript
root; no CLI/worktree):

```bash
mise exec -- mix test test/speckit_orchestrator/checkpoint_test.exs
```

Expected: all green. The suite MUST cover, one scenario per acceptance criterion:

1. **Round-trip (US3 / SC-003)** — `write/1` then `read/1` returns a record whose
   fields equal what was written (`last_phase`, `status`, `reason`, `session_id`).
2. **Absent read (US3 / FR-006b)** — `read/1` for a feature with no checkpoint
   returns `{:error, :no_checkpoint}`.
3. **Corrupt read (FR-006c)** — a `checkpoint.json` containing malformed/non-object
   content yields `{:error, :corrupt}`, distinct from absent.
4. **Diverted write (US1 / SC-001)** — writing with `last_phase: :clarify,
   status: :escalated` (and `:analyze`/`:halted`) round-trips those exact values.
5. **Tuple reason (FR-004)** — a `reason` such as `{:breaker, "budget"}` is stored
   as its `inspect/1` string and does not fail the write.
6. **Delete on done (US2 / FR-005)** — after a prior `write/1`, `delete/1` removes
   the record so a later `read/1` returns `{:error, :no_checkpoint}`; `delete/1` on
   an absent checkpoint is a no-op returning `:ok`.
7. **Best-effort write (SC-004)** — a forced write failure (e.g. an unwritable
   transcript root) returns `:ok` and raises nothing.

Full suite stays green (no regression in `FeatureRunner`):

```bash
mise exec -- mix test
```

## Manual validation (secondary, iex)

```bash
mise exec -- iex -S mix
```

```elixir
alias SpeckitOrchestrator.Checkpoint

# absent
Checkpoint.read("999-demo")
#=> {:error, :no_checkpoint}

# write a diverted checkpoint (reason is a tuple)
Checkpoint.write(%{feature_id: "999-demo", last_phase: :clarify,
                   status: :escalated, reason: {:needs_human, "ambiguous spec"},
                   session_id: "sess-abc"})
#=> :ok

# read it back — fields match, reason is the inspect string
Checkpoint.read("999-demo")
#=> {:ok, %{"feature_id" => "999-demo", "last_phase" => "clarify",
#           "status" => "escalated", "reason" => "{:needs_human, \"ambiguous spec\"}",
#           "session_id" => "sess-abc"}}

# a completed re-run removes it
Checkpoint.delete("999-demo")
#=> :ok
Checkpoint.read("999-demo")
#=> {:error, :no_checkpoint}
```

Confirm the file lived under the durable transcript root (co-located with per-phase
transcripts, keyed by feature id — FR-009):

```bash
ls "$(mise exec -- elixir -e 'IO.puts SpeckitOrchestrator.Config.transcript_root()')"/999-demo/
```

## End-to-end check (optional, ties to FeatureRunner)

Drive a feature to a diverted terminal (e.g. an `:escalated` clarify) through
`FeatureRunner.run/2` and confirm `Checkpoint.read(feature.id)` reports the halted
phase and status matching the divert point (SC-001, SC-005: determined from the
checkpoint alone, without opening any transcript). Then drive a feature to `:done`
and confirm no checkpoint remains (SC-002).

## Success signals

- `read/1` distinguishes record / absent / corrupt in 100% of cases (SC-003).
- Every non-`:done` terminal produces a checkpoint whose `last_phase` matches the
  divert phase (SC-001); every `:done` terminal leaves none (SC-002).
- A forced write failure never fails the run (SC-004).
- `mise exec -- mix compile` clean under `warnings_as_errors`; `mise exec -- mix
  test` green.
