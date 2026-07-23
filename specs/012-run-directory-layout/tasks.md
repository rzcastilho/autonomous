---

description: "Task list for feature 012-run-directory-layout"
---

# Tasks: Standardized Run Directory Layout

**Input**: Design documents from `/specs/012-run-directory-layout/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/repo-identity.md, contracts/layout.md, quickstart.md

**Tests**: Included — the plan's Constitution Check and quickstart.md require hermetic pure-unit coverage (>90% on `RepoIdentity`/`Layout`) plus tagged `:integration` tests for the git-origin read and filesystem create/write paths.

**Organization**: Tasks are grouped by user story (spec.md) to enable independent implementation and testing of each story. All Elixir commands run through `mise exec --` per CLAUDE.md.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1/US2/US3)
- File paths are exact, relative to the repository root

---

## Phase 1: Setup

- [X] T001 Confirm no new dependency is needed (`:crypto` for the identity hash is Elixir stdlib) — run `mise exec -- mix deps.get && mise exec -- mix compile` as a clean baseline before starting (warnings-as-errors must already pass)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The two new pure-core modules every user story is built on (FR-011's single resolution surface). No user story work can begin until this phase is complete.

- [X] T002 [P] Implement `SpeckitOrchestrator.RepoIdentity` — pure `canonicalize/1` (strip scheme/`git@`/`.git`/trailing slash, normalize SCP-style `host:owner/repo`, lower-case host only) and `segment/1` (`"#{name}-#{shorthash}"`, first 6 hex of `:crypto.hash(:sha256, canonical)`); IO boundary `resolve/1` (`git -C <repo> remote get-url origin`, mirroring `TargetPack.check_remote/3`) returning `{:error, :no_origin}` on a missing/unusable origin — in `lib/speckit_orchestrator/repo_identity.ex` per `contracts/repo-identity.md`
- [X] T003 [P] Add `Config.autonomous_root/0` (default `Path.expand("~/.autonomous")`, overridable via `Application.put_env/3`) and `Config.specs_root/0` (default `"specs/autonomous"`, in-repo) in `lib/speckit_orchestrator/config.ex` per research.md Decision 6
- [X] T004 Implement `SpeckitOrchestrator.Layout` — `%Layout{worktree_root, transcript_root, breakdown_root, ad_hoc_root}` struct; `build/3` (`repo, segment, scope` where `scope :: {:breakdown, slug} | :ad_hoc`) resolving all four roots as pure path joins per the data-model.md Directory Grammar, returning `{:error, {:reserved_slug, "ad-hoc"}}` for `{:breakdown, "ad-hoc"}` and `{:error, {:home_unavailable, reason}}` when `autonomous_root` can't be resolved; `ensure/1` (`File.mkdir_p` every resolved root, fail loud as `{:error, {:mkdir, path, reason}}`, never deletes/overwrites a sibling run's directory); and `in_repo_rel/1` returning the **repo-relative** in-repo suffix (`"specs/autonomous/breakdown/<slug>"` | `"specs/autonomous/ad-hoc"`) for worktree-relative phase resolution — `breakdown_root`/`ad_hoc_root` are base-repo absolute for load/inspection only (resolves I1) — in `lib/speckit_orchestrator/layout.ex` per `contracts/layout.md` (depends on T002, T003)
- [X] T005 [P] Unit tests for `RepoIdentity`: SSH/HTTPS/SCP equivalence, different-owner/host divergence, `segment/1` determinism, `resolve/1` `{:error, :no_origin}` on a repo with no origin — in `test/speckit_orchestrator/repo_identity_test.exs`; keep `canonicalize/1`/`segment/1` assertions hermetic (no IO) and tag the `resolve/1` git-origin assertions `:integration` (depends on T002)
- [X] T006 [P] Unit tests for `Layout`: four-root resolution for `{:breakdown, slug}` and `:ad_hoc` scopes, the reserved `"ad-hoc"` slug rejection, and `ensure/1`'s mkdir/fail-loud behavior against an unwritable root — in `test/speckit_orchestrator/layout_test.exs` (depends on T004)

**Checkpoint**: `RepoIdentity` + `Layout` compile and pass their own unit suite — every user story below builds on this single resolution surface.

---

## Phase 3: User Story 1 - Isolate working data per target repository (Priority: P1) 🎯 MVP

**Goal**: Worktrees and durable transcripts resolve under `~/.autonomous/{worktrees,transcripts}/<repo-name>-<shorthash>` — two repositories never share a run subpath, and a repository with no `origin` remote is refused before any work begins.

**Independent Test**: Configure two target repositories with different remotes, run one feature in each, and confirm their worktrees and transcripts resolve to two different roots with no shared subpath; confirm a repo with no `origin` is refused at preflight.

### Implementation for User Story 1

- [X] T007 [US1] At `SpeckitOrchestrator.run/1` and `run_spec/1` preflight, call `RepoIdentity.resolve/1` then `Layout.build/3` + `Layout.ensure/1` before releasing any wave; on `{:error, :no_origin}` return `{:error, {:preflight, [{:no_origin, repo}]}}` without starting any work (FR-002, SC-004) — in `lib/speckit_orchestrator.ex`
- [X] T008 [US1] Thread the resolved `%Layout{}` through `Coordinator` state (alongside the existing `:context`) so every runner spawned for the run carries it — in `lib/speckit_orchestrator/coordinator.ex` (`start_link/1` opts, `defstruct`, `spawn_feature/2`) (depends on T007)
- [X] T009 [US1] Add a `:layout` opt to `FeatureRunner.run/2` (alongside `:worktree`/`:ledger`/`:notify`/`:run_context`) and pass it through to the writers touched in US2/US3 — in `lib/speckit_orchestrator/feature_runner.ex` (depends on T008)
- [X] T010 [US1] Resolve `Worktree.create/2`/`locate/2`'s worktree root from `layout.worktree_root` instead of `Config.worktree_root/0` — in `lib/speckit_orchestrator/worktree.ex`, threaded from every runner/executor in `lib/speckit_orchestrator.ex` (default, resume, stacked-PR) (depends on T007)
- [X] T011 [P] [US1] Integration test: two throwaway repos with different `origin` remotes, run through `RepoIdentity.resolve/1` + `Layout.build/3`, produce worktree/transcript roots sharing no common subpath (SC-001) — in `test/speckit_orchestrator/run_directory_layout_test.exs` (tag `:integration`) (depends on T004, T010)
- [X] T012 [P] [US1] Integration test: `SpeckitOrchestrator.run/1` against a repo with no `origin` remote returns `{:error, {:preflight, problems}}` with `{:no_origin, _}` in `problems`, and creates no worktree/transcript directory (SC-004) — in `test/speckit_orchestrator/run_directory_layout_test.exs` (tag `:integration`) (depends on T007)

**Checkpoint**: User Story 1 is fully functional and testable independently — repository isolation holds for worktrees and transcripts, no-origin repos are refused loud.

---

## Phase 4: User Story 2 - Organize runs by breakdown package (Priority: P2)

**Goal**: Breakdown packages are identified by slug (the package directory name under `specs/autonomous/breakdown/`); their feature files and durable transcripts group under that slug, so two packages with overlapping feature ids never collide.

**Independent Test**: Place two breakdown packages with overlapping feature ids under distinct slugs, run one feature from each, and confirm their feature files and transcripts resolve under separate slug segments with no collision.

### Implementation for User Story 2

- [X] T013 [US2] Extend `SpeckitOrchestrator.run/1` to select one breakdown package by slug (an explicit `:slug`/`:package` opt or the sole package found under `layout.breakdown_root`'s parent), build `Layout` with scope `{:breakdown, slug}`, and load `Backlog.load!/1` over `layout.breakdown_root` instead of `Path.join(Config.repo(), Config.breakdown_dir())` — in `lib/speckit_orchestrator.ex` (`load_backlog/0`) (depends on T007)
- [X] T014 [P] [US2] Resolve `PhaseRequest.breakdown_ref/2`'s path via `Layout.in_repo_rel/1` + `Path.basename(feature.path)` — a **worktree-relative** path (phases run with `cwd = <worktree>`), NOT the base-repo-absolute `Layout.breakdown_root` (resolves I1); thread the run's `%Layout{}` into `PhaseRequest.build/3` — in `lib/speckit_orchestrator/phase_request.ex` (depends on T004, T013)
- [X] T015 [P] [US2] Write durable transcripts under `layout.transcript_root` (scope-keyed: `<segment>/<slug>/<feature_id>/NN-<phase>.md`) instead of `Config.transcript_root()` — in `lib/speckit_orchestrator/transcripts.ex` (`write/4`, `maybe_write_durable/4`), threaded through `FeatureRunner`'s `:layout` opt (depends on T009)
- [X] T016 [P] [US2] Resolve `Checkpoint.write/1`/`read/1`/`delete/1` per-feature paths from `layout.transcript_root` (scope-keyed `<segment>/<scope>/<feature_id>/checkpoint.json`) instead of `Config.transcript_root()`; write side threads the run's `%Layout{}` via `FeatureRunner`, read side (resume) rebuilds a `%Layout{}` from the manifest's recorded `segment`+`scope` (see T033) — in `lib/speckit_orchestrator/checkpoint.ex` (depends on T009)
- [X] T017 [P] [US2] Keep `RunManifest` a **single global slot**: `write/1`/`read/0`/`clear/0` resolve a **fixed** `<autonomous_root>/transcripts/run.json` (NOT scope-partitioned — its read callers have no `%Layout{}`), and `write/1` additionally records `segment` and `scope` in the record so a resume can rebuild a `%Layout{}` to locate scope-partitioned checkpoints (resolves I2) — in `lib/speckit_orchestrator/run_manifest.ex`, `segment`/`scope` supplied through `Coordinator`'s existing `:manifest`/`:context` seam (depends on T008)
- [X] T018 [P] [US2] Resolve `Describe.write_pr/2`/`read_pr/1` paths from `layout.transcript_root` instead of `Config.transcript_root()` — in `lib/speckit_orchestrator/describe.ex`, threaded through `FeatureRunner` and the stacked-PR publisher path (depends on T009)
- [X] T019 [US2] Update `PipelineDagLive`: list breakdown packages under `specs/autonomous/breakdown/<slug>` (per-package `Backlog.load!/1`) instead of the flat `docs/breakdown`; resolve identity for `Config.repo/0` at mount and read the global `run.json`; overlay last-known statuses (`manifest_record/0`, `checkpoints_for/1`) **only when** `manifest["segment"]` matches the viewed repo's segment (a stale cross-repo manifest must not paint this DAG — resolves U2), rebuilding a `%Layout{}` from the manifest's `segment`+`scope` to locate each feature's checkpoint (FR-012) — in `lib/speckit_orchestrator/web/live/pipeline_dag_live.ex` (`load_layout/1`, `manifest_record/0`, `checkpoints_for/1`) (depends on T013, T015, T033)
- [X] T020 [US2] Update `TriggerLive` to list breakdown packages under `specs/autonomous/breakdown/` and let the operator select one by slug before starting a backlog run (FR-012) — in `lib/speckit_orchestrator/web/live/trigger_live.ex` (`backlog_preview/0`, `start_opts/1`, render) (depends on T013)
- [X] T021 [P] [US2] Add two fixture breakdown packages, each with a feature `001` (same id, different slug/content), under `test/fixtures/breakdown_packages/alpha/` and `test/fixtures/breakdown_packages/beta/`
- [X] T022 [P] [US2] Integration test: packages `alpha` and `beta` (both containing feature `001`) resolve their feature files and transcripts under distinct slug segments with 0 overwrites (SC-002) — in `test/speckit_orchestrator/run_directory_layout_test.exs` (tag `:integration`) (depends on T013, T015, T021)
- [X] T033 [US2] Thread manifest-recorded `segment`+`scope` into the facade resume paths so scope-partitioned checkpoints/transcripts are found post-crash (resolves I2): `resume_run/1`/`resumable_run/0` read the fixed global `run.json`, take `segment`+`scope`, and rebuild a `%Layout{}`; `resume/2`'s `dispatch_resume`/`run_from_checkpoint` locate `Checkpoint.read/1` under that Layout instead of a bare `Config.transcript_root()`; add a test asserting a crashed breakdown run resumes and finds its checkpoint under `<segment>/<slug>/<feature_id>/` — in `lib/speckit_orchestrator.ex` + `test/speckit_orchestrator/resume_run_test.exs` (depends on T016, T017)

**Checkpoint**: User Stories 1 AND 2 both work independently — breakdown packages are slug-isolated end-to-end (feature files, transcripts, DAG/trigger views), and crash-resume locates scope-partitioned checkpoints via the self-describing global manifest.

---

## Phase 5: User Story 3 - Keep ad-hoc runs separate from breakdown packages (Priority: P3)

**Goal**: Ad-hoc single-feature runs write their seed file to a dedicated ad-hoc location and their transcripts under a dedicated ad-hoc segment, never mixing with any breakdown package.

**Independent Test**: Run one ad-hoc feature and one breakdown feature in the same repository, and confirm the ad-hoc feature file and transcripts resolve under the dedicated ad-hoc location while the breakdown feature resolves under its slug.

### Implementation for User Story 3

- [X] T023 [US3] Route `SpeckitOrchestrator.run_spec/2` to build `Layout` with scope `:ad_hoc` and write the single-spec seed to `Path.join([worktree.path, Layout.in_repo_rel(layout), Path.basename(feature.path)])` — **inside the worktree** (Principle III containment, matching the worktree-relative `breakdown_ref` from T014), NOT the base-repo `layout.ad_hoc_root` (resolves I1) — in `lib/speckit_orchestrator.ex` (`write_seed/3`, `spec_run_opts/3`, `seed_runner/2`, `seed_executor/2`) (depends on T004, T007, T013)
- [X] T024 [US3] Update `gather_taken_ids/1` to scan `layout.ad_hoc_root` (instead of `Config.breakdown_dir()`) for already-taken ad-hoc ids, so two ad-hoc runs never silently overwrite each other's feature file — in `lib/speckit_orchestrator.ex` (depends on T023)
- [X] T025 [US3] Enforce the reserved `"ad-hoc"` breakdown-slug guard at package selection (T013): reject with `{:error, {:reserved_slug, "ad-hoc"}}` from `Layout.build/3` before any `Backlog.load!/1` call — in `lib/speckit_orchestrator.ex` (depends on T013)
- [X] T026 [US3] Update `TranscriptsLive` to browse `<transcript_root>/<segment>/<scope>/<feature_id>` (breakdown slug or the literal `ad-hoc`) instead of the flat `<transcript_root>/<feature_id>` (FR-012) — in `lib/speckit_orchestrator/web/live/transcripts_live.ex` (`list_feature_ids/0`, `find_transcript_path/2`) (depends on T015)
- [X] T027 [P] [US3] Integration test: one ad-hoc run and one breakdown run in the same repo — the ad-hoc feature file lands under `specs/autonomous/ad-hoc`, never under any breakdown package dir, and its transcripts land under the `ad-hoc` segment, distinct from the breakdown slug segment (SC-003) — in `test/speckit_orchestrator/run_directory_layout_test.exs` (tag `:integration`) (depends on T023)
- [X] T028 [P] [US3] Facade-level test: `SpeckitOrchestrator.run/1` selecting a breakdown package literally named `ad-hoc` surfaces `{:error, {:preflight, [{:reserved_slug, "ad-hoc"}]}}` (or equivalent) before any Backlog load — in `test/speckit_orchestrator/run_directory_layout_test.exs` (depends on T025)

**Checkpoint**: All three user stories are independently functional — repository isolation, breakdown-package organization, and ad-hoc separation all hold end-to-end.

---

## Phase 6: Polish & Cross-Cutting Concerns

- [X] T034 Update existing writer/facade test path assertions to the new layout (plan.md Source Code tree mandates this; resolves C1) — repoint hard-coded `../.speckit-worktrees`, `<repo>/.speckit-transcripts`, and `docs/breakdown` paths in `test/speckit_orchestrator/{worktree,transcripts,checkpoint,run_manifest,describe,resume,resume_run,resume_crash,facade_e2e,ledgerlite_dryrun}_test.exs` and any `web/` LiveView tests to the `%Layout{}`-resolved paths (inject a tmp `autonomous_root`/`specs_root` to keep the default suite hermetic); run `mise exec -- mix test` green before Polish continues
- [X] T029 [P] Retire the now-superseded `Config.worktree_root/0`, `Config.transcript_root/0`, `Config.breakdown_dir/0` defaults (old sibling/in-repo paths) — grep for any remaining direct caller outside `Layout`-threaded code and repoint it, or explicitly mark the function as legacy-only (old-layout compatibility, FR-013) — in `lib/speckit_orchestrator/config.ex` (depends on T034)
- [X] T030 [P] Update `docs/runbook.md` with the new `~/.autonomous/` layout, the breakdown-package slug selection workflow (Trigger UI), and the migration note (old-layout data is left in place; drain in-flight runs before upgrading — FR-013/FR-014)
- [X] T031 Run `mise exec -- mix test --cover` and confirm `RepoIdentity` + `Layout` coverage > 90%, default suite stays hermetic (no git/filesystem IO outside `:integration`-tagged tests)
- [X] T032 Run `mise exec -- mix test --include integration` and `mise exec -- mix compile` (warnings-as-errors) clean; walk quickstart.md Scenarios 1–6 end-to-end and check off its Definition of Done

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Depends on Setup — BLOCKS all user stories (RepoIdentity + Layout are the single resolution surface every story threads through, FR-011).
- **User Story 1 (Phase 3)**: Depends on Foundational only.
- **User Story 2 (Phase 4)**: Depends on Foundational; T013 (package/slug selection) also depends on US1's T007 (preflight resolves `Layout` before a scope can be chosen).
- **User Story 3 (Phase 5)**: Depends on Foundational; T023/T025 depend on US2's T013 (scope selection already distinguishes breakdown vs. ad-hoc).
- **Polish (Phase 6)**: Depends on all three user stories being complete.

### User Story Dependencies

- **US1 (P1)**: No dependency on US2/US3 — independently testable once Foundational lands.
- **US2 (P2)**: Builds on US1's preflight/Layout threading (T007) to add scope selection; independently testable via its own fixtures (T021/T022) once T013 lands. T033 (crash-resume checkpoint locality, I2) closes the read-side of the manifest/checkpoint move and is serial after T016/T017.
- **US3 (P3)**: Builds on US2's scope selection (T013) to add the `:ad_hoc` branch; independently testable via T027/T028.

### Parallel Opportunities

- T002/T003 (Foundational) run in parallel — different files, no shared dependency.
- T005/T006 (Foundational tests) run in parallel once their respective modules (T002, T004) exist.
- T011/T012 (US1 tests) run in parallel once T010 lands.
- T014–T018 (US2 writer threading: PhaseRequest, Transcripts, Checkpoint, RunManifest, Describe) run in parallel — five different files, all depending only on T004/T013.
- T033 (US2 resume threading, resolves I2) is **serial after** T016+T017 — it consumes the manifest `segment`+`scope` those tasks add.
- T021/T022 (US2 fixtures + integration test) — T021 first, T022 depends on it, but both are independent of T014–T020.
- T027/T028 (US3 tests) run in parallel once T023/T025 land.
- T034 (existing-test path updates, resolves C1) runs **before** T029 (which retires the old `Config` defaults those tests reference); T029/T030 then run in parallel.

---

## Parallel Example: User Story 2

```bash
# Once T013 (package/slug selection) lands, thread the resolved Layout into
# every durable writer in parallel — five independent files:
Task: "Resolve PhaseRequest.breakdown_ref/1 via layout.breakdown_root in lib/speckit_orchestrator/phase_request.ex"
Task: "Write durable transcripts under layout.transcript_root in lib/speckit_orchestrator/transcripts.ex"
Task: "Resolve Checkpoint paths from layout.transcript_root in lib/speckit_orchestrator/checkpoint.ex"
Task: "Resolve RunManifest paths from layout.transcript_root in lib/speckit_orchestrator/run_manifest.ex"
Task: "Resolve Describe paths from layout.transcript_root in lib/speckit_orchestrator/describe.ex"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup.
2. Complete Phase 2: Foundational — `RepoIdentity` + `Layout`, unit-tested in isolation.
3. Complete Phase 3: User Story 1 — repository isolation for worktrees + transcripts, no-origin refusal.
4. **STOP and VALIDATE**: run T011/T012 and confirm SC-001/SC-004 hold.

### Incremental Delivery

1. Setup + Foundational → resolution surface ready, fully unit-tested.
2. Add US1 → validate SC-001/SC-004 → repository collisions are impossible.
3. Add US2 → validate SC-002 → breakdown packages are slug-isolated, DAG/Trigger views updated.
4. Add US3 → validate SC-003 → ad-hoc runs never pollute a breakdown package.
5. Polish → retire old `Config` defaults, update the runbook, confirm coverage + full quickstart pass.

---

## Notes

- [P] tasks touch different files with no shared dependency chain.
- [Story] labels map every Phase 3–5 task to its spec.md user story for traceability.
- This is a placement-only refactor (plan.md, Assumptions): no task changes what a worktree, transcript, breakdown file, or ad-hoc file *contains* — only where it is written/read.
- FR-013/FR-014 (new-runs-only, no migration) mean no task moves/deletes anything under the old paths (`../.speckit-worktrees`, `<repo>/.speckit-transcripts`, `docs/breakdown`); T029 only stops routing *new* writes through the old `Config` defaults.
- Commit after each task or logical group; stop at either Checkpoint to validate a story independently before moving on.
