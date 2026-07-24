# Phase 1 Data Model: Pre-phase remediation prompt at resume

This feature is control-flow, not persistence. The "entities" are the operator
inputs, the agent state that carries them, and the discrete step they drive.
No new files/tables — cost lands in the existing `Ledger`, output in the existing
transcript/telemetry channels.

## Entities

### Remediation prompt (operator input)

| Field | Type | Notes |
|-------|------|-------|
| value | free-text string \| nil | Optional. The correction instruction, included verbatim in the remediation request. |

- **Validation**: *blank* = `nil`, `""`, or whitespace-only (`String.trim/1 == ""`).
  Blank ⇒ **no remediation step** (FR-004). Non-blank ⇒ exactly one step (FR-002).
- **Lifecycle**: supplied once at `resume/2`; consumed once, for the target phase
  of *this* resume only; never persisted, never re-applied to a later phase
  (FR-005).

### Remediation model override (operator input)

| Field | Type | Notes |
|-------|------|-------|
| value | model alias (`"opus"` \| `"sonnet"`) \| nil | Optional. Overrides the model driving the remediation step only. |

- **Validation**: an unknown alias is rejected loudly (Principle II). `nil` ⇒
  default to `Config.model_for(target_phase)` (FR-011).
- **Scope**: applies **only** to the remediation request; the target phase's own
  `Config.model_for/1` routing is unchanged (FR-011).

### Remediation step (derived execution)

A discrete model execution — one `%Jido.Harness.RunRequest{}` run through the
`:claude` adapter — sequenced strictly before the target phase.

| Aspect | Value |
|--------|-------|
| prompt | framing header (feature id/slug + worktree-relative breakdown ref) + operator prompt verbatim |
| cwd | the feature's existing worktree path |
| model | resolved remediation model (override → else target-phase model) |
| permissions | `:accept_edits`, allowed `Read Write Edit Bash Grep Glob` (write-capable, contained — FR-009) |
| session_id | none (fresh session, like every phase) |
| step index | `0` (before the target phase's `step_of/1`) |
| telemetry | `[:speckit, :phase]` span, `meta.phase = :remediation` (FR-012) |
| transcript | `00-remediation.md` in worktree `.speckit_logs/` + durable root (FR-012) |
| cost | `Cost.for_phase(:remediation, result)` → `Ledger.record` (FR-008) |
| retry | `run_phase_with_retry` on `PhaseResult.transient?/1` (FR-006) |

### Target phase (existing)

The pipeline phase the feature resumes at (`start_phase`; the checkpointed phase
or a `:from` override). Executes **after** the remediation step, observing
artifacts as the step left them (FR-003). Its model routing, permissions, and the
feature-004 in-phase `resume_prompt` are all unchanged (FR-010).

## Agent state additions (`FeatureAgent` schema)

New fields, both seeded by `Actions.InitFeature`, both defaulting to `nil`
(zero effect when absent):

```elixir
remediation_prompt: [type: {:or, [nil, :string]}, default: nil],
remediation_model:  [type: {:or, [nil, :string]}, default: nil],
```

These sit alongside the existing feature-004 resume anchors (`resume_phase`,
`resume_prompt`) and are **strictly independent** of them (FR-010).

## Control flow (`FeatureRunner.run/1`)

```text
start_agent
  └─ call "feature.init"  (seeds worktree, layout, start_phase,
                           resume_phase/resume_prompt,  ← feature 004
                           remediation_prompt/remediation_model)  ← NEW

  IF remediation_prompt is non-blank:                             ← NEW (FR-002)
    step = remediation_with_retry(agent)     # "remediation.run" signal,
                                             #   telemetry span + transcript(0)
    IF step.last_outcome == :error:          #   post-retry genuine failure
       finalize :failed → checkpoint → keep worktree → notify → RETURN   (FR-006)
    # else fall through — artifacts now carry the fix (FR-003)

  loop(start_phase …)                        # unchanged phase loop (FR-005:
                                             #   remediation never re-enters here)
  finalize / checkpoint / worktree / notify  # unchanged
```

**Invariants**

- **At-most-once, before target only**: the step is called outside `loop/…`, so
  it can precede only the target phase, never a subsequent one (FR-005/SC-003).
- **Zero overhead when blank**: a blank prompt skips the call entirely — no
  signal, no request, no cost, identical to today's resume (FR-004/SC-002).
- **No proceed on failure**: a genuine remediation failure returns before `loop`,
  leaving a `:failed`, worktree-retained, diagnosable state (FR-006/SC-005).
- **No auto-loop**: if the re-run target phase re-diverts (gate halt/escalation),
  normal terminal handling applies and nothing re-runs without a new operator
  action (FR-007).

## Facade thread-through (`resume/2`)

| Opt | Flows to | Effect |
|-----|----------|--------|
| `:remediation_prompt` | `inject_resume_strategy` → `resume_runner`/`resume_executor` → `FeatureRunner.run(remediation_prompt: …)` | Drives the step; blank ⇒ no step |
| `:remediation_model` | same path → `FeatureRunner.run(remediation_model: …)` | Overrides the step's model only |

Both are independent of the existing `:prompt` opt (feature-004 in-phase note)
and of each other. Not threaded into `resume_run/1` (no operator in the
automatic crash-recovery path).
