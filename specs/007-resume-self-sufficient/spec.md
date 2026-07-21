# Feature Specification: Self-Sufficient Resume (Checkpoint Carries Identity + Run Context)

**Feature Branch**: `007-resume-self-sufficient`

**Created**: 2026-07-21

**Status**: Draft

**Input**: User description: "Two bugs to fix: (1) When restarting from checkpoint I shouldn't need to pass feature info (the Feature struct with id/slug/path/status) — the checkpoint must already hold this so `resume/1` works from the id alone. (2) Context variables like `pr_workflow: true` used to initialize the run must be reused on resume — a run started with `SPECKIT_PR_WORKFLOW=true` did not honor that setting when a phase was resumed."

## Clarifications

### Session 2026-07-21

- Q: What overrides the recorded checkpoint run context at resume time? → A: Only an explicit `resume` call option overrides recorded context; live env/Config are the *original* source but at resume time serve only as fallback for values the checkpoint did not record. A recorded value always wins over a live env/Config value.
- Q: Which settings does the persisted run context cover? → A: Only the run-shaping flags (`pr_workflow`, concurrency cap, budget, plan stack, `pr_base`, `pr_remote`). The target `repo` and `breakdown_dir` stay env-supplied at each invocation — `repo` because the checkpoint is located *via* it (circular dependency), and `breakdown_dir` because identity now comes from the checkpoint. Model routing and other static config are out of scope.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Resume from the feature id alone (Priority: P1)

An operator resolved a halted or escalated feature and wants to restart it from its
checkpoint. Today they must reconstruct and pass the full work-unit definition
(id, slug, artifact path, status) alongside the id, even though the system already
recorded that feature when it checkpointed it. The operator should be able to
resume with only the feature id (plus an optional guidance note), and the system
should recover the feature's identity from what it saved at checkpoint time.

**Why this priority**: This is the primary operator ergonomic and correctness
defect the user hit. Requiring the operator to hand-type identity fields is both
tedious and error-prone — a mistyped slug or path silently points the resume at
the wrong branch/worktree. Recovering identity from the checkpoint removes a whole
class of operator mistakes and is the minimum viable fix.

**Independent Test**: Check a feature out to a halted state so a checkpoint is
written, then resume it supplying only the feature id and an optional note (no
explicit work-unit definition, no reliance on a backlog listing). Verify the
feature resumes on its existing branch at the checkpointed phase with the correct
slug and artifact path.

**Acceptance Scenarios**:

1. **Given** a feature that halted and wrote a checkpoint, **When** the operator
   resumes it with only the feature id, **Then** the run restarts at the
   checkpointed phase using the feature's recorded identity (slug, artifact path),
   with no requirement to supply that identity.
2. **Given** the same halted feature, **When** the operator resumes with the id
   and an optional guidance note, **Then** the note is carried into the resumed
   phase exactly as before, and identity is still recovered from the checkpoint.
3. **Given** a feature that is present in the current backlog listing, **When** the
   operator still supplies an explicit work-unit definition, **Then** resume
   continues to honor that explicit input (backward compatible), and any
   difference between it and the checkpoint is resolved by a defined precedence
   rule (see FR-003).
4. **Given** a resume for an id with no checkpoint on disk, **When** resume runs,
   **Then** it fails with the existing distinct "no checkpoint" outcome and starts
   no run (unchanged from today).

---

### User Story 2 - Resume reuses the original run context (Priority: P1)

An operator started a run under a specific context — for example the stacked
sequential PR workflow (`pr_workflow: true`), a non-default concurrency cap, a cost
budget, or a fixed plan stack. When they later resume a phase of that run, the
resumed phase must execute under the same context it was originally launched with.
Today the context is only present in the process environment at the moment the
application booted; a resume is a separate invocation, so if the environment no
longer carries those settings the resumed phase silently runs under defaults —
e.g. a PR-workflow run resumes as a non-PR run.

**Why this priority**: This is a silent-correctness defect. A stacked PR-workflow
feature resumed without its context runs with the wrong execution shape (wrong
concurrency, no stacking/preflight, no PR on completion) with no error surfaced —
exactly the "fail loud, never carry a silently wrong state" concern the project
constitution calls out. It must be fixed alongside Story 1 for resume to be
trustworthy.

**Independent Test**: Start a run whose context differs from the defaults (e.g.
the PR workflow enabled), drive a feature to a checkpointed non-done state, then
resume that feature in a fresh invocation whose environment does **not** re-declare
that context. Verify the resumed feature executes under the original context (PR
workflow still in effect: cap 1, stacking/preflight behavior, PR-on-done), not the
defaults.

**Acceptance Scenarios**:

1. **Given** a run started with the PR workflow enabled that then checkpointed a
   feature, **When** the operator resumes that feature in an invocation whose
   environment does not set the PR workflow, **Then** the resumed feature still
   runs under the PR workflow (sequential cap, stacking/preflight, PR on
   completion).
2. **Given** a run started with a non-default concurrency cap, cost budget, or
   plan stack, **When** a feature from that run is resumed, **Then** the resumed
   feature honors those same values rather than the compile-time defaults.
3. **Given** an operator who explicitly overrides a context value at resume time,
   **When** resume runs, **Then** the explicit override wins over the recorded
   context (see FR-007), so a human can still deliberately change the shape of a
   resumed run.
4. **Given** a checkpoint from an older run that predates recorded context, **When**
   it is resumed, **Then** resume falls back to the current live context/defaults
   without crashing, and this fallback is observable (see FR-008).

---

### Edge Cases

- **Corrupt checkpoint**: A checkpoint that exists but cannot be read/parsed must
  keep the existing distinct "corrupt checkpoint" failure and start no run —
  recovering identity/context must never fabricate missing fields to paper over
  corruption.
- **Partial context**: A checkpoint that recorded some but not all context values
  must apply the values it has and fall back to live/default for the rest, without
  crashing.
- **Identity drift**: The identity recorded at checkpoint time disagrees with a
  backlog entry the operator also supplies (e.g. slug renamed). Precedence must be
  defined and deterministic (FR-003), not order-dependent.
- **Unknown-feature resume**: Resuming an id that has neither a checkpoint nor any
  other recorded identity must fail with the existing "unknown feature" style
  outcome and start no run.
- **Invalid/overridden phase**: A checkpointed phase (or explicit start-phase
  override) that isn't a real pipeline phase keeps the existing distinct
  "unknown phase" failure — unchanged.
- **Sensitive context**: Recorded context must not persist secrets (API keys,
  tokens); only run-shaping settings are captured (see FR-011).

## Requirements *(mandatory)*

### Functional Requirements

**Feature identity (Story 1)**

- **FR-001**: When a feature checkpoints at a non-done terminal state, the system
  MUST persist enough of the feature's identity to fully reconstruct its work-unit
  definition on resume — at minimum its id, slug, and breakdown/artifact path, plus
  any field required to locate its branch and worktree.
- **FR-002**: `resume` MUST reconstruct the feature's work-unit definition from the
  checkpoint's recorded identity when the caller does not supply an explicit
  definition, so a resume can be issued with only the feature id (plus optional
  guidance/override options).
- **FR-003**: When both a checkpoint identity and a caller-supplied definition exist
  for the same id, the system MUST resolve them by a single documented precedence
  rule (RECOMMENDED: an explicitly supplied definition wins; otherwise the
  checkpoint identity is used) and MUST NOT depend on argument ordering.
- **FR-004**: Resume MUST NOT require a backlog listing to be present or loadable in
  order to recover identity from a checkpoint (a feature that was never in a
  breakdown backlog — e.g. a single-spec run — MUST still resume from its id alone).
- **FR-005**: All existing resume preconditions and their distinct failure outcomes
  MUST be preserved: no-checkpoint, corrupt-checkpoint, unknown-phase, and the
  worktree/branch-missing failure each remain distinct and start no run.

**Run context (Story 2)**

- **FR-006**: The system MUST persist the run-shaping context under which a feature
  was launched so it can be reapplied on resume. This context is EXACTLY: the
  PR-workflow flag, concurrency cap, cost budget, plan stack, PR base, and PR remote
  — the settings that determine the execution shape of a run. The target `repo` and
  `breakdown_dir` are OUT of the persisted context and remain env-supplied at each
  invocation: `repo` because the checkpoint file is located via it (a circular
  dependency), and `breakdown_dir` because feature identity now comes from the
  checkpoint (FR-001). Static configuration such as model routing is out of scope.
- **FR-007**: On resume, the system MUST reapply the recorded run context so the
  resumed phase executes under the same shape as the original run. A recorded value
  MUST take precedence over the live env/Config value for the same setting. The
  ONLY thing that overrides a recorded value is an explicit option passed to the
  `resume` call itself; live env/Config values are NOT treated as overrides — at
  resume time they serve only as fallback for settings the checkpoint did not
  record (FR-008). Precedence: explicit `resume` option > recorded context > live
  env/Config/default.
- **FR-008**: When a checkpoint has no recorded context (e.g. predates this
  feature) or has only partial context, resume MUST fall back to the current live
  configuration/defaults for the missing values without crashing, and MUST make the
  fallback observable to the operator (e.g. a log line), consistent with the
  project's fail-loud-at-boundaries principle.
- **FR-009**: Reapplied context MUST route the resumed run through the same
  execution path it would have taken originally — in particular, a resumed
  PR-workflow feature MUST run sequentially (cap 1) with the stacking/preflight and
  PR-on-completion behavior of the original run.

**Cross-cutting**

- **FR-010**: Persisting identity and context MUST remain best-effort at
  checkpoint-write time — a failure to record them MUST NOT break the running
  feature (a checkpoint write already never breaks a run).
- **FR-011**: The persisted context MUST NOT include secrets or credentials
  (e.g. API keys/tokens); only run-shaping settings are recorded.
- **FR-012**: The operator-facing resume documentation (runbook) MUST be updated so
  the documented resume invocation is the id-only form, and the removal of the
  hand-supplied identity requirement is reflected.

### Key Entities *(include if feature involves data)*

- **Checkpoint record**: The durable per-feature resume pointer. Currently holds
  the feature id, last phase, terminal status, reason, and session id. This feature
  extends it with (a) the feature's **identity** (slug, artifact path, and any field
  needed to rebuild the work-unit and locate its branch/worktree) and (b) the
  **run context** (the run-shaping settings enumerated in FR-006). It remains a
  single durable artifact per feature and is deleted on a done terminal.
- **Run context**: The set of run-shaping settings captured at run start and
  reapplied on resume — PR-workflow flag, concurrency cap, cost budget, plan stack,
  PR base, PR remote. Excludes secrets/credentials.
- **Feature work-unit**: The in-memory definition of a feature (id, slug, artifact
  path, status). Today the operator reconstructs it by hand for resume; after this
  feature it is reconstructed from the checkpoint's recorded identity.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: An operator can resume any checkpointed feature by providing only its
  id (and optional guidance/override), with zero hand-typed identity fields, in
  100% of cases where a valid checkpoint exists.
- **SC-002**: A feature launched with a non-default run context (e.g. PR workflow
  enabled) and then resumed in an environment that does not re-declare that context
  executes under the original context in 100% of resumes — 0 silent reversions to
  defaults.
- **SC-003**: All previously-distinct resume failure outcomes (no-checkpoint,
  corrupt-checkpoint, unknown-phase, unknown-feature, branch-missing) remain
  distinct and start no run — no regression versus current behavior.
- **SC-004**: Resuming a checkpoint that predates recorded identity/context
  succeeds via fallback (or fails only on a genuinely unrecoverable precondition)
  and never crashes; the fallback is visible to the operator.
- **SC-005**: A checkpoint-write failure while recording the new identity/context
  fields never interrupts the running feature (best-effort preserved).

## Assumptions

- The checkpoint remains a single durable per-feature artifact (extended in place),
  not a new separate store; it continues to be deleted on a done terminal.
- "Run context" is limited to the run-shaping settings already surfaced as
  configuration/`run` options (PR workflow, concurrency, budget, plan stack, PR
  base/remote). Model routing and other statically-configured values are out of
  scope unless they are already run-time overridable options.
- Explicit operator input at resume time is the intended override channel; the
  recorded context is a default, not a lock — a human can still change the shape of
  a resumed run deliberately.
- Secrets/credentials are supplied via the environment at each invocation and are
  intentionally NOT persisted in the checkpoint.
- Backward compatibility with the current `resume` signature (still accepting an
  explicit feature definition and existing options) is required; the id-only form
  is additive.
