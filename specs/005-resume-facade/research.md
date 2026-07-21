# Phase 0 Research: Resume Facade

All Technical Context items were resolvable from the existing codebase and the
three prerequisite features; no external/NEEDS CLARIFICATION items remained. The
open decisions were integration-shape decisions, resolved below.

## Decision 1 — Start-phase resolution & the string→atom boundary

**Decision**: Resolve `start_phase` in the facade as
`opts[:from] || parse(checkpoint["last_phase"])`, where both the operator
override and the checkpoint's stored value are validated against
`Pipeline.phases/0` before any run starts. The override arrives as an atom; the
checkpoint stores the phase as a **string** (`Checkpoint.write/1` does
`Atom.to_string/1`). Convert the checkpoint string with `String.to_existing_atom/1`
guarded by a membership check against `Pipeline.phases/0` — never
`String.to_atom/1` on stored data (atom-table safety).

**Rationale**: `FeatureRunner.run` expects `:start_phase` as an atom and calls
`Pipeline.step_of/1`, which returns `nil + 1` (a crash) for an unknown phase. The
boundary must guarantee a known phase atom or reject — Principle II. Validating
the checkpoint's own stored phase too (not only the operator override) means a
checkpoint hand-edited to an unknown phase is caught here rather than crashing the
runner.

**Alternatives considered**:
- *Pass the raw string through to the runner* — rejected: the runner treats
  `:start_phase` as an atom; a string silently mismatches every phase.
- *`String.to_atom/1`* — rejected: unbounded atom creation from file contents.
- *Trust the checkpoint blindly* — rejected: violates SC-005 (invalid stored
  phase must produce a distinct result, not a crash or wrong-phase resume).

## Decision 2 — Distinct error taxonomy (fail-loud, no collapsing)

**Decision**: Return these distinct results, each starting **no** run:

| Condition | Result |
|---|---|
| unknown feature id | `{:error, {:unknown_feature, id}}` (matches `resolve/1`) |
| no checkpoint file | `{:error, :no_checkpoint}` |
| checkpoint present but unreadable/corrupt | `{:error, :corrupt_checkpoint}` |
| `:from` (or stored phase) not a real pipeline phase | `{:error, {:unknown_phase, phase}}` |
| branch gone → worktree cannot be recreated | `{:error, {:worktree, reason}}` |

**Rationale**: SC-004/SC-005 require every failure mode to be independently
recognizable and to never silently fall back. `Checkpoint.read/1` already
distinguishes `{:error, :no_checkpoint}` from `{:error, :corrupt}` (mapped to the
facade's `:corrupt_checkpoint` to keep the operator-facing name self-describing);
the facade must preserve that split rather than treating both as "no checkpoint".

**Alternatives considered**:
- *Collapse corrupt into `:no_checkpoint`* — rejected explicitly by the
  clarification session (Q1) and SC-005.
- *Fall back to `Pipeline.first()` on a bad override* — rejected: SC-005 forbids
  a silent fall-through to phase one.

## Decision 3 — One-feature wave + resume-runner wrapper

**Decision**: Mirror the `run_spec` → `spec_run_opts` pattern:
`resume/2` builds `opts` with `:features => [feature]` and injects a private
**resume runner** wrapping the default runner. The wrapper (a) reuses the kept
worktree if the dir exists else recreates it via `Worktree.create` (which reuses
the existing branch — `worktree.ex:152`), then (b) calls
`FeatureRunner.run(feature, worktree: wt, ledger: Ledger, notify: notify,
start_phase: start_phase, resume_prompt: opts[:prompt])`. On `Worktree.create`
failure the wrapper notifies `:failed` with `{:worktree, reason}` exactly as
`default_runner/2` does. Delegate to `run/1` so Coordinator start/stop,
`on_start` return, and opts passthrough (FR-008) are inherited unchanged.

**Rationale**: This is the established, tested shape for "one feature, wrapped
runner" (`speckit_orchestrator.ex:247-289`). Reusing it keeps resume consistent
with the rest of the operator surface and avoids re-implementing Coordinator
wiring. A caller-supplied `:runner` (test seam) must still win, so the wrapper is
only injected when the caller did not supply one — same guard `run_spec` uses.

**Alternatives considered**:
- *Bypass the Coordinator and call `FeatureRunner.run` directly* — rejected:
  loses the uniform `on_start` return, status reporting, and Ledger wiring;
  diverges from `run/1`.
- *A brand-new Coordinator entry* — rejected: unnecessary; the `:features` +
  `:runner` seams already express a one-feature wave.

## Decision 4 — Worktree reuse vs. recreate, and branch-gone propagation

**Decision**: In the resume runner, `Worktree.locate/2` the feature; if the path
exists, reuse it; else `Worktree.create/2` to recreate from the existing branch.
If the branch itself is gone, `Worktree.create` fails and that error is propagated
as `{:error, {:worktree, reason}}` (via the `notify(:failed, …)` path) — resume
never starts a fresh unrelated branch (FR-005, edge case, SC-005).

**Rationale**: An operator who ran `resolve/1` has a kept branch but no worktree;
the common resume case must recreate the tree from that branch so the committed
fix is present. `Worktree.create` already implements branch reuse, so no new
git logic is needed — only routing its failure to a distinct result.

**Alternatives considered**:
- *Always recreate (ignore an existing worktree)* — rejected: needless churn and
  risks discarding uncommitted post-mortem state in a kept worktree.
- *Silently `specify`-init a new branch when the branch is missing* — rejected:
  directly violates FR-005 and Principle V.

## Decision 5 — `resolve/1` left intact

**Decision**: No change to `resolve/1`. Resume is strictly additive; the
full-restart path (clear worktree → next `run/1` starts over) stays as the
separate, distinct operation (FR-009).

**Rationale**: The two recovery paths serve different operator intents (restart
mid-pipeline vs. start the feature over). Keeping both avoids a behavior
regression for anyone relying on the full-restart semantics.
