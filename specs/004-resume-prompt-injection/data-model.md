# Phase 1 Data Model: Operator prompt injection at the resume phase

This feature introduces **no new persisted entity** and **no new struct field**.
It reads existing agent state and threads a plain string through one function
opt. The "entities" below are conceptual, matching the spec's Key Entities.

## Resume state (read-only here)

Carried in `FeatureAgent` state, seeded at init by feature 002/003. This
feature only **consumes** it.

| Field | Type | Source | Meaning |
|-------|------|--------|---------|
| `resume_phase` | `atom \| nil` | `FeatureAgent` schema (`feature_agent.ex:31`), set by `InitFeature` from the runner's `start_phase` | The phase the run was resumed at; the fixed anchor against which the currently-executing phase is compared. `nil` on a fresh run. |
| `resume_prompt` | `String.t() \| nil` | `FeatureAgent` schema (`feature_agent.ex:32`), set by `InitFeature` from the runner's `:resume_prompt` opt | The operator's free-text guidance for the resumed phase. `nil` on a fresh run. |

**Validation / states**: none added. `resume_prompt` is free text; no length
limit, no structured format, no sanitization beyond safe verbatim inclusion
(spec Assumptions). Blank values (`nil`, `""`, whitespace-only) are treated as
"no guidance".

## Phase prompt (assembled, transient)

The flat instruction string sent to the CLI for one phase execution, produced by
`PhaseRequest.build/3` → `%RunRequest{prompt: ...}`.

| Aspect | Behavior |
|--------|----------|
| Base body | Unchanged per-phase assembly (`prompt/2` clauses). |
| Guidance section | Appended **iff** the `:resume_prompt` opt is non-blank: `"\n\n---\nOperator guidance (resume): <prompt>"`. |
| When blank | Byte-identical to the base body (no marker, no separator). |

## Derived value: `resume_prompt_for(state, phase)`

Not persisted — computed per phase execution inside `Actions.RunFeaturePhase`.

```
resume_prompt_for(state, phase) =
  state.resume_prompt   when phase == state.resume_phase
  nil                   otherwise
```

- **Domain**: `(agent_state, atom) -> String.t() | nil`
- **Invariant**: returns non-nil for at most one phase per run (the resume
  anchor); returns `nil` for every phase on a fresh run (`resume_phase == nil`,
  so the equality is false for all real phase atoms).
- **Feeds**: the `:resume_prompt` opt of `PhaseRequest.build/3`. Blank-guarding
  (empty/whitespace) is enforced downstream in `build/3`, so this helper may
  return `state.resume_prompt` verbatim even if blank.

## Field-change summary

| File | Change | New field? |
|------|--------|-----------|
| `feature.ex` | none | no |
| `feature_agent.ex` | none (fields already present) | no |
| `phase_request.ex` | new `:resume_prompt` opt on `build/3` | no struct field |
| `actions/run_feature_phase.ex` | new private `resume_prompt_for/2`; pass opt into `build/3` | no |
