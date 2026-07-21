---

description: "Task list for feature 006-resume-docs"
---

# Tasks: Resume Docs & Operator Runbook

**Input**: Design documents from `/specs/006-resume-docs/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/resume-doc-surface.md, quickstart.md

**Tests**: Docs-only feature — no automated test suite. Verification is grep/read-based per quickstart.md (SC-001/SC-002/SC-003); no test tasks are generated.

**Organization**: Tasks are grouped by user story (US1 = P1, US2 = P2) per spec.md. No Setup phase — docs-only, no project init needed.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2)
- Exact file paths are included in every task

---

## Phase 1: Foundational (Blocking Prerequisites)

**Purpose**: Pin the exact facts both user stories must write against — the shipped signature and the current stale-reference baseline — so no downstream prose task guesses.

**⚠️ CRITICAL**: No documentation writing may begin until this phase is complete.

- [X] T001 Read `resume/2` `@doc`/`@spec` in `lib/speckit_orchestrator.ex` (lines ~138–162) and confirm it matches `specs/006-resume-docs/contracts/resume-doc-surface.md` verbatim (signature, option keys `:from`/`:prompt`, error tuples). This is the parity source every runbook example in Phase 2 must reproduce (SC-002).
- [X] T002 Run the baseline stale-reference sweep — `rtk grep -rniE 'mid-pipeline resume is v2|v2 concern|resume[^.]*(is|a)[^.]*(future|v2)' --include='*.md' . | grep -v '/specs/'` — from repo root and record the current match set (expected: `docs/runbook.md:281` only) to scope the Phase 4 sweep task. **Actual baseline exceeds expectation**: also matched `docs/harness-contract.md:98` and `docs/breakdown/005-resume-docs.md` (4 lines) — out of scope for Phase 2, flagged for the Phase 4 sweep (T008).

**Checkpoint**: Signature confirmed, baseline stale-reference set known — writing can begin.

---

## Phase 2: User Story 1 - Operator recovers via documented resume loop (Priority: P1) 🎯 MVP

**Goal**: `docs/runbook.md` documents the full escalate → fix → resume loop, the `:from`/`:prompt` options, and the `resolve/1` vs `resume/2` decision criteria, so an operator can run recovery from the runbook alone.

**Independent Test**: An operator unfamiliar with `resume/2` internals follows only `docs/runbook.md` and correctly executes the escalate → fix → resume loop with valid `iex` syntax (quickstart.md Check 3, SC-001).

### Implementation for User Story 1

- [X] T003 [US1] Add a `resume/2` recovery section to `docs/runbook.md` (near the existing `resolve/1` escalation section) documenting the escalate → fix → resume loop end-to-end: fix root cause on the feature branch, commit, then `SpeckitOrchestrator.resume("003")` restarting at the checkpointed (halted/escalated) phase by default. Use the exact canonical example from `contracts/resume-doc-surface.md` #1. (FR-001, FR-002, FR-003)
- [X] T004 [US1] Extend the `docs/runbook.md` resume section with the `:from` option (override start phase, restart-earlier case) and the `:prompt` option (operator guidance injected into the resumed phase), each with the canonical examples from `contracts/resume-doc-surface.md` #2–#4, plus prose on *when* to reach for `:from`. (FR-004)
- [X] T005 [US1] Add a `resolve/1` vs `resume/2` decision-criteria subsection to the `docs/runbook.md` resume section, cross-linked to the existing `resolve/1` escalation section (steps ~252–283): `resume/2` when a checkpoint exists and the fix is local to one phase's inputs; `resolve/1` when the fix must regenerate upstream artifacts, or checkpoint is missing/corrupt. Also list the four documented error outcomes (`{:error, {:unknown_feature, id}}`, `{:error, :no_checkpoint}`, `{:error, :corrupt_checkpoint}`, `{:error, {:unknown_phase, term}}`) as no-run failures per `data-model.md`. (FR-005)
- [X] T006 [US1] Fix the stale framing at `docs/runbook.md:281` ("re-runs from the start (mid-pipeline resume is v2)") to point at the new `resume/2` section for the targeted-restart case. (FR-007, partial — this file)

**Checkpoint**: `docs/runbook.md` resume section complete. Validate with quickstart.md Check 2 (SC-002 signature parity) and Check 3 (SC-001 dry-read).

---

## Phase 3: User Story 2 - Reader of CLAUDE.md gets an accurate picture (Priority: P2)

**Goal**: `CLAUDE.md`'s observability/operability paragraph names `resume/2` as shipped, with no deferred/"v2" framing.

**Independent Test**: Grep `CLAUDE.md` for future/deferred resume language returns zero matches, and the observability/operability paragraph names the shipped `resume/2` facade (quickstart.md Check 5).

### Implementation for User Story 2

- [X] T007 [P] [US2] Update the observability/operability paragraph in `CLAUDE.md` (~lines 124–132) to name `SpeckitOrchestrator.resume/2` as a shipped mid-pipeline recovery path alongside `resolve/1`, with no deferred/"v2 concern" framing. (FR-006)

**Checkpoint**: `CLAUDE.md` accurately reflects shipped `resume/2`. Validate with quickstart.md Check 5.

---

## Phase 4: Polish & Cross-Cutting Concerns

**Purpose**: Close out the repo-wide stale-reference requirement (FR-007 beyond the two files edited directly) and confirm the change stayed docs-only.

- [X] T008 Re-run the repo-wide stale-reference sweep — `rtk grep -rniE 'mid-pipeline resume is v2|v2 concern|resume[^.]*(is|a)[^.]*(future|v2)' --include='*.md' . | grep -v '/specs/'` — against the T002 baseline; fix any remaining match beyond `docs/runbook.md` and `CLAUDE.md` (current sweep found none, but this is the enforced zero-match gate). **Actual: sweep found 5 more matches** (`docs/harness-contract.md:98`, `docs/breakdown/005-resume-docs.md` x4) beyond the T002 baseline's two files — fixed by rewording to drop literal "v2"/"is v2" framing while preserving meaning. Re-swept: zero matches. (FR-007, SC-003 — quickstart.md Check 1)
- [X] T009 Run quickstart.md Check 4 — `rtk git diff --name-only main...006-resume-docs` — and confirm only `.md` files changed (`docs/runbook.md`, `CLAUDE.md`, `specs/006-resume-docs/**`), with no `lib/`, `test/`, `config/`, or `mix.exs` touched. **Note: no `006-resume-docs` branch was cut — work landed as uncommitted changes directly on `main`**, so verified via `git diff --name-only HEAD` + untracked instead: `CLAUDE.md`, `docs/breakdown/005-resume-docs.md`, `docs/harness-contract.md`, `docs/runbook.md`, `.specify/feature.json` (spec-kit pointer, not code), `specs/006-resume-docs/` (new). No `lib/`, `test/`, `config/`, `mix.exs`. PASS. (INV-3)
- [X] T010 Run the full `quickstart.md` validation end-to-end (Checks 1–5) and confirm all three Success Criteria (SC-001, SC-002, SC-003) pass. **Result: all PASS.** Check 1 zero matches (SC-003). Check 2: signature `def resume(feature_id, opts \\ [])` matches contract; all 4 canonical runbook examples present verbatim; zero invented-opt matches (SC-002). Check 3: dry-read of the runbook resume section confirms decision criteria, fix+commit step, `resume/2` invoke syntax, and `:from`-override guidance are all present (SC-001). Check 4: see T009. Check 5: `CLAUDE.md` names `SpeckitOrchestrator.resume/2` as shipped, no deferred framing.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Foundational (Phase 1)**: No dependencies — start immediately. BLOCKS both user stories.
- **User Story 1 (Phase 2)**: Depends on Foundational (T001, T002). No dependency on US2.
- **User Story 2 (Phase 3)**: Depends on Foundational (T001, T002). No dependency on US1.
- **Polish (Phase 4)**: Depends on both User Story 1 and User Story 2 being complete (sweeps and validates the combined result).

### Within Phase 2 (User Story 1)

T003 → T004 → T005 → T006, strictly sequential — all four edit the same `docs/runbook.md` resume section, each building on the prior task's prose.

### Parallel Opportunities

- T001 and T002 (Foundational) touch different sources (`lib/speckit_orchestrator.ex` read vs. repo-wide grep) and can run in parallel.
- Phase 2 (US1, `docs/runbook.md`) and Phase 3 (US2, `CLAUDE.md`) touch different files and can run in parallel once Foundational completes — T007 is marked `[P]` relative to the T003–T006 chain.
- T003–T006 are NOT parallelizable (same file, same section, sequential prose dependencies).

---

## Parallel Example: Post-Foundational

```bash
# After T001/T002 complete, run the two user stories concurrently:
Task: "Add resume/2 recovery section to docs/runbook.md (T003)"
Task: "Update CLAUDE.md observability paragraph to name shipped resume/2 (T007)"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Foundational (T001, T002)
2. Complete Phase 2: User Story 1 (T003–T006)
3. **STOP and VALIDATE**: quickstart.md Checks 2 and 3 (SC-002, SC-001)
4. This alone delivers the primary operational payoff — the documented resume loop

### Incremental Delivery

1. Foundational → signature + baseline confirmed
2. Add User Story 1 → validate independently (Checks 2, 3) → MVP delivered
3. Add User Story 2 → validate independently (Check 5)
4. Polish → repo-wide sweep + docs-only confirmation → validate all SCs (Checks 1, 4, full run)

---

## Notes

- Docs-only feature: no `[P]` opportunities within `docs/runbook.md` itself (T003–T006 are sequential edits to one section).
- `lib/speckit_orchestrator.ex` is read-only reference in T001 — never edited by this feature.
- Commit after each task or logical group (e.g., after T006 completes the full runbook section; after T007 completes the CLAUDE.md fix).
- Stop at each phase checkpoint to run the relevant quickstart.md check before moving on.
