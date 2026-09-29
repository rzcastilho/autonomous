---
description: "Task list for feature 030-permissive-containment"
---

# Tasks: Permissive Containment Profile

**Input**: Design documents from `/specs/030-permissive-containment/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/scope-guard.md, contracts/run-options.md, contracts/pack-preflight.md, contracts/operator-surfaces.md, quickstart.md

**Tests**: ExUnit coverage is explicitly required by plan.md's Testing section and the contracts' "Test obligations" — included below.

**Organization**: Tasks are grouped by user story (US1 human sessions, US2 permissive runs, US3 visibility) per plan.md's delivery order. Governance (constitution 6.0.0) is **already ratified** at `.specify/memory/constitution.md` (Version 6.0.0, 2026-09-28) — no governance task is generated.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- File paths are exact and relative to repo root.

## Path Conventions

Single-project OTP layout: `lib/autonomous/`, `lib/autonomous/web/`, `priv/target_pack/.claude/`, `test/autonomous/`, `docs/`. All Elixir commands run through `mise exec --`.

---

## Phase 1: Setup

- [X] T001 Constitution 6.0.0 ratified at `.specify/memory/constitution.md` (Principle III profiles, FR-014) — already done, verified at plan time.

**Checkpoint**: Governance gate cleared. Foundation may begin.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `Containment` pure module, config accessor, and `RunContext` key that every user story's session-driving code depends on.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T002 [P] Create `Autonomous.Containment` pure module in `lib/autonomous/containment.ex`: `normalize/1 :: atom | String.t() -> {:ok, String.t()} | {:error, {:invalid_containment_profile, term}}` (accepts only `:strict`/`:permissive`/`"strict"`/`"permissive"`, atom→string via `Atom.to_string/1` only, never string→atom); `permissive?/1 :: String.t() | nil -> boolean` (`nil` → `false`); `session_env/1 :: String.t() -> %{"AUTONOMOUS_ORCHESTRATED" => "1", "AUTONOMOUS_CONTAINMENT_PROFILE" => profile}`; `pr_note/1 :: String.t() | nil -> String.t()` (`""` unless `"permissive"`, else the exact note text from contracts/operator-surfaces.md); `report_line/1 :: String.t() | nil -> String.t() | nil` (`nil` unless `"permissive"`, else `"containment: permissive (no pack deny list)"`).
- [X] T003 [P] Add `Config.containment_profile/0 :: :strict | :permissive` in `lib/autonomous/config.ex`, `get(:containment_profile, :strict)`, raising `ArgumentError` naming the key and value for anything else (mirror the `model_for/1` raise pattern at line ~77).
- [X] T004 [US-shared] Extend `RunContext` in `lib/autonomous/run_context.ex`: add 13th field `containment_profile :: String.t() | nil`; `capture/1` reads `opts[:containment_profile]` over `Config.containment_profile/0`, stringified via `Containment.normalize/1`; `to_map/1` always writes `"containment_profile"`; `from_map/1` — missing key decodes to `"strict"` (never `nil`); `merge/2` unchanged generic precedence.
- [X] T005 [P] Add `containment: "strict" | "permissive"` option to `PhaseRequest.build/3` and `build_remediation/3` in `lib/autonomous/phase_request.ex` (default `"strict"`): under `"strict"`, `permissions/1` is byte-identical to today except `metadata["claude"][:env]` now carries `Containment.session_env(containment)`; under `"permissive"`, `permission_mode: :bypass_permissions`, `allowed_tools: ~w(Read Write Edit MultiEdit NotebookEdit Bash Grep Glob WebFetch WebSearch)`, `disallowed_tools: ~w(Agent Task ScheduleWakeup)`. Env markers set under **both** profiles.
- [X] T006 [P] Pure unit tests for `Containment` in `test/autonomous/containment_test.exs`: `normalize/1` valid/invalid/atom/string cases, `permissive?/1` nil and both strings, `session_env/1` output shape, `pr_note/1` exact text for `"permissive"`/`"strict"`/`nil`, `report_line/1` for `"permissive"`/`"strict"`/`nil`.
- [X] T007 [P] Unit tests for `RunContext` containment key in `test/autonomous/run_context_test.exs`: `capture/1` precedence (opt over config), `to_map/1` always includes key, `from_map/1` missing key ⇒ `"strict"`, `merge/2` never falls back to live config for a recorded run.
- [X] T008 [P] Unit tests for `PhaseRequest` containment option in `test/autonomous/phase_request_test.exs`: strict-default byte-identical `RunRequest` except env markers; permissive `permission_mode`/`allowed_tools`/`disallowed_tools`; env markers present under both profiles for `build/3` and `build_remediation/3`.

**Checkpoint**: `Containment`, `Config.containment_profile/0`, `RunContext.containment_profile`, and `PhaseRequest`'s `:containment` option exist and are tested. User story work may begin.

---

## Phase 3: User Story 1 - Operator's own Claude Code session is not blocked (Priority: P1) 🎯 MVP

**Goal**: Move all pack denials from `settings.json` into the hook so human interactive sessions are never denied, while orchestrator-driven strict sessions are denied exactly as today.

**Independent Test**: Install the pack into a scratch repo. Start an interactive `claude` session there (not through the orchestrator); request a push, a web fetch/search/download, and an out-of-tree write — none denied. Start an orchestrator-driven session in the same repo under `strict` — all four still denied.

### Tests for User Story 1

- [X] T009 [P] [US1] Pin the `scope_guard_test.exs` helper (`test/autonomous/scope_guard_test.exs`) to clear `AUTONOMOUS_ORCHESTRATED`, `AUTONOMOUS_CONTAINMENT_PROFILE`, and `CLAUDE_CODE_ENTRYPOINT` from the spawned hook's env before every existing assertion runs (undecided origin ⇒ strict), so the suite does not flip when run from inside a Claude Code shell.
- [X] T010 [US1] Add the origin × profile matrix to `test/autonomous/scope_guard_test.exs`: {orchestrated-strict, orchestrated-permissive, interactive, undecided, bad profile value} × {each strict rule_id from research.md R4, one benign command, unparseable stdin} — depends on T012.
- [X] T011 [P] [US1] Add the settings-deny parity test to `test/autonomous/scope_guard_test.exs`: every input denied by the old `settings.json` deny list (`sudo …`, `git push …`, `curl …`, `wget …`, `WebFetch`, `WebSearch`) is denied by the new hook under orchestrated-strict and undecided — depends on T012.

### Implementation for User Story 1

- [X] T012 [US1] Rewrite `priv/target_pack/.claude/hooks/scope_guard.py`: add `PACK_CONTRACT = 2` and a `--contract` flag (prints `2`, exits 0, reads no stdin); implement `decide(origin, profile, tool, tool_input, root)` per contracts/scope-guard.md decision order — (1) unparseable stdin → deny `unparseable` under every origin/profile; (2) resolve origin from `AUTONOMOUS_ORCHESTRATED`/`AUTONOMOUS_CONTAINMENT_PROFILE`/`CLAUDE_CODE_ENTRYPOINT` per research.md R3; (3) `permissive` → allow, no rule list; (4) `strict` → apply the strict rule set (union of old settings + hook rules per research.md R4 table: `write_outside_worktree`, `bash_rm_rf_root`, `bash_rm_rf_home`, `bash_sudo`, `bash_git_push`, `bash_curl`, `bash_wget`, `bash_pipe_to_shell`, `bash_fork_bomb`, `bash_chmod_777_root`, `bash_redirect_outside_worktree`, `tool_web_fetch`, `tool_web_search`); widen the PreToolUse matcher to also cover `WebFetch`/`WebSearch` tool names; deny output uses reason `scope_guard[<profile>|<origin>]: <rule_id>: <detail>` keeping every existing `detail` string verbatim (`write outside worktree denied: <path>`, `dangerous bash denied: <name>`, `redirect outside worktree: <path>`, `unparseable hook input`); unparseable prefix is `scope_guard[unknown|unknown]: unparseable: unparseable hook input`.
- [X] T013 [US1] Drop `permissions.deny` from `priv/target_pack/.claude/settings.json`; widen the PreToolUse hook matcher to `Write|Edit|MultiEdit|NotebookEdit|Bash|WebFetch|WebSearch`; keep `defaultMode` and `allow` list unchanged — depends on T012.
- [X] T014 [US1] Update `TargetPack.install/2` in `lib/autonomous/target_pack.ex` to write the new `settings.json` and hook (mode `0755`); signature and return unchanged — depends on T013.

**Checkpoint**: Human interactive sessions are never denied by the pack; strict orchestrator-driven sessions are denied exactly as today. This slice ships value alone.

---

## Phase 4: User Story 2 - Operator opts a run into the permissive profile (Priority: P2)

**Goal**: Thread the recorded containment profile through every session-driving site so a permissive run's headless sessions get full write/Bash/network access, with preflight and resume/continue locking the profile.

**Independent Test**: Start a run with `containment_profile: :permissive` against a scratch target whose feature needs a web fetch and a sibling-directory write. Both succeed, feature reaches `:done`. Start the same run without a profile choice — same actions denied as today.

### Tests for User Story 2

- [X] T015 [P] [US2] SC-002 probe test in `test/autonomous/scope_guard_test.exs`: under orchestrated-permissive, one input per action class (push, web fetch, web search, download, out-of-tree write) plus `rm -rf /` (checked by the guard only, never executed) → all allow.
- [X] T016 [P] [US2] Test in `test/autonomous/run_context_test.exs` (or `autonomous_test.exs`) that every `RunRequest` built for `RunFeaturePhase` (incl. implement chunks), `RunAutoRemediation`, `RunRemediation`, and `Describe.run/4` under either profile carries `AUTONOMOUS_ORCHESTRATED=1` in `metadata["claude"][:env]` — depends on T018-T021.
- [X] T017 [P] [US2] `TargetPack.verify/2` tests in `test/autonomous/target_pack_test.exs` against real temp git repos: `profile: "strict"` passes on an un-upgraded pack; `profile: "permissive"` requires committed `HEAD:.claude/hooks/scope_guard.py --contract == "2"` and committed `settings.json` with no non-empty `permissions.deny`; either failure or an uncommitted upgrade → `{:pack_outdated, path, "re-run TargetPack.install/2 and commit"}` — depends on T027.

### Implementation for User Story 2

- [X] T018 [P] [US2] Add `containment :: String.t()` field (default `"strict"`) to `FeatureAgent` state in `lib/autonomous/feature_agent.ex`.
- [X] T019 [US2] Seed `containment` from `run_context.containment_profile` in `InitFeature` (`lib/autonomous/actions/init_feature.ex`) — depends on T004, T018.
- [X] T020 [P] [US2] Pass `containment: state.containment` to `PhaseRequest.build/3`/`build_remediation/3` from `RunFeaturePhase` (`lib/autonomous/actions/run_feature_phase.ex`, covers implement chunks via `ChunkRunner`/`Chunking`), `RunAutoRemediation` (`lib/autonomous/actions/run_auto_remediation.ex`), and `RunRemediation` (`lib/autonomous/actions/run_remediation.ex`) — depends on T005, T018.
- [X] T021 [P] [US2] Add `:containment` option to `Describe.run/4` in `lib/autonomous/describe.ex`, sourced by `FeatureRunner` from `run_context.containment_profile` — depends on T005.
- [X] T022 [US2] Read `run_context.containment_profile` in `FeatureRunner` (`lib/autonomous/feature_runner.ex`) and pass it into `InitFeature` and `Describe.run/4` calls — depends on T019, T021.
- [X] T023 [US2] Add `check_pack_contract/2` to `TargetPack` (`lib/autonomous/target_pack.ex`): read `git -C repo show HEAD:.claude/hooks/scope_guard.py`, run with `--contract` via a temp file, require stdout `"2"`; read `git -C repo show HEAD:.claude/settings.json`, require decoded JSON has no non-empty `permissions.deny`; either failure (including `git show` failure for an uncommitted file) → `{:pack_outdated, path, "re-run TargetPack.install/2 and commit"}`.
- [X] T024 [US2] Add `profile:` option (`"strict"` default) to `TargetPack.verify/2`: `"strict"` keeps today's checks unchanged; `"permissive"` adds `check_pack_contract/2` — depends on T023.
- [X] T025 [US2] Add `:containment_profile` option to `Autonomous.run/1` (`lib/autonomous.ex`): resolves via `Config.containment_profile/0` when absent; preflight (before any store write) rejects unknown value with `{:error, {:preflight, [{:invalid_containment_profile, value}]}}`, and rejects `permissive` against a non-contract-2 committed pack with `{:error, {:preflight, [{:pack_outdated, path, hint}]}}` via `TargetPack.verify(repo, profile: resolved)`; resolved value captured into `RunContext.containment_profile` and recorded with the run — depends on T024.
- [X] T026 [US2] Pass `profile: run_context.containment_profile` at the `preflight_stacked/1` call site and the second `TargetPack.verify/2` call in `lib/autonomous.ex` — depends on T024.
- [X] T027 [US2] Add the resume/continue/publish-only profile lock in `lib/autonomous.ex`: `resume/2`, `continue_run/1`, `resume_run/1`, and the publish-only route always source the profile from the recorded run (`RunContext.from_map/1`); an explicit `:containment_profile` opt equal to the recorded value is a no-op, a different value is refused with `{:error, {:preflight, [{:containment_profile_locked, recorded}]}}` before any side effect — depends on T004.
- [X] T028 [US2] Add the two-option (`strict`/`permissive`) containment control to the Trigger Run page (`lib/autonomous/web/live/trigger_live.ex`): initial value from `Config.containment_profile/0`, selection passed as `containment_profile:` to `run/1`; selecting `permissive` shows a one-line consequence note (no pack deny list, container recipe recommended) — depends on T025.

**Checkpoint**: Permissive runs get full access at every session-driving site; strict runs are unaffected; preflight and resume/continue lock the profile correctly.

---

## Phase 5: User Story 3 - The profile is always visible (Priority: P3)

**Goal**: Every operator surface and PR body shows the containment profile when (and only when) it is `permissive`; `strict` surfaces stay byte-identical to today.

**Independent Test**: Run one feature under each profile. Compare report, console pages, and PR body — only the permissive run shows the marker; the strict run's surfaces are unchanged.

**Must ship in the same release as US2 (plan.md Delivery order step 5).**

### Tests for User Story 3

- [X] T029 [P] [US3] `coordinator_test.exs` (`test/autonomous/coordinator_test.exs`): final report and `status/0` snapshot carry `containment_profile: "permissive"` only for a permissive run; key absent for strict.
- [X] T030 [P] [US3] `report_test.exs` (`test/autonomous/report_test.exs`): `Report.format_status/1` includes the line `containment: permissive (no pack deny list)` after the spend line only for permissive; omitted (byte-identical) for strict.
- [X] T031 [P] [US3] `pull_request_test.exs` (`test/autonomous/pull_request_test.exs`): PR body ends with `Remediation.pr_note/1` then `Containment.pr_note(profile)`; profile sourced from `RunSettings.settings["containment_profile"]` so a publish-only resume writes the same note.
- [X] T032 [P] [US3] `web/mission_control_live_test.exs`, `web/run_detail_live_test.exs`, `web/config_live_test.exs`: topbar chip (`data-containment="permissive"`) on every view only when permissive; Run Detail `CONTAINMENT` block and SETTINGS chip list (skips `containment_profile` when strict); Config page row `containment_profile default: permissive` and live run's profile.
- [X] T033 [P] [US3] Confirm `test/support/design_contract.ex` (`design_contract_test.exs`) stays green with no new color/radius/font-size/spacing literal introduced by the chip — depends on T037.

### Implementation for User Story 3

- [X] T034 [P] [US3] Add `containment_profile: "permissive"` key to the `Coordinator` final report map and `Coordinator.status/0` snapshot in `lib/autonomous/coordinator.ex` — present only when the run is permissive — depends on T004.
- [X] T035 [P] [US3] Add the containment line to `Report.format_status/1` in `lib/autonomous/report.ex` via `Containment.report_line/1`, placed after the spend line — depends on T002.
- [X] T036 [P] [US3] Append `Containment.pr_note(profile)` after `Remediation.pr_note/1` in `pr_text/2` in `lib/autonomous.ex`, profile read from `RunSettings.settings["containment_profile"]` — depends on T002.
- [X] T037 [US3] Add the neutral chip (`--raised` fill, `--border-strong` border, `--text`, `--r-chip`, mono, `containment: permissive`) to `lib/autonomous/web/components/layouts.ex` topbar, rendered on every view including Mission Control, only when the run's profile is permissive; add the matching CSS rule using existing tokens only in `priv/static/assets/console.css` — depends on T034.
- [X] T038 [P] [US3] Add the `CONTAINMENT` block (`containment_profile: permissive` + hint to the enforcement guide) and the SETTINGS chip (skipped when strict) to `lib/autonomous/web/live/run_detail_live.ex` — depends on T034.
- [X] T039 [P] [US3] Add the `containment_profile default: permissive` row (shown when the default is permissive) and the live run's profile row to `lib/autonomous/web/live/config_live.ex` — depends on T003.

**Checkpoint**: Every listed surface and every PR body shows the profile exactly when permissive; strict output is byte-identical to `df4b6f3`.

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Docs (FR-017) and live validation across a scratch target.

- [X] T040 [P] Update `docs/enforcement.md`: describe both profiles, correct the stale `--dangerously-skip-permissions` claim (the real SDK path uses `--permission-mode`, research.md R2), recommend the container recipe for `permissive` runs.
- [X] T041 [P] Update `docs/runbook.md`: operator flow for selecting a profile, pack upgrade steps, the `cli`-only entrypoint human-detection limitation (research.md R3 "Verify at implementation").
- [X] T042 [P] Update `docs/harness-contract.md`: document the observed `--permission-mode` path superseding the stale skip-permissions claim.
- [X] T043 [P] Update `CLAUDE.md`'s Enforcement paragraph to describe both containment profiles.
- [X] T044 Run the full suite: `mise exec -- mix test` (design guard included) — depends on all prior tasks.
- [X] T045 Execute quickstart.md §3–§6 live against a scratch target: human session (US1/SC-001), strict run unchanged (SC-003), permissive run (US2/US3/SC-002/SC-004), profile lock on resume (FR-004/SC-005) — depends on T044.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: Done (constitution already ratified).
- **Foundational (Phase 2)**: No dependencies beyond Setup. BLOCKS all user stories.
- **US1 (Phase 3)**: Depends on Foundational (needs `Containment.session_env/1` shape referenced by hook reason text conventions, though the hook itself is Python and has no Elixir dependency — can start hook rewrite immediately, but `TargetPack.install/2` update (T014) has no code dependency on Phase 2).
- **US2 (Phase 4)**: Depends on Foundational (T002-T008) directly — needs `Containment`, `Config.containment_profile/0`, `RunContext.containment_profile`, `PhaseRequest`'s `:containment` option. Also depends on US1's pack rewrite (T012-T013) for `TargetPack.verify/2`'s contract-2 check (T023-T024) to have something real to check against.
- **US3 (Phase 5)**: Depends on Foundational (T002, T004) and on US2's `RunContext`/facade work (T025-T027) for the recorded profile to read. Must ship in the same release as US2 per plan.md.
- **Polish (Phase 6)**: Depends on US1+US2+US3 complete.

### Parallel Opportunities

- Phase 2: T002, T003 in parallel; T004 depends on T002 (uses `Containment.normalize/1`); T005 depends on T002. T006, T007, T008 in parallel once their targets exist.
- Phase 3 (US1): T012 first (hook rewrite); T013 depends on T012 (settings.json matcher/deny removal is independent edit, can be done alongside T012 in the same file review); T009 can start immediately (test harness pinning, no code dependency); T010, T011 depend on T012.
- Phase 4 (US2): T018 standalone; T019 depends on T004+T018; T020, T021 depend on T005+T018 and can run in parallel (different files); T022 depends on T019+T021; T023 standalone; T024 depends on T023; T025 depends on T024; T026 depends on T024; T027 depends on T004; T028 depends on T025.
- Phase 5 (US3): T034, T035, T036 depend only on Foundational and can run in parallel (different files); T037 depends on T034; T038 depends on T034; T039 depends on T003.
- Phase 6: T040-T043 (docs) fully parallel.

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 2: Foundational.
2. Complete Phase 3: US1 — hook rewrite, settings.json deny removal, pack install update, red-team parity/matrix tests.
3. **STOP and VALIDATE**: quickstart.md §3 (human session) and §4 (strict run unchanged). Ships value alone — operator stops being blocked, no autonomous-run behavior changes.

### Incremental Delivery

1. Foundational → US1 (MVP, human sessions unblocked) → US2 (permissive runs) + US3 (visibility, same release as US2) → Polish (docs + full quickstart).

---

## Notes

- [P] tasks touch different files with no unmet dependency.
- US2 and US3 must ship together (plan.md, FR-015/Principle VII visibility obligation for any relaxation).
- `String.to_atom/1` is never used on stored/file-content values (repo-wide ban, 017 R4) — `Containment.normalize/1` only goes atom→string.
- FR-009 gates (branch-drift, artifact-substance, incomplete-session, analyze, clarify, breaker, deadlines) are explicitly **not** touched by this feature — no task modifies them.
- Commit after each task or logical group; stop at each phase checkpoint to validate independently.
