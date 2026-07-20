# Phase 0 Research: Resume Checkpoint Persistence

No open `NEEDS CLARIFICATION` remained after `/speckit.clarify` (the corrupt-vs-absent
read distinction was resolved in the spec's Clarifications section). The decisions
below record the technical choices that shape Phase 1.

## Decision 1 — Storage format and location

**Decision**: One JSON document per feature at
`<Config.transcript_root>/<feature_id>/checkpoint.json`.

**Rationale**: FR-009 requires records under the same durable root as per-phase
transcripts, keyed by feature id. `Config.transcript_root/0` already resolves that
root (`config.ex:47`), and `Transcripts` already writes durable per-phase copies
to `<transcript_root>/<feature_id>/NN-<phase>.md`. Placing `checkpoint.json` in the
same per-feature directory keeps a feature's durable artifacts co-located. JSON is
already the project's machine-readable serialization convention (used by
`AnalyzeResult`, `Describe`), and Jason is available.

**Alternatives considered**:
- Erlang term file (`:erlang.term_to_binary` / `File.write` of `inspect`): rejected
  — not the project's "machine-readable serialized document" convention (Assumptions);
  harder for an operator/external tool to inspect than JSON.
- A single shared index file for all features: rejected — introduces multi-writer
  contention the spec explicitly rules out (Assumptions: one record per feature,
  single finalizer), and complicates the per-feature delete-on-done.

## Decision 2 — Serializing the terminal reason

**Decision**: Store `reason` as its `inspect/1` string.

**Rationale**: FR-004 / the "non-serializable reason" edge: a terminal reason can be
a compound value (e.g. a tuple like `{:breaker, ...}` or `{kind, err}` from the
runner's catch clause). JSON cannot encode a raw tuple, and a naive encode would
raise and (given best-effort write) silently drop the checkpoint. `inspect/1`
produces a human- and machine-readable string for any term without failing — the
same approach `Transcripts.render/2` already uses for `cost_usd`/`num_turns`. The
stored reason is thus always a JSON string.

**Alternatives considered**:
- `Jason.encode` the reason directly: rejected — raises on tuples/PIDs, defeating
  the "never causes a write failure" requirement.
- Structured decomposition of every possible reason shape: rejected — over-engineered
  for a post-mortem pointer; the reason is informational, not re-parsed into control
  flow by this feature (FR-010, out of scope).

## Decision 3 — Best-effort write vs. fail-loud read

**Decision**: `write/1` is best-effort (`rescue -> :ok`, mirroring
`Transcripts.maybe_write_durable/4` at `transcripts.ex:36-49`); `read/1` fails loud
with a distinct signal on a corrupt file.

**Rationale**: FR-008 / SC-004 — a write failure (unwritable location, I/O error,
serialization problem) MUST NOT fail or crash the run; the run must still finalize
at its correct terminal state. This is the same contract the durable transcript
write already honors. The read side is the opposite (Constitution II, FR-006): an
existing-but-unparseable file MUST surface `{:error, :corrupt}`, distinct from the
`{:error, :no_checkpoint}` absent case, so a caller (the future resume feature)
never confuses "damaged record" with "never checkpointed" and never receives
fabricated fields.

**Alternatives considered**:
- Best-effort read that returns `:no_checkpoint` on any failure: rejected — collapses
  corrupt into absent, violating FR-006 and the clarified requirement.
- Asserting (`File.write!`) in write and letting the runner's catch handle it:
  rejected — a checkpoint write failure would then mark the whole feature `:failed`
  (the runner catch clause), violating FR-008.

## Decision 4 — Wiring point in FeatureRunner

**Decision**: Write/delete the checkpoint in `FeatureRunner.run/2` after `loop/7`
returns, beside the existing `handle_worktree/3` call (`feature_runner.ex:74-81`),
using `agent.state.phase` (last phase run, set by `RunFeaturePhase`),
`agent.state.session_id`, and the `status`/`reason` the loop returned.

**Rationale**: This is the single finalization point where the halted phase, status,
reason, and session id are all in hand (Assumptions). `agent.state.phase` is exactly
the phase the pipeline diverted at, satisfying FR-003 / SC-001. On `:done`, call
`Checkpoint.delete/1` so no stale pointer lingers (FR-005 / SC-002). The catch clause
(unexpected crash → `:failed`) is left to write its checkpoint too, best-effort, so a
crashed run is also recorded — but that path has no live agent state, so it is handled
carefully (see data-model open note) or left to the normal-return path only, per the
breakdown which places the write beside `handle_worktree/3` on the success path.

**Alternatives considered**:
- Writing inside `FinalizeFeature` action (agent-side): rejected — the agent dies with
  the runner and the action returns a state map; the durable write belongs in the
  runner where the transcript/worktree finalization already lives (Constitution I keeps
  the agent action a pure state update).
