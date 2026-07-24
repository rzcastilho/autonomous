# Tasks: Recovery State Reconciliation

**Input**: Design documents from `/specs/014-recovery-reconciliation/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: Included — plan.md's Testing section requires pure `Recovery.Reconcile`
unit coverage (>90%) and integration tests reusing 009's fixture conventions;
quickstart.md names the exact test files.

**Organization**: Tasks are grouped by user story (spec.md priorities). Phase 3
(US1) and Phase 4 (US2) share the same new modules (`Recovery.Evidence`,
`Recovery.Reconcile`, `Recovery`) because the decision table is one pure
function reconciling every status in one pass — the plan does not split it
module-by-module per story. Each story phase instead adds the clauses/fixtures
that story requires and is independently verifiable via its own test file.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)
- Paths are repo-root relative, matching the existing `lib/speckit_orchestrator/`
  / `test/speckit_orchestrator/` layout (plan.md "Project Structure")

## Path Conventions

Single Elixir project (Option 1). Source: `lib/speckit_orchestrator/`. Tests:
`test/speckit_orchestrator/`. No new project structure — this feature adds a
`recovery/` submodule folder to the existing tree.

---

## Phase 1: Setup

**Purpose**: Confirm the workspace builds before any new module lands.

- [X] T001 Run `mise exec -- mix deps.get && mise exec -- mix compile` from repo
      root and confirm a clean compile (warnings-as-errors) before starting —
      no new dependency is introduced (FR-016), this only verifies baseline.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `Evidence` struct and the collector edge module that every
story's reconciliation depends on. No user story can be verified without these.

**⚠️ CRITICAL**: Phase 3+ cannot start until this phase is complete.

- [X] T002 [P] Define `SpeckitOrchestrator.Recovery.Evidence` struct in
      `lib/speckit_orchestrator/recovery/evidence.ex`: fields
      `feature_id :: String.t()`, `branch_committed? :: boolean()`,
      `last_boundary_phase :: Pipeline.phase() | nil`,
      `pr_record? :: boolean()`, `pr_remote? :: boolean() | :unknown`,
      `checkpoint :: map() | nil`, `final_marker? :: boolean()`, per
      data-model.md "Entity: `Recovery.Evidence`"; add `@type t`.
- [X] T003 [US-shared] Implement `Recovery.Evidence.collect/3` in
      `lib/speckit_orchestrator/recovery/evidence.ex` per
      `contracts/evidence.md` `collect/3`: `(feature :: Feature.t(), layout ::
      Layout.t() | nil, opts :: keyword()) :: Evidence.t()`, reading
      `branch_committed?` and `last_boundary_phase` via an injected `:git` seam
      (default real `Worktree`/`git`), `pr_record?` via `Describe.read_pr/2`,
      `checkpoint` via `Checkpoint.read/2`, `final_marker?` from the durable
      `07-converge.md` transcript (`## CONVERGE: READY`), and `pr_remote?` via
      an injected `:remote` seam (default local-only, returns `:unknown`,
      never touches network) attempted only when `pr_record? == false`. Every
      source read independently; any absent/corrupt source degrades to its
      unknown value, never raises (FR-011).
- [X] T004 [US-shared] Implement the boundary-commit git-log parse in
      `lib/speckit_orchestrator/recovery/evidence.ex` (or a small private
      helper module under `recovery/`): match only subjects
      `"speckit: <id> checkpoint after <phase>"` (the `:done`-squash subject
      `"speckit: feature <id> pipeline artifacts (...)"` and other terminal
      commits MUST NOT be parsed as a boundary — evidence.md "Boundary-commit
      parse"); take the newest match's `<phase>` via `Pipeline.parse/1`;
      unparseable/absent → `nil`. Wire this as the default `:git` seam's
      `last_boundary_phase` implementation, reusing `Worktree`'s branch-naming
      convention (`feature/NNN-slug`) for the `git log` target.
- [X] T005 [P] [US-shared] `test/speckit_orchestrator/recovery/evidence_test.exs`:
      unit tests for `collect/3` over tmp-dir fixtures — present
      `pr.json`/`checkpoint.json`/`07-converge.md` (all fields populate);
      absent each individually (degrades to unknown value, no raise); corrupt
      (truncated) `pr.json` (→ `pr_record?: false`, falls back to
      git/transcript evidence per FR-011); fake `:git` seam returning a
      boundary-commit log (`last_boundary_phase` parses correctly, ignoring
      non-boundary subjects); `:remote` seam untouched when `pr_record?` is
      `true`, invoked and its failure mapped to `pr_remote?: :unknown` when
      `pr_record?` is `false` and the seam errors/times out (offline-first,
      FR-018/SC-009 — quickstart.md Scenario 5).

**Checkpoint**: `Recovery.Evidence.collect/3` is complete and tested — the
pure decision table (Phase 3) can now consume real `%Evidence{}` values.

---

## Phase 3: User Story 1 - Reconcile a stale "running" feature that actually finished (Priority: P1) 🎯 MVP

**Goal**: A feature recorded `running` whose durable evidence proves it
finished (PR-workflow: `pr.json` + committed branch; non-PR: converge success
marker + committed branch) reconciles to `done`, unblocking its dependents,
with zero phase re-run and spend preserved exactly once.

**Independent Test**: Reproduce the `quickpoll` first-wave state (manifest
`001: running`, `002: pending`; `001`'s `pr.json` + `07-converge.md` READY +
branch with boundary commit `after converge`). Run recovery. Verify `001`
reports/persists `done`, `002` reports as next runnable, no `001` phase
re-runs (`test/speckit_orchestrator/recovery_quickpoll_test.exs`).

### Tests for User Story 1

- [X] T006 [P] [US1] `test/speckit_orchestrator/recovery/reconcile_test.exs`
      (US1 slice): unit tests for `Recovery.Reconcile.status/3` clause 4
      (contracts/reconcile.md precedence #4) — `recorded ∈ {:running,
      :pending}` and `done_signal?(evidence, shape)` → `:done`, for both
      `{:breakdown, slug}` (PR-workflow: `pr_record? and branch_committed?`)
      and `:ad_hoc` non-PR-workflow (`final_marker? and branch_committed?`)
      run shapes; and `done_signal?/2` itself (PR-workflow ignores
      `final_marker?`, non-PR ignores `pr_record?`, `pr_remote?: :unknown`
      never flips a local `true` to `false`).
- [X] T007 [US1] `test/speckit_orchestrator/recovery_quickpoll_test.exs`: SC-001
      regression reproducing the exact `quickpoll` defect per quickstart.md
      Scenario 1 — manifest `001: running`/`002: pending` fixture, `001`'s
      durable dir with `pr.json` + `07-converge.md` READY, git branch
      `feature/001-…` with boundary commit `after converge`; run
      `Recovery.reconcile_run/2`; assert `001` reconciles/persists `done`,
      `002` appears in `next_runnable`, zero `001` phases re-run, `001`'s
      committed spend counted exactly once in `report.spend`.

### Implementation for User Story 1

- [X] T008 [US1] Implement `SpeckitOrchestrator.Recovery.Reconcile.status/3`
      skeleton in `lib/speckit_orchestrator/recovery/reconcile.ex` per
      `contracts/reconcile.md` `status/3`: `@spec status(recorded ::
      Feature.status(), Evidence.t(), run_shape()) :: :done | {:resume,
      Pipeline.phase()} | :pending | :escalated | :halted | :failed |
      {:conflict, atom()}`, with `@type run_shape :: {:breakdown, String.t()}
      | :ad_hoc`; implement clause 4 only for this story (non-terminal
      done-signal → `:done`) plus a `done_signal?/2` and `phase_after/1`
      helper per the contract (later stories add the remaining clauses to the
      same module/function).
- [X] T009 [US1] Implement `SpeckitOrchestrator.Recovery.reconcile_run/2` in
      `lib/speckit_orchestrator/recovery.ex` per `contracts/recovery-report.md`
      steps 1–5: `@spec reconcile_run(record :: map(), opts :: keyword()) ::
      {:ok, %{statuses: map(), report: Recovery.Report.t(), resume_phases:
      map()}} | {:error, term()}` — rebuild `Layout` via
      `RunManifest.rebuild_layout/2`, derive `run_shape` from scope, collect
      `Evidence` per feature (`Evidence.collect/3`), run `Reconcile.status/3`,
      fold into a `statuses` map and a `resume_phases` map, immediately
      rewrite the manifest via `RunManifest.write/1` preserving
      `features`/`context`/`spend`/`segment`/`scope` verbatim and refreshing
      `updated_at` (FR-009), and build the reconciled report (`next_runnable`
      via `Release.next_wave`/`releasable?` over corrected statuses). Missing/
      corrupt manifest propagates as `{:error, :no_manifest | :corrupt}`; a
      single corrupt per-feature artifact never errors (absorbed by the
      collector).
- [X] T010 [US1] Define `SpeckitOrchestrator.Recovery.Report` struct/type in
      `lib/speckit_orchestrator/recovery/report.ex` (or inline in
      `recovery.ex` if simpler) matching data-model.md "Entity: Reconciled run
      report": `features :: [%{id, slug, recorded, reconciled, resume_phase,
      corrected?}]`, `conflicts :: [%{id, reason}]`, `next_runnable ::
      [feature_id]`, `spend :: number`, `run_shape :: {:breakdown, String.t()}
      | :ad_hoc`. `corrected?` is `recorded != reconciled`.
- [X] T011 [US1] Wire `SpeckitOrchestrator.resume_run/2`
      (`lib/speckit_orchestrator.ex:424`) to call `Recovery.reconcile_run/2` in
      place of the raw `RunManifest.reconstruct/1` call at line 427, per
      `contracts/recovery-report.md` "Integration with `resume_run/2`": seed
      the Coordinator's `:statuses` option with the reconciled statuses
      (`done`/held/conflict features never re-released), keep
      `Ledger.restore(Ledger, record["spend"])` unchanged (FR-013), and have
      `dispatch_resume` use `resume_phases` for `{:resume, phase}` features
      while leaving `:done`/held/conflict features untouched (FR-006, no
      re-run for this story's `:done` path).
- [X] T012 [US1] Wire `SpeckitOrchestrator.resumable_run/0`
      (`lib/speckit_orchestrator.ex:373`) to return the reconciled report from
      `Recovery.reconcile_run/2` for a read-only preview (FR-015, SC-008) —
      no Coordinator seeded, no work started; preserves the existing `:none`
      classification and `{:error, :no_manifest | :corrupt_manifest}` returns.

**Checkpoint**: User Story 1 is independently functional — `mise exec -- mix
test test/speckit_orchestrator/recovery_quickpoll_test.exs` passes; the exact
reported `quickpoll` defect (SC-001) is fixed.

---

## Phase 4: User Story 2 - Reconcile a "running" feature that stopped partway (Priority: P1)

**Goal**: A `running` feature with only intermediate committed progress (no
terminal/PR evidence) reconciles to resumable at the phase **after** its
latest committed git boundary, so continuation re-runs only remaining phases.

**Independent Test**: Feature with boundary commits through `plan`, no
`pr.json`, checkpoint `last_phase: plan / in_progress`. Run recovery. Verify
reconciled `{:resume, :tasks}` and continuation runs only `tasks → … →
converge` (quickstart.md Scenario 2; `test/speckit_orchestrator/recovery/reconcile_test.exs`).

### Tests for User Story 2

- [X] T013 [P] [US2] `test/speckit_orchestrator/recovery/reconcile_test.exs`
      (US2 slice): unit tests for clause 5 (contracts/reconcile.md
      precedence #5) — `recorded == :running`, not a done-signal, branch has
      ≥1 boundary commit → `{:resume, phase_after(evidence.last_boundary_phase)}`;
      table-test `phase_after/1` across all `Pipeline.phases()` (e.g. `:plan`
      → `:tasks`, `:analyze` → `:implement`); and clause 6 — `recorded ==
      :pending`, no branch and no artifacts → `:pending` (FR-008, US3 overlap
      covered fully in Phase 5).
- [X] T014 [US2] Integration test in `test/speckit_orchestrator/recovery_test.exs`
      reproducing quickstart.md Scenario 2: manifest `running`, boundary
      commits through `plan` only, no `pr.json`, checkpoint `last_phase: plan`
      / `status: in_progress`. Run `Recovery.reconcile_run/2`. Assert
      `resume_phases["<id>"] == :tasks`, persisted manifest status stays
      `"running"`, and (via `resume_run/2`) continuation dispatches at
      `:tasks` without regenerating `specify`/`clarify`/`plan`.

### Implementation for User Story 2

- [X] T015 [US2] Extend `SpeckitOrchestrator.Recovery.Reconcile.status/3` in
      `lib/speckit_orchestrator/recovery/reconcile.ex` with clause 5 (mid-run
      resume) and clause 6 (never-started pending) per `contracts/reconcile.md`
      precedence order — clause 5 before clause 6, both after the clause-4
      done-signal check from Phase 3; implement `phase_after/1` per the
      contract (`Pipeline` phase following the latest committed boundary;
      terminal `:converge` boundary is handled by clause 4, not here — `nil`
      boundary with `recorded == :running` falls through to clause 6/7, not a
      resume).
- [X] T016 [US2] Confirm `dispatch_resume` (the private helper `resume_run/2`
      already calls per `lib/speckit_orchestrator.ex`'s existing resume
      machinery) accepts a `resume_phases`-supplied start phase for a
      `{:resume, phase}` feature via the existing checkpoint-driven resume
      path (007's phase-boundary resume) — add the plumbing in
      `lib/speckit_orchestrator.ex` if the current `dispatch_resume` only
      reads the checkpoint's own `last_phase` and needs the reconciled
      `resume_phases` override threaded through (FR-004: never resume within
      a phase, always at a full phase boundary).

**Checkpoint**: User Stories 1 AND 2 both pass independently — the two halves
of the `running` classification (finished vs. genuinely incomplete) are both
correct.

---

## Phase 5: User Story 3 - Reconcile pending and terminal states across the whole run (Priority: P2)

**Goal**: Every remaining status classification is correct: never-started
`pending` stays `pending`; `escalated`/`halted` stay held; `failed` stays
`failed`; `done` with corroborating evidence stays `done`; `done` WITHOUT
evidence and other self-contradictory evidence surface as
`{:conflict, reason}`, held gate-like via the existing `:blocked` status.

**Independent Test**: Manifest exercising every status
(`running`/`pending`/`escalated`/`halted`/`failed`/`done`) with matching or
conflicting evidence; verify each reconciles per the rule for its state
(`test/speckit_orchestrator/recovery/reconcile_test.exs` full run,
quickstart.md Scenario 3).

### Tests for User Story 3

- [X] T017 [P] [US3] `test/speckit_orchestrator/recovery/reconcile_test.exs`
      (US3 slice): unit tests for the remaining clauses — clause 1 (`recorded
      ∈ {:escalated, :halted}` → unchanged regardless of evidence, gate
      safety invariant: no input combination advances a gate); clause 2
      (`recorded == :failed` → `:failed`); clause 3 both branches
      (`recorded == :done` with branch/PR corroboration → `:done`; `recorded
      == :done` with no branch/no PR → `{:conflict, :done_without_artifacts}`);
      clause 7 contradiction (`pr_record? and not branch_committed?` →
      `{:conflict, :pr_without_branch}`); clause 6 pending-never-started
      confirmation. Include a purity check (identical inputs → identical
      output, no I/O) and a property-style sweep asserting no
      `:escalated`/`:halted` input reaches any output other than itself.
- [X] T018 [US3] Integration test in
      `test/speckit_orchestrator/recovery_test.exs` (or extend
      `recovery_quickpoll_test.exs`'s sibling fixture): one manifest with six
      features, each exercising one status per data-model.md's state
      transitions table (including the `done_without_artifacts` conflict and
      an `escalated` feature); run `Recovery.reconcile_run/2`; assert the
      persisted manifest matches per-feature expectations, the conflict
      feature persists as `"blocked"` in the rewritten manifest, its
      dependents are absent from `next_runnable`, and independent
      non-dependent features still appear in `next_runnable` (FR-014 — one
      conflict never freezes the run).

### Implementation for User Story 3

- [X] T019 [US3] Complete `SpeckitOrchestrator.Recovery.Reconcile.status/3` in
      `lib/speckit_orchestrator/recovery/reconcile.ex` with the remaining
      clauses in contract precedence order: 1 (gate passthrough), 2 (failed
      passthrough), 3 (done corroboration / `:done_without_artifacts`
      conflict), 7 (`:pr_without_branch` conflict and the residual-ambiguity
      catch-all `{:conflict, reason}` — never a silent guess, per the
      "No fabrication" invariant).
- [X] T020 [US3] In `Recovery.reconcile_run/2`
      (`lib/speckit_orchestrator/recovery.ex`), map `{:conflict, reason}`
      reconciled values to the persisted manifest status `"blocked"` and
      populate the report's `conflicts` list (`%{id, reason}`) per
      data-model.md's mapping table and `contracts/recovery-report.md`
      "Conflict release semantics" — no change needed to `Release`
      (`:blocked` already excluded from `releasable?`), confirm this holds by
      T018 rather than adding new release logic.
- [X] T021 [US3] Update `SpeckitOrchestrator.Report`
      (`lib/speckit_orchestrator/report.ex`) or add a
      `Recovery.Report.format/1` rendering function producing the reconciled
      table shown in `contracts/recovery-report.md` "Reconciled report"
      (`Feature | Recorded | Reconciled | Note` columns, `Spend:` and `Next
      runnable:` footer, `CONFLICT` rows carrying their reason) — feeds
      `SpeckitOrchestrator.print_status`-style operator output for
      `resumable_run/0`'s reconciled preview.

**Checkpoint**: All six status classifications reconcile correctly; the whole-
run picture is trustworthy end-to-end (SC-004 fully covered).

---

## Phase 6: User Story 4 - Recovery works for both breakdown waves and ad-hoc runs (Priority: P2)

**Goal**: The same reconciliation logic produces correct results for both run
shapes carried in the manifest's `scope` — `{:breakdown, slug}` and `:ad_hoc`.

**Independent Test**: Ad-hoc run whose single feature finished before a crash
→ reported `done`/complete, no re-run; breakdown wave → a reconciled `done`
releases dependents on continuation (quickstart.md Scenario 4).

### Tests for User Story 4

- [X] T022 [P] [US4] `test/speckit_orchestrator/recovery_test.exs`: ad-hoc-run
      scenario — single-feature manifest with `scope: "ad-hoc"`, `running`
      recorded, non-PR-workflow done-signal (`final_marker?` +
      `branch_committed?`, no `pr.json`); run `Recovery.reconcile_run/2`;
      assert `run_shape == :ad_hoc` is derived correctly from
      `RunManifest.rebuild_layout/2`'s scope, the feature reconciles `done`,
      and the report reflects a complete run.
- [X] T023 [P] [US4] `test/speckit_orchestrator/recovery_test.exs`: breakdown-
      wave scenario — manifest `scope: %{"breakdown" => slug}`, a finished
      upstream feature (`done`-signal evidence) and a `pending` dependent with
      that feature as a prereq; assert `run_shape == {:breakdown, slug}`,
      the upstream reconciles `done`, and the dependent appears in
      `next_runnable` after reconciliation.

### Implementation for User Story 4

- [X] T024 [US4] Confirm/adjust `run_shape` derivation in
      `Recovery.reconcile_run/2` (`lib/speckit_orchestrator/recovery.ex`) so
      `RunManifest.rebuild_layout/2`'s scope (`scope_of/1`: `{:breakdown,
      slug}` vs `:ad_hoc`) maps 1:1 onto `Reconcile`'s `run_shape()` type used
      by `done_signal?/2` — no new scope logic; this task is the explicit
      cross-check that the existing `RunManifest`/`Layout` scope plumbing
      (012) already threads through correctly for both shapes, per T022/T023.

**Checkpoint**: Both run shapes reconcile correctly — the full spec (US1–US4)
is functionally complete.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Corrupt-tolerance/offline resilience proofs spanning all stories,
coverage verification, and full-suite regression.

- [X] T025 [P] `test/speckit_orchestrator/recovery/evidence_test.exs`
      (extend): quickstart.md Scenario 5 corrupt-tolerance case — truncate
      `pr.json` for an otherwise-finished feature; assert `collect/3` falls
      back to git/transcript evidence and `Reconcile.status/3` still reaches a
      correct `:done` or `{:conflict, _}` (never crashes, per SC-006).
- [X] T026 [P] `test/speckit_orchestrator/recovery_test.exs` (extend):
      quickstart.md Scenario 5 offline case — run `Recovery.reconcile_run/2`
      with the default local-only `:remote` seam (network never touched);
      assert every feature reaches its correct reconciled status from local
      state alone, `pr_remote?` stays `:unknown` throughout, and no
      `{:error, _}` is attributable to the remote (SC-009).
- [X] T027 Manifest-missing/corrupt edge case in
      `test/speckit_orchestrator/recovery_test.exs`: `Recovery.reconcile_run/2`
      on a missing manifest returns `{:error, :no_manifest}`; on a corrupt
      manifest returns `{:error, :corrupt}` — fail-loud per Principle II,
      never fabricates a run (spec "Edge Cases" — manifest missing/corrupt).
- [X] T028 Run `mise exec -- mix test --cover` and confirm `Recovery.Reconcile`
      and `Recovery.Evidence` hold >90% coverage per plan.md's Testing
      section; add any missing clause/branch tests surfaced by the report.
- [X] T029 Run `mise exec -- mix test` (full suite, `warnings_as_errors` on)
      and confirm green, including the pre-existing `resume_run_test.exs`,
      `resume_crash_test.exs`, `resolve_test.exs`, and `coordinator_test.exs`
      suites are unaffected by the `resume_run/2`/`resumable_run/0` call-site
      changes (T011/T012).
- [X] T030 Execute `quickstart.md`'s full validation block end-to-end (all
      five scenarios + `mix test --cover` + `mix test`) as the final
      spec-to-implementation confirmation.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies.
- **Foundational (Phase 2)**: Depends on Setup. BLOCKS Phases 3–7 — every
  story reconciles against `%Evidence{}`, which only Phase 2 produces.
- **User Story 1 (Phase 3)**: Depends on Phase 2. Delivers the MVP fix
  (SC-001) and stands up `Recovery.Reconcile`/`Recovery`/`Recovery.Report` —
  later stories extend the same `status/3` function rather than creating
  parallel modules.
- **User Story 2 (Phase 4)**: Depends on Phase 3 (extends the same
  `Reconcile.status/3` clauses 5–6 into the function Phase 3 created).
- **User Story 3 (Phase 5)**: Depends on Phase 4 (completes the same
  function's remaining clauses 1–3, 7).
- **User Story 4 (Phase 6)**: Depends on Phase 5 conceptually (needs the full
  decision table to validate both shapes meaningfully), but its own new work
  (T024) is a thin cross-check — could run directly after Phase 3 if desired,
  since `run_shape` threading doesn't depend on which clauses exist yet.
- **Polish (Phase 7)**: Depends on all of Phases 3–6 being complete.

**Note on shared-module structure**: Unlike a typical feature where each user
story owns disjoint files, US1–US3 here incrementally complete one pure
function (`Recovery.Reconcile.status/3`) because the contract defines it as a
single 7-clause precedence table (contracts/reconcile.md) — splitting it
across stories would violate the "one pure decision surface" design (Decision
1, research.md). Each story phase is still independently *testable* (each has
its own test task exercising only its clauses) even though the implementation
tasks touch the same file sequentially.

### Within Each User Story

- Tests written first (T006/T013/T017 before T008/T015/T019 respectively),
  expected to fail until the corresponding implementation task lands.
- `Recovery.Reconcile` clauses before `Recovery.reconcile_run/2` wiring before
  `resume_run/2`/`resumable_run/0` call-site changes.
- Story complete before moving to the next priority.

### Parallel Opportunities

- T002 (Evidence struct) has no dependents inside Phase 2 besides T003/T004
  which need the struct shape — T002 must land first, but T005 (evidence
  tests) can be written in parallel with T003/T004 (drafted against the
  contract, run once T003/T004 land).
- T006 and T013 and T017 (the three `reconcile_test.exs` slices) touch the
  same file — do NOT mark them [P] against each other in execution even
  though they're tagged [P] individually for parallel drafting; land them
  sequentially to avoid merge conflicts in one growing test file, or draft
  in parallel branches and merge.
- T022/T023 (US4 tests) are independent scenarios in the same file — draftable
  in parallel, sequential merge.
- T025/T026 (Phase 7 corrupt/offline tests) touch different files — true [P].

---

## Parallel Example: Phase 2 (Foundational)

```bash
# T002 first (struct shape), then:
Task: "Implement Recovery.Evidence.collect/3 in lib/speckit_orchestrator/recovery/evidence.ex"
Task: "Implement boundary-commit git-log parse in lib/speckit_orchestrator/recovery/evidence.ex"
# T005 drafted in parallel against contracts/evidence.md, run once T003/T004 land
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational (`Recovery.Evidence` — CRITICAL, blocks
   everything).
3. Complete Phase 3: User Story 1 — this alone fixes the reported `quickpoll`
   defect (SC-001) and stands up the full `Recovery` orchestration path.
4. **STOP and VALIDATE**: `mise exec -- mix test
   test/speckit_orchestrator/recovery_quickpoll_test.exs` green.

### Incremental Delivery

1. Setup + Foundational → evidence collection ready.
2. US1 → the exact reported defect fixed → validate → this is the MVP.
3. US2 → mid-run resume correctness → validate.
4. US3 → whole-run status correctness (pending/gates/conflicts) → validate.
5. US4 → both run shapes confirmed → validate.
6. Polish → corrupt/offline resilience proofs, coverage, full suite.

---

## Notes

- [P] tasks target different files or are independently draftable against a
  contract, even when a later merge into a shared file (e.g.
  `reconcile_test.exs`) is sequential.
- Verify each story's tests fail before implementing its clauses.
- Commit after each task or logical group.
- Stop at any checkpoint to validate a story independently.
- No new dependency, no datastore, no new process — every task edits or adds
  files inside `lib/speckit_orchestrator/` and `test/speckit_orchestrator/`
  only (FR-016, plan.md Constitution Check).
