# Phase 0 Research: Operator prompt injection at the resume phase

No open `NEEDS CLARIFICATION` remain — the stack, seams, and data are fully
determined by the existing codebase and the one clarification already recorded
in `spec.md` (blank `resume_prompt` handling). This document records the
decisions that shape the design.

## Decision 1 — Injection seam: `PhaseRequest.build/3`, append-only

- **Decision**: Append the operator guidance to the already-assembled prompt
  inside `PhaseRequest.build/3`, via a new `:resume_prompt` opt. The append is a
  trailing, clearly-delimited section: a blank-line separator, a marker line,
  then the verbatim guidance.
- **Rationale**: `build/3` is the single choke point where every phase's prompt
  is assembled (`phase_request.ex:38`). It already takes an `opts` keyword list
  (`:cwd`, `:session_id`), so adding `:resume_prompt` is idiomatic and touches
  no per-phase `prompt/2` clause. Append-only means the six existing per-phase
  prompt shapes are unchanged when no guidance is passed — the large body of
  per-phase prompt tests stays byte-valid (FR-003, SC-003).
- **Marker text**: `"\n\n---\nOperator guidance (resume): <prompt>"` (from the
  breakdown's technical notes). The `\n\n---\n` makes it visually distinct from
  the phase's own body (FR-002).
- **Alternatives considered**:
  - *Per-phase injection inside each `prompt/2` clause* — rejected: multiplies
    the change across every clause, and most clauses are bare slash strings that
    have no natural insertion point.
  - *A separate `RunRequest` field for guidance* — rejected: the adapter has no
    such field, and the CLI consumes one flat prompt; the guidance must be part
    of the prompt text to reach the model.

## Decision 2 — Per-phase gating: in `RunFeaturePhase`, not in the builder

- **Decision**: The action computes `resume_prompt_for(state, phase)` and passes
  the result as the `:resume_prompt` opt. It returns `state.resume_prompt` only
  when `phase == state.resume_phase`, and `nil` for every other phase.
- **Rationale**: Principle I (Pure Core) — the builder must stay side-effect
  free and must not reach into agent state to decide whether *this* is the
  resume phase. Extracting that decision upstream and passing a plain value in
  keeps `build/3` a pure function of its arguments. This mirrors how gate
  signals are extracted upstream and passed into `Pipeline.next/3`.
- **Consequence — retries re-inject (FR-006)**: because the decision is made per
  phase execution and `resume_phase`/`resume_prompt` are fixed in agent state, a
  transient retry of the resume phase (before the pipeline advances) recomputes
  the same non-nil value and re-injects the guidance. This is intended (Edge
  Cases, SC-004) and needs no extra "already injected" bookkeeping.

## Decision 3 — Blank guidance is a no-op (nil / "" / whitespace-only)

- **Decision**: Treat `nil`, `""`, and whitespace-only alike as "no guidance" —
  append nothing, not even the marker line. Guard on non-blank
  (`is_binary(x) and String.trim(x) != ""`).
- **Rationale**: The recorded clarification (`spec.md` §Clarifications) and
  FR-003/SC-003 require the fresh-run (non-resumed) prompt to be byte-identical
  to today. A whitespace-only or empty string reaching `build/3` must never emit
  a dangling marker with an empty body.
- **Alternatives considered**: *Guard only on `nil`* — rejected: an empty or
  whitespace `resume_prompt` would leak a meaningless `--- Operator guidance:`
  section, violating FR-003.

## Decision 4 — No change to routing / permissions / session (FR-007)

- **Decision**: The injection touches only `prompt`. `Config.model_for/1`,
  `permissions/1`, `max_turns/1`, and `:session_id` handling are untouched.
- **Rationale**: FR-007 is explicit. Each phase stays a fresh `claude -p`
  session; the human intent travels in the prompt text, not via a resumed
  session (breakdown "Out of scope"). Keeping the append the *only* delta makes
  the change auditable and the constitution check trivially clean.
