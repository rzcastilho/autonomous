# 001 — Resume checkpoint persistence

## Summary

Persist a durable, machine-readable pointer to the phase a feature reached when
it terminated, so a later resume knows where to restart. This is the foundation
of the human-in-the-loop mid-pipeline resume flow.

## Context

A diverted feature (`:escalated` at clarify, `:halted` at analyze, or a gate
`:failed`) drains with its worktree kept and artifacts committed, but **nothing
records which phase it reached**. `Feature` has no phase field, and the
`FeatureAgent` state (which does hold `phase`) dies with the agent when the
runner stops. The only durable trace today is the branch, the Ledger spend, and
per-phase transcript files — none of which is read back to determine a restart
point.

## User value

Every terminated run leaves a checkpoint recording the halted phase and terminal
status. Independently valuable (operators can inspect *where* a feature stopped
without reading transcripts) and a prerequisite for automated resume.

## Prerequisites

None.

## In scope

- New module `SpeckitOrchestrator.Checkpoint`:
  - `write(feature_id, %{last_phase, status, reason, session_id})` — writes JSON
    to `<Config.transcript_root>/<feature_id>/checkpoint.json`. Best-effort
    (`rescue -> :ok`), mirroring `Transcripts.maybe_write_durable/4`. `reason`
    may be a tuple, so serialize it with `inspect/1`.
  - `read(feature_id) :: {:ok, map} | {:error, :no_checkpoint}`.
  - `delete(feature_id) :: :ok`.
- `FeatureRunner.run/2`: after `loop/7` returns, write the checkpoint from
  `agent.state.phase` (the halted phase — set by `RunFeaturePhase`) plus
  `status` / `reason` / `session_id`; on a `:done` terminal call
  `Checkpoint.delete/1` instead (a completed feature needs no resume pointer).
  Place beside the existing `handle_worktree/3` call (`feature_runner.ex:77-79`).

## Out of scope

- Reading the checkpoint back into a run (feature 004).
- Any resume/start-phase behavior (features 002-004).

This feature only *produces* the record.

## Acceptance

- Terminating a feature at a non-`:done` state writes a checkpoint whose
  `last_phase` matches the phase the pipeline diverted at.
- A `:done` terminal deletes any existing checkpoint for that feature.
- `read/1` round-trips a written checkpoint; returns `{:error, :no_checkpoint}`
  when the file is absent.
- A checkpoint write failure never fails or crashes the run.
- `mise exec -- mix compile` clean under `warnings_as_errors`; `mise exec -- mix
  test` green.

## Technical notes

- Reuse the durable-root + best-effort write pattern from `transcripts.ex:36-49`.
- `Config.transcript_root/0` already exists and is the same root `Transcripts`
  writes its durable per-phase copies to — the checkpoint lives alongside them,
  keyed by `feature_id`.
