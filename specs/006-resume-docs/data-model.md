# Data Model: Resume Docs & Operator Runbook

This is a documentation feature — there are no runtime entities or persisted
records. The "data model" is the **documented surface** the prose must render
faithfully and the **doc artifacts** it lives in. Captured here so `tasks.md` and
the parity check (SC-002) have a concrete field list.

## Entity: `resume/2` documented API surface

The read-only contract the docs describe. Source of truth:
`lib/speckit_orchestrator.ex` `resume/2` `@doc`/`@spec`.

| Field | Value / Type | Doc requirement |
|-------|--------------|-----------------|
| Call | `SpeckitOrchestrator.resume(feature_id, opts \\ [])` | Exact arity + name in every example (FR-002, SC-002) |
| `feature_id` | `String.t()` (e.g. `"003"`) | Shown as the first positional arg |
| Default start phase | checkpoint `record.last_phase` | "restarts at the halted/escalated phase by default" (FR-003) |
| `:from` opt | pipeline phase atom; overrides checkpoint phase | Documented as the override for restarting earlier, with *when to reach for it* (FR-004) |
| `:prompt` opt | `String.t() \| nil`; carried as `resume_prompt` | Documented as operator guidance injected into the resumed phase (FR-004) |
| Pass-through opts | same as `run/1` (`:features`, `:runner`, …) | Mentioned as inherited, not re-specified |
| Error: unknown id | `{:error, {:unknown_feature, id}}` | Listed as a safe no-run failure |
| Error: no checkpoint | `{:error, :no_checkpoint}` | Listed; drives the "fall back to `resolve/1`" criterion (FR-005) |
| Error: corrupt checkpoint | `{:error, :corrupt_checkpoint}` | Listed; also a `resolve/1` fallback trigger |
| Error: bad phase | `{:error, {:unknown_phase, term}}` | Listed (guards a bad `:from`) |

## Entity: recovery-path decision (FR-005)

| Path | When | Documented in |
|------|------|---------------|
| `resume/2` | checkpoint exists; fix is local to a phase's inputs (typical analyze-halt) | new runbook resume section |
| `resolve/1` | fix must regenerate upstream artifacts (breakdown `## Decisions` re-read by `specify`); no/corrupt checkpoint; want full rebuild | existing runbook escalation section, cross-linked |

## Entity: documentation artifacts (edit targets)

| Artifact | Change | Requirement |
|----------|--------|-------------|
| `docs/runbook.md` | ADD `resume/2` recovery section (loop, `:from`, `:prompt`, decision criteria); FIX line ~281 "resume is v2" framing | FR-001..FR-005, FR-007 |
| `CLAUDE.md` | UPDATE observability/operability paragraph (~124–132) to name shipped `resume/2` | FR-006 |
| Other repo `.md` | Sweep confirms none carry stale framing (current: none beyond runbook:281) | FR-007, SC-003 |
| `lib/speckit_orchestrator.ex` | **Read-only** — signature source; `resolve/1` "v2" docstring untouched | Out of scope (spec Assumptions, clarify ruling) |

## State transitions

None — no runtime state. The *documented* state semantics are: a checkpointed
feature (`:halted` / `:escalated`, worktree kept) → operator fixes on the feature
branch → `resume/2` restarts the pipeline at the checkpointed (or `:from`-overridden)
phase. This mirrors Constitution Principle V and is described, not implemented.
