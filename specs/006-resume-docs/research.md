# Research: Resume Docs & Operator Runbook

Docs-only feature. No technology unknowns; "research" here resolves the exact
shipped surface the docs must describe and the precise set of stale references to
purge, so the implementation phase writes prose against facts, not guesses.

## Decision 1: Authoritative `resume/2` surface to document

**Decision**: Document `SpeckitOrchestrator.resume(feature_id, opts \\ [])` exactly
as defined in `lib/speckit_orchestrator.ex` (@doc/@spec ~lines 138–162):

- Default: restarts at the feature's **checkpointed phase** (`record.last_phase`).
- `:from` — overrides the start phase; **takes precedence** over the checkpoint's
  stored `last_phase`.
- `:prompt` — operator guidance note carried into the resumed phase as
  `resume_prompt`; omitted/`nil` runs the phase with no note.
- Passes remaining `run/1` opts through unchanged (`:features`, `:runner`, …).
- Error returns (each starts **no** run): `{:error, {:unknown_feature, id}}`,
  `{:error, :no_checkpoint}`, `{:error, :corrupt_checkpoint}`,
  `{:error, {:unknown_phase, term}}`.

**Rationale**: SC-002 requires every runbook example to run against the shipped
signature without modification. Pinning to the actual `@spec` is the only way to
guarantee parity; the contract file freezes it.

**Alternatives considered**: Paraphrase from the feature 003–005 spec docs —
rejected: those describe intermediate designs (`FeatureRunner.run/2` opts like
`start_phase:`/`resume_prompt:`), not the public facade an operator calls.

## Decision 2: Selection criteria — `resolve/1` vs `resume/2` (FR-005)

**Decision**: Document the choice as: use `resume/2` (targeted restart at the
checkpointed phase) as the default recovery path when a checkpoint exists and the
fix is local to one phase's inputs; fall back to `resolve/1` (full re-run from
`specify`) when the fix must regenerate upstream artifacts (e.g. a breakdown
`## Decisions` edit that `specify` must re-read), when there is no/corrupt
checkpoint, or when the operator wants a clean full rebuild.

**Rationale**: The runbook's existing escalation section (steps 1–5, lines
~252–283) already routes escalations through `resolve/1` + full re-run *because
resume did not exist when it was written*. The clarify-gate case specifically
needs `specify` to re-read the breakdown, so it stays a `resolve/1` case; the
analyze-halt / phase-input-fix case is the new `resume/2` sweet spot. Stating the
criterion prevents operators defaulting to the more expensive `resolve/1`.

**Alternatives considered**: Present `resume/2` as a blanket replacement —
rejected: `resolve/1`'s "regenerate from breakdown" semantics are still required
for the multi-round clarify loop, and a corrupt/absent checkpoint has no resume
path.

## Decision 3: Exact stale-reference set to purge (FR-007 / SC-003)

**Decision**: Repo-wide `.md` sweep target is the phrase-family "mid-pipeline
resume is v2 / v2 concern / (future) resume". Current on-disk matches:

- `docs/runbook.md:281` — "re-runs from the start (mid-pipeline resume is v2)" →
  rewrite to point at `resume/2` for the targeted case.
- `CLAUDE.md` observability paragraph (~lines 124–132) — does **not** literally say
  "v2 concern"; it omits `resume/2` entirely. FR-006 fix = add a shipped-`resume/2`
  sentence, not delete a phrase.

**Out of scope (confirmed)**: `lib/speckit_orchestrator.ex:121-122` `resolve/1`
docstring "mid-pipeline resume is v2" — source-code docstring, excluded by the
clarify-session ruling and FR-007. Leaving it does not violate SC-003 (search is
`.md`-only).

**Rationale**: The spec's input framing ("CLAUDE.md currently calls resume a 'v2
concern'") is approximate; the literal grep shows the only `.md` "v2" resume
phrase is in the runbook. Grounding the task in the actual match set prevents a
phantom edit and a missed one.

**Alternatives considered**: Trust the spec's prose location — rejected: would
have edited a non-existent CLAUDE.md phrase and possibly missed runbook:281.

## Decision 4: Verification method (all SCs, docs-only)

**Decision**:
- **SC-003**: `grep -rniE 'mid-pipeline resume is v2|v2 concern|resume.*(is|a) (future|v2)' --include='*.md' .` (excluding `specs/`) returns zero → pass.
- **SC-002**: diff each documented `resume(...)` call and error tuple against the
  `@spec` in `lib/speckit_orchestrator.ex` — names/arity/opts must match.
- **SC-001**: operator dry-read of the new runbook section performs the escalate →
  fix → resume loop using only its `iex` snippets.

**Rationale**: No code ships, so CI adds nothing; these three checks are the
feature's acceptance surface and map 1:1 to the Success Criteria.

**Alternatives considered**: A doctest/ExUnit guard on the runbook — rejected:
out of scope (adds code), and the grep/parity checks are sufficient and cheap.
