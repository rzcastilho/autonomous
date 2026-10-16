# Tasks: Orchestrator-Owned Target Pack

**Input**: Design documents from `/specs/044-orchestrator-owned-pack/`

**Prerequisites**: plan.md, spec.md, research.md (R1–R11), data-model.md, contracts/target-pack.md (G1–G10), contracts/operator-surfaces.md, quickstart.md

**Tests**: INCLUDED — spec SC-007 and plan.md require new tests for the three target states (no pack, current committed, outdated committed) and the untracked guarantee.

**Organization**: Grouped by user story. All Elixir commands run through `mise exec --`; `warnings_as_errors` is on.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallel (different files, no dependency on incomplete tasks)
- **[Story]**: US1–US4, maps to spec.md user stories

## Path Conventions

Single OTP project: `lib/autonomous/`, `lib/autonomous/web/`, `test/autonomous/`, `docs/`, `.specify/memory/`.

---

## Phase 1: Setup

**Purpose**: Constitution gate and baseline.

- [X] T001 Amend the constitution 7.1.0 → 7.2.0 (MINOR) by running `/speckit-constitution` with the rewordings from research R11: Principle III bullets 3–4 (pack supplied into each worktree untracked, committed pack optional but must meet contract 6, refusal names both remedies, supplying MUST NOT modify a tracked file, supplied files exist only in feature worktrees) and the Development Workflow worktree bullet; include a Sync Impact Report. Edits `.specify/memory/constitution.md` (FR-018). Must land before any code task.
- [X] T002 Baseline: run `mise exec -- mix compile && mise exec -- mix test` and confirm green before changes (record any pre-existing failures).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Pure helpers, exclude writer, reworked `install/2`, and refusal rendering that every story builds on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T003 Replace `merge_settings/2` with pure `local_settings(pack :: map, tracked :: map | nil) :: map` (`@spec`) in `lib/autonomous/target_pack.ex`: drop from `pack["env"]` every key the tracked `settings.json` `env` sets; drop the `env` key entirely when it becomes empty; all other keys verbatim (data-model "Local settings derivation").
- [X] T004 In `lib/autonomous/target_pack.ex` change `@outdated_hint` to name both remedies (update tracked file to contract 6 and commit, or `git rm --cached <file>` + commit so the orchestrator supplies it) and add the `:pack_local_tracked` hint (stop tracking `.claude/settings.local.json`) per contracts/target-pack.md.
- [X] T005 Add exclude-block writer in `lib/autonomous/target_pack.ex` (e.g. `ensure_excluded/1`): resolve `git rev-parse --git-common-dir`, create `info/` if missing, append the marked 044 block (`/.claude/autonomous-pack.json`, `/.claude/settings.local.json`) writing each line only if absent as an exact line, header once, never reorder or remove existing lines; return the list of patterns added; failure → `{:error, {:exclude_failed, reason}}` (data-model "Shared exclude block").
- [X] T006 Rework `install/2` in `lib/autonomous/target_pack.ex`: write `.claude/settings.local.json` = `local_settings(pack, existing settings.json)` only when bytes differ (`Jason.encode!(map, pretty: true) <> "\n"`); NEVER write `.claude/settings.json`; write the marker only when absent or not current; keep stale-hook removal, constitution non-clobber, and `{:error, {:invalid_settings, ".claude/settings.json"}}` before any write; summary map `%{settings, marker, stale_hook_removed, constitution_skipped}` now meaning "written this call" (depends on T003).
- [X] T007 [P] Add `Report.format_reason/1` clauses in `lib/autonomous/report.ex`: `{:pack_local_tracked, rel, hint}` → `"#{rel} is tracked: #{hint}"`; `{:invalid_settings, rel}` → `"#{rel} is not a JSON object — fix or remove it, commit, and re-run"`; `{:pack_supply, reason}` → `"could not supply the target pack: " <> format_reason(reason)`; keep `{:pack_outdated, …}` rendering.
- [X] T008 [P] Extend `test/autonomous/report_test.exs` with the three new `format_reason/1` clauses (depends on T007).
- [X] T009 Extend `test/autonomous/target_pack_test.exs`: `local_settings/2` (tracked env key omitted, empty env dropped, non-env keys verbatim, nil tracked), reworked `install/2` (writes `settings.local.json` and marker, never `settings.json`, tracked `settings.json` byte-identical, second call writes nothing, invalid `settings.json` refused before writes, constitution not clobbered), and exclude writer (block created, no duplicates on second call, pre-existing operator lines preserved, `info/` created when missing). Remove/adjust old `merge_settings` and settings.json-writing assertions (depends on T003–T006).

**Checkpoint**: Foundation ready — `install/2`, exclude writer and refusal rendering verified in isolation.

---

## Phase 3: User Story 1 - Start a run on a repo that carries no orchestrator files (Priority: P1) 🎯 MVP

**Goal**: A target with no committed pack passes the preflight, and every feature worktree gets the marker and `settings.local.json`, untracked everywhere.

**Independent Test**: Target with constitution + `.claude/skills` + `.specify/` and no pack files: `verify/2` → `:ok`; `Worktree.create/2` yields both files; `git status --porcelain` empty in worktree and checkout; commit + squash diff names neither file (G1, G2, G3, G10).

### Tests for User Story 1

- [X] T010 [P] [US1] In `test/autonomous/target_pack_test.exs` add G1: `verify/2` on a target whose committed tree has no `.claude/autonomous-pack.json` and no `.claude/settings.json` returns `:ok`; constitution/skills/`.specify` checks (FR-002) still fail when those are missing or template.
- [X] T011 [P] [US1] In `test/autonomous/target_pack_test.exs` add `supply/1` tests on a temp git repo + linked worktree: returns `{:ok, %{source: :supplied, wrote: [...], excluded: [...]}}`; both files exist; second call → `wrote: [], excluded: []` (G9).
- [X] T012 [P] [US1] In `test/autonomous/worktree_test.exs` add G2/G3/G10 against temp repos: after `create/2` both files exist and `git status --porcelain` is empty in worktree and target checkout; after `commit/2` + `squash/3`, `git diff --name-only <fork>..HEAD` names neither `.claude/autonomous-pack.json` nor `.claude/settings.local.json`; target checkout never gains either file.

### Implementation for User Story 1

- [X] T013 [US1] In `lib/autonomous/target_pack.ex` `verify/2`: remove `require_file(".claude/settings.json")`; make `check_pack_contract/2` treat an absent marker and absent `settings.json` as ok (supplied), keeping the present-file checks and reading `git show HEAD:<path>` (contracts/target-pack.md verify step 3; FR-001).
- [X] T014 [US1] Add `TargetPack.supply(worktree_path)` in `lib/autonomous/target_pack.ex` with `@spec`: run `ensure_excluded/1` then `install/2` against the worktree, return `{:ok, %{source, wrote, excluded}}`; never writes, merges or deletes a tracked path (tracked-tree refusals are added in US2/T022) (depends on T005, T006).
- [X] T015 [US1] In `lib/autonomous/worktree.ex`: remove `.claude/settings.json` from `@scaffold_files` (scaffold = `.specify`, `.claude/skills`); in `create/2` call `TargetPack.supply/1` after the scaffold assertion, honouring new option `:supply_pack` (default `true`); on supply error remove the half-made worktree like the `:missing_scaffold` path and return `{:error, {:pack_supply, reason}}` (depends on T014).
- [X] T016 [US1] Confirm callers (`lib/autonomous.ex` `run_fresh`, `default_executor`, `seed_executor`/`run_spec/2`, `FeatureRunner`) surface `{:pack_supply, reason}` as `{:worktree, {:pack_supply, reason}}` and that preflight call sites (`:2366`, `:2654`) need no edit; adjust only if a caller pattern-matches `create/2` errors too narrowly.
- [X] T017 [US1] Update existing `test/autonomous/worktree_test.exs` fixtures that created worktrees from a target committing `settings.json` as scaffold so they pass with the new scaffold set; use `supply_pack: false` only where the test exercises pure git plumbing.

**Checkpoint**: US1 independently functional — pack-less target runs untracked end to end (MVP).

---

## Phase 4: User Story 2 - A target that still commits a pack keeps working (Priority: P1)

**Goal**: Committed current packs work byte-identically with operator `env` precedence; committed outdated packs, tracked `settings.local.json` and invalid `settings.json` are refused before any session; non-pack `settings.json` is untouched.

**Independent Test**: Three targets — committed current pack (+ operator `env`), committed outdated pack, non-pack `settings.json` — plus tracked `settings.local.json` (G4–G7).

### Tests for User Story 2

- [X] T018 [P] [US2] In `test/autonomous/target_pack_test.exs` add G5: committed marker `contract: 5`, committed `permissions.deny`, committed scope-guard `PreToolUse` hook, and tracked `.claude/hooks/scope_guard.py` are each refused by `verify/2` and by `supply/1` with `{:pack_outdated, rel, hint}`; hint contains both remedies.
- [X] T019 [P] [US2] In `test/autonomous/target_pack_test.exs` add G6/G7 and invalid input: non-pack tracked `settings.json` (no marker, no deny/hook) passes `verify/2` and stays byte-identical after `supply/1`; tracked `.claude/settings.local.json` → `{:pack_local_tracked, rel, hint}`; tracked `settings.json` not a JSON object → `{:invalid_settings, rel}`.
- [X] T020 [P] [US2] In `test/autonomous/worktree_test.exs` add G4: committed current pack with tracked `settings.json` holding `"env": {"BASH_DEFAULT_TIMEOUT_MS": "60000"}` — after `create/2`, `git diff` and `git status --porcelain` empty, tracked files byte-identical, `settings.local.json` lacks that env key; plus `create/2` with an outdated committed pack returns `{:error, {:pack_supply, {:pack_outdated, …}}}` and leaves no worktree directory.
- [X] T021 [P] [US2] Add a preflight-refusal test (in the existing `run/1`/preflight test file under `test/autonomous/`; locate with `rtk grep -l "TargetPack.verify\|:preflight" test/`) asserting an outdated committed pack yields `{:error, {:preflight, problems}}` before any store write or session, and that removing the pack from version control (`git rm --cached`) then passes (US2-4).

### Implementation for User Story 2

- [X] T022 [US2] In `lib/autonomous/target_pack.ex` extend `check_pack_contract/2` (first failure wins: marker → settings.json → stale hook → settings.local.json): marker present must decode with `contract >= 6`; `settings.json` present must be a JSON object, with no scope-guard hook registration and no non-empty `permissions.deny`; `.claude/hooks/scope_guard.py` not tracked; `.claude/settings.local.json` not tracked via `git ls-files --error-unmatch` (skipped when `committed? = false`). A non-pack `settings.json` must pass (FR-007, FR-008).
- [X] T023 [US2] In `TargetPack.supply/1` add step 1 (worktree tracked-tree inspection via `git -C <wt> ls-files` + working copy, reusing `check_pack_contract/2` with `committed? = false` semantics for the worktree) BEFORE the exclude/install steps, so every tracked-file case is refused and no tracked file is ever modified (FR-005, FR-007) (depends on T022).
- [X] T024 [US2] Verify precedence end to end: `local_settings/2` wiring in `install/2` reads the worktree's tracked `settings.json` `env` (not the pack's) so the operator's value is the one in effect (FR-006); fix if T020 shows leakage.

**Checkpoint**: US1 + US2 both work; all three target states covered (SC-007).

---

## Phase 5: User Story 3 - Resume and continue across the change (Priority: P2)

**Goal**: Pre-044 runs resume/continue with the pack supplied, no new worktree change, and refused continues stay parked byte-identical.

**Independent Test**: Worktrees from before the feature (holding a committed pack, or neither file) go through `restore/1` / `resume` / `continue_run/1` (G8).

### Tests for User Story 3

- [X] T025 [P] [US3] In `test/autonomous/worktree_test.exs` add G8: `restore/1` on a pre-044 worktree with a committed current pack leaves tracked files untouched, and on a worktree with neither file supplies both, with `git status --porcelain` empty; running `restore/1` twice keeps the exclude block single.
- [X] T026 [P] [US3] In the existing `continue_run/1`/`resume/2` test file (locate with `rtk grep -l "continue_run" test/`) add: continue on a parked run whose worktree lacks the pack supplies it before the first session and no pack file becomes a change; continue refused by an outdated committed pack returns the same reason term and leaves the run record `:parked`, byte-identical (FR-012, feature 035).

### Implementation for User Story 3

- [X] T027 [US3] In `lib/autonomous/worktree.ex` `restore/1`: call `TargetPack.supply/1` after `reset --hard` + `clean -fd` (excluded files survive `clean` without `-x`; re-supply covers pre-044 worktrees); on error return `{:error, {:pack_supply, reason}}`.
- [X] T028 [US3] Confirm `resume_worktree/2` (used by `resume/2`, `resume_run/1`, `continue_run/1`) reaches supply via `create/2`/`restore/1` and that `preflight_stacked/2`'s pack check runs against the still-parked run before `Writer.continue_run/1`; make no edits to `lib/autonomous.ex` unless T026 fails.

**Checkpoint**: US1–US3 work; upgrade mid-run is safe.

---

## Phase 6: User Story 4 - Operator can see and manage the pack state (Priority: P3)

**Goal**: Configuration shows pack source and contract; docs describe the orchestrator-supplied pack as the default.

**Independent Test**: Configuration "target pack" row for each of the three target states; docs read correctly.

### Tests for User Story 4

- [X] T029 [P] [US4] Create `test/autonomous/web/pack_view_test.exs`: `state/1` maps `{:ok, %{source: :supplied, contract: 6}}` → `{:supplied, 6}`, `:committed` → `{:committed, n}`, `{:error, reason}` → `{:refused, text}` using `Report.format_reason/1`; `summary/1` strings `supplied by the orchestrator — contract 6` / `committed in the target — contract n`; no `inspect/1`.
- [X] T030 [P] [US4] In `test/autonomous/target_pack_test.exs` add `source/1` tests: no marker → `{:ok, %{source: :supplied, contract: 6}}`; committed current marker → `:committed` with its contract; outdated/undecodable marker, deny, hook, tracked `settings.local.json`, invalid `settings.json` → `{:error, reason}`.
- [X] T031 [P] [US4] In `test/autonomous/web/config_live_test.exs` assert the "target pack" row for each state: `data-pack-source="supplied|committed|refused"`, text per contracts/operator-surfaces.md, `checking…` while loading, refusal rendered through `.form_refusal`.

### Implementation for User Story 4

- [X] T032 [US4] Add `TargetPack.source(repo)` in `lib/autonomous/target_pack.ex` returning `{:ok, %{source: :supplied | :committed, contract: pos_integer()}} | {:error, reason}` using the same reads as `check_pack_contract/2` (R8).
- [X] T033 [P] [US4] Create pure `lib/autonomous/web/pack_view.ex` (`state/1`, `summary/1`) per data-model "Console view state"; no color/spacing literals, no `inspect/1`.
- [X] T034 [US4] In `lib/autonomous/web/live/config_live.ex` add the "target pack" `<dt>/<dd>` row next to "agent root" (~`:256`): always rendered, mono `config-instance-id` class, `data-pack-source` name only, value loaded in a `Task` (`TargetPack.source(Config.repo())`) on connected mount/refresh with initial `:loading` → `checking…`, task failure → `{:refused, …}` not a crash (depends on T032, T033).
- [X] T035 [P] [US4] Update `docs/enforcement.md` § Target pack: orchestrator-supplied is default; install leaves the operator checklist; "Reinstalling an outdated pack" gains the remove-from-VCS remedy; three-state compatibility table (FR-017).
- [X] T036 [P] [US4] Update `docs/runbook.md`: target setup no longer commits the pack; refusal messages and both remedies; Configuration "target pack" row; manual `install/2` is optional and affects the operator's own checkout sessions (R10).
- [X] T037 [P] [US4] Update `docs/container.md`: replace "committed target pack" wording with "target pack (supplied into each worktree, or committed)".
- [X] T038 [P] [US4] Update `/Users/castilho/code/github.com/rzcastilho/autonomous/CLAUDE.md`: rewrite the Enforcement paragraph (`supply/1`, `settings.local.json`, shared exclude, `verify/2` no longer requires the files) and add an "Orchestrator-owned pack (feature 044)" section.

**Checkpoint**: All four stories complete.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T039 [P] Add FR-014/SC-002 check in `test/autonomous/worktree_test.exs` (or the describe/publish test file): commit message and PR body text produced after a supplied run, and the branch diff, never mention `autonomous-pack.json` or `settings.local.json`.
- [X] T040 [P] Add a test asserting session configuration is identical for supplied vs committed packs (permission mode, tool set, shell-timeout env, markers) in the existing `PhaseRequest` test file (SC-003, FR-009); `PhaseRequest` itself must stay unchanged.
- [X] T041 Run `mise exec -- mix compile` (warnings_as_errors) and the full `mise exec -- mix test`, including `design_contract_test.exs`; fix any warning, failure or guard hit (no new tokens, no inline style, no `inspect/1`).
- [ ] T042 Execute quickstart.md §2–§7 manually in `iex -S mix` against scratch targets (no pack, committed current + operator env, committed outdated, tracked `settings.local.json`, parked pre-044 run, console row); optionally §8 in the container.
- [X] T043 Final review of `git diff` for the FR-005 invariant: no code path writes or deletes a tracked target file, and `Autonomous`'s only pack calls on the checkout are read-only (`verify/2`, `source/1`) (FR-016).

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (1)**: T001 first (constitution gate); T002 any time before code.
- **Foundational (2)**: after Setup; blocks all stories. T003→T006→T009; T007→T008 parallel with the rest.
- **US1 (3)** → **US2 (4)** → **US3 (5)**: US2 extends `check_pack_contract/2` and `supply/1` from US1; US3 extends `Worktree.restore/1` using `supply/1`.
- **US4 (6)**: `source/1` (T032) needs the final `check_pack_contract/2` (T022); `PackView` (T033) and docs tasks need only Foundational and can start earlier.
- **Polish (7)**: after desired stories.

### Within Each Story

- Tests are written first and must fail before implementation.
- `target_pack.ex` tasks within a phase are sequential (same file); `[P]` tests in different files run in parallel.

### Parallel Opportunities

- Phase 2: T007+T008 (report) alongside T003–T006 (target_pack).
- US1 tests T010/T011/T012; US2 tests T018–T021; US3 tests T025/T026; US4 tests T029–T031 and docs T035–T038.
- US4 `pack_view.ex` (T033) and docs can proceed while US2/US3 code lands.

### Parallel Example: User Story 2 tests

```bash
Task: "G5 outdated-pack refusals in test/autonomous/target_pack_test.exs"          # T018
Task: "G4 committed-pack byte-identity in test/autonomous/worktree_test.exs"       # T020
Task: "preflight refusal before any store write in the run/preflight test file"    # T021
```

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. Phase 1 (T001–T002) → Phase 2 (T003–T009).
2. Phase 3 (T010–T017).
3. **Stop and validate**: quickstart §2 — pack-less target runs, nothing tracked.

### Incremental Delivery

1. + US2 (compatibility/refusals) → quickstart §3–§5. US1+US2 together are the shippable P1 slice; do not release US1 alone, since upgrading existing committed-pack targets needs US2's refusals.
2. + US3 (resume/continue) → quickstart §6.
3. + US4 (console + docs) → quickstart §7.
4. Polish → full suite, design guard.

---

## Notes

- Pack contract number stays **6** (R7); no store schema change.
- Never edit `priv/target_pack/.claude/` bytes — its `settings.json` is the local-file template.
- Behavioural changes beyond this spec require a new `/speckit-specify` feature.
- Commit after each task or logical group.
