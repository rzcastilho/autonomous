# Phase 0 Research: Pre-phase remediation prompt at resume

No external/unknown technologies — this feature composes existing internal
seams. "Research" here resolves the design decisions that turn the spec's FRs
into a placement on the current architecture. Each decision records the choice,
why, and the rejected alternative.

## D1 — Where the remediation step executes

**Decision**: A new Jido action `SpeckitOrchestrator.Actions.RunRemediation`,
routed by a new `"remediation.run"` signal on `FeatureAgent`, driven **once** by
`FeatureRunner.run/1` *before* the phase loop (after `feature.init`, before the
first `loop/…` call).

**Rationale**: Every model execution in this system already flows through the
agent via an action (`RunFeaturePhase`), which is where cost folding, history
entries, and `last_result` capture live. Making remediation a sibling action
keeps that plumbing uniform and lets the `FakeSDK` test seam
(`:jido_claude, :sdk_module`) cover it for free. `FeatureRunner` remains the pure
orchestrator (it already owns "run this, inspect state, decide next").

**Alternatives rejected**:
- *Inline `Jido.Harness.run_request/3` directly in `FeatureRunner`* — duplicates
  cost/`Ledger`/`PhaseResult`-fold logic, bypasses the agent's state folding, and
  splits harness contact across two modules. Violates the single-execution-path
  intent of Principle I's boundary isolation.
- *Fold remediation text into the target phase's own prompt* — explicitly
  rejected by the spec (Assumptions): a read-only phase like `analyze` cannot fix
  what it only evaluates; the fix must be a **separate** write-capable execution.

## D2 — Request construction

**Decision**: Add a pure `PhaseRequest.build_remediation/3(feature, model, opts)`
returning a `%Jido.Harness.RunRequest{}`. Prompt = a short framing header
(feature id/slug + worktree-relative breakdown ref, mirroring the phase prompts)
followed by the operator's verbatim remediation text. `cwd` = worktree,
`model` = the resolved remediation model (D4), permissions = the write-capable
contained set (D3). No `session_id` (fresh session, like every phase).

**Rationale**: Request assembly stays side-effect-free and unit-testable
alongside `PhaseRequest.build/3` (Principle I). Reusing the existing module keeps
the `breakdown_ref`/`Layout` resolution and permission helpers in one place.

**Alternatives rejected**:
- *Separate `RemediationRequest` module* — no reuse of `breakdown_ref`,
  `permissions/1`, `maybe_put/3`; needless duplication for one builder.

## D3 — Containment / permissions

**Decision**: The remediation `RunRequest` uses
`permission_mode: :accept_edits` with `allowed_tools: ~w(Read Write Edit Bash
Grep Glob)` — the same write-capable set the write phases (specify/plan/tasks/
implement/converge) use.

**Rationale**: The step must *edit artifacts* (that is its purpose), so a
read-only set (like `analyze`'s) would make it useless. FR-009 requires
containment **no weaker than a normal phase** — this set is exactly a normal
write phase's, and the committed `scope_guard.py` PreToolUse hook still denies
out-of-tree writes and dangerous Bash regardless of the prompt. Defense-in-depth
holds (Principle III); the operator prompt cannot broaden reach.

**Alternatives rejected**:
- *Reuse `analyze`'s read-only permissions* — the step could not write the fix.
- *A looser mode (bypass/none)* — would weaken containment below a phase,
  violating FR-009 and Principle III.

## D4 — Model routing

**Decision**: Default the remediation model to `Config.model_for(target_phase)`;
allow override via the resume opt `:remediation_model` (a CLI alias — `opus` /
`sonnet`). The chosen model is validated (fail loud on an unknown alias) and is
passed **only** to the remediation request — it never touches the target phase's
own `Config.model_for/1` routing.

**Rationale**: FR-011. Defaulting to the target phase's model means "fix the
thing this phase cares about with the same calibre of model." The override lets
an operator escalate (e.g. force `opus`) for a hard fix. Validating the alias
keeps a typo from silently mis-routing (Principle II).

**Alternatives rejected**:
- *Always the target-phase model, no override* — fails FR-011's override clause.
- *Free-form model string* — the pinned SDK catalog rejects full strings; the
  system already routes on `opus`/`sonnet` aliases (`Config`). Accepting arbitrary
  strings would reintroduce the exact breakage `Config` exists to prevent.

## D5 — Observability (telemetry + transcript)

**Decision**: Wrap the step in the **existing** `:telemetry.span([:speckit,
:phase], meta, …)` with `meta.phase = :remediation` and `meta.step = 0`, and
write its transcript via `Transcripts.write(worktree, layout, 0, :remediation,
result)` → `00-remediation.md` (both worktree and durable root).

**Rationale**: FR-012 asks for parity "same as any phase." Reusing the
`[:speckit, :phase]` span means `Telemetry.attach_default_logger/0` logs it with
no change, and the `00-` step ordering places remediation visibly *before* the
target phase's `NN-<phase>.md` in the transcript directory. SC-006's post-mortem
trail is satisfied by the same machinery phases already use.

**Alternatives rejected**:
- *Dedicated `[:speckit, :remediation]` event* — would require a new telemetry
  handler and diverge from "same as a phase"; no benefit.

## D6 — Retry & failure semantics

**Decision**: Reuse `run_phase_with_retry`'s policy for the remediation step —
`Config.phase_max_retries()` re-runs on a `PhaseResult.transient?/1` failure. A
failure that persists past the retries (or a non-transient error) is a **genuine
failure**: `FeatureRunner` does **not** run the target phase, finalizes the
feature `:failed`, checkpoints, retains the worktree, and notifies.

**Rationale**: FR-006 mandates auto-retry parity with a phase, then a hard stop
on genuine failure; SC-005 requires the operator always sees a remediation
failure rather than the phase running on unremediated artifacts. Reusing the
existing retry helper keeps one policy.

**Alternatives rejected**:
- *No retry (any error stops)* — regresses below phase behavior; a single dropped
  stream would waste the resume.
- *Proceed to the phase on remediation failure* — directly violates FR-006/SC-005.

## D7 — Scoping to one resume (no leak, independent of the in-phase note)

**Decision**: The step is invoked structurally **once**, inside
`FeatureRunner.run/1` before the loop — never inside the per-phase loop — so it
cannot precede any later phase (FR-005/SC-003). It is carried by **separate**
agent state (`remediation_prompt` / `remediation_model`) and a **separate** signal
from the feature-004 in-phase note (`resume_prompt`), which continues to append
to the target phase's own prompt via the unchanged
`PhaseRequest.append_resume_prompt/2` path. Neither suppresses the other
(FR-010).

**Rationale**: Placing the call outside the loop is the simplest structural
guarantee of "at most once, before the target phase only." Keeping the two
prompts on distinct fields/signals makes their independence a data fact, not a
convention.

**Alternatives rejected**:
- *Insert remediation as a pseudo-phase in the pipeline table* — would risk
  re-firing and entangle it with `Pipeline.next/3`'s pure transition logic.
- *Overload `resume_prompt` to mean both* — couples two independent operator
  inputs, breaking FR-010.

## D8 — Facade surface & blank handling

**Decision**: `resume/2` gains `:remediation_prompt` and `:remediation_model`
opts, threaded through `inject_resume_strategy/6` → `resume_runner/4` /
`resume_executor/4` → `FeatureRunner.run/1`. A **blank** prompt (absent, empty,
or whitespace-only) leaves the resume byte-identical to today: no state field
set, no signal sent, no step, no cost (FR-004/SC-002). Remediation is **not**
threaded into `resume_run/1` (automatic crash recovery has no operator to supply
a prompt).

**Rationale**: Mirrors how feature 004's `:prompt` is already threaded, so the
change slots into the established resume plumbing. The blank check is the single
gate that guarantees the zero-overhead default path.

**Alternatives rejected**:
- *A truthy `:remediate` boolean + prompt* — redundant; a non-blank prompt is
  itself the opt-in signal, matching the existing `:prompt` convention.
- *Thread into `resume_run/1` too* — no operator in the automatic path; would be
  dead surface.
