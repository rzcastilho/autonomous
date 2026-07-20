# 003 — Operator prompt injection at the resume phase

## Summary

Inject the human operator's fix/guidance prompt into the phase being resumed —
and only that phase — by appending it to that phase's `PhaseRequest` prompt.

## Context

When a human resolves the cause of an escalation/halt, they supply a short prompt
describing the fix. That guidance must steer the resumed phase (e.g. re-run
clarify with "resolved: use integer cents") without leaking into any downstream
phase, which must run clean. `PhaseRequest.build/3` already assembles per-phase
prompts and accepts an opts keyword list (`phase_request.ex:38-48`), and feature
002 carries `resume_phase` / `resume_prompt` in agent state.

## User value

On resume, the operator's guidance reaches exactly the phase being restarted,
appended to its slash-command prompt — steering that one phase while later phases
proceed unaffected.

## Prerequisites

- 002 FeatureRunner resume entry point (`resume_phase` / `resume_prompt` in agent
  state).

## In scope

- `PhaseRequest.build/3`: accept a `:resume_prompt` opt. When present and
  non-nil, append to the assembled prompt:
  `"\n\n---\nOperator guidance (resume): #{resume_prompt}"`. No change to model
  routing, per-phase permissions, or `session_id`.
- `RunFeaturePhase` (`actions/run_feature_phase.ex:57`): pass `resume_prompt:
  resume_prompt_for(state, phase)` into `PhaseRequest.build/3`, where
  `resume_prompt_for/2` returns `state.resume_prompt` only when `phase ==
  state.resume_phase`, and `nil` otherwise. Transient retries of the resume phase
  re-inject the guidance — intended.

## Out of scope

- The `resume/2` operator facade (feature 004).
- Claude session resume — sessions stay fresh per phase; the prompt (not a
  resumed session) carries the human intent.

## Acceptance

- `PhaseRequest.build/3` with `:resume_prompt` appends the guidance line; without
  it, the built prompt is byte-identical to today's output.
- Across a multi-phase run, `RunFeaturePhase` injects the prompt when `phase ==
  resume_phase` and omits it at every other phase.
- Compile clean under `warnings_as_errors`; tests green.

## Technical notes

- Keep the injection strictly append-only so existing per-phase prompt tests
  remain valid when no `resume_prompt` is passed.
