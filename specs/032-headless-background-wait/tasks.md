# Tasks: Headless Background-Wait Hardening

**Input**: Design documents from `/specs/032-headless-background-wait/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (4 files), quickstart.md

**Tests**: Included. The constitution (Quality & Test Discipline) requires hermetic unit tests for pure modules (>90% coverage) and the plan lists a test file per touched module.

**Organization**: Grouped by user story. US1 and US2 are both P1 and independent. US3/US4 are P2. US5 is P3.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1–US5, from spec.md
- All Elixir commands run through `mise exec -- …`. `warnings_as_errors` is on.
- Paths are repo-root relative. Core code is in `lib/autonomous/`, tests in `test/autonomous/`.

---

## Phase 1: Setup

**Purpose**: Confirm the toolchain and CLI pin, and record the green baseline.

- [X] T001 Confirm `claude --version` prints `2.1.287`, `mise trust mise.toml` is done, and `mise exec -- mix test` is green on branch `032-headless-background-wait`. Record the baseline test count in a comment on this task. *(Baseline: 1896 tests green, `claude` 2.1.287; after Phase 3: 1953+.)*
- [X] T002 [P] Create the fixture directory `test/fixtures/sessions/` (used by T006 and T011).

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The one option that both US1 wiring and US3 prompt work depend on. It lands as a no-op-when-empty option so nothing else changes.

**⚠️ CRITICAL**: US1 wiring (T012–T016) needs this.

- [X] T003 Add the `:background_retry` option (list of command strings) to `PhaseRequest.build/3` in `lib/autonomous/phase_request.ex`. `nil` or `[]` produces a byte-identical prompt. A non-empty list appends the "Retry note" block **last** (after resume guidance and clarify answers), each command truncated to 200 chars (contracts/prompt-and-tools.md §2). Add tests in `test/autonomous/phase_request_test.exs`: absent/empty is byte-identical, non-empty names every command, note is the final block, truncation at 200.

**Checkpoint**: Option exists and is inert unless set.

---

## Phase 3: User Story 1 - A session that ends while waiting on background work is never counted as a success (Priority: P1) 🎯 MVP

**Goal**: Detect a stranded backgrounded shell command in a successful session, retry once with a corrective note, then fail with `{:backgrounded_command, where, commands}`.

**Independent Test**: Replay the SC-001 fixture (synthetic fretboard-master 014 stall). The phase is classified incomplete on the first evaluation, retried once, then failed with a reason naming the command. Never `{:stuck_task_phase, …}`.

### Tests for User Story 1 ⚠️ (write first, confirm they fail)

- [X] T004 [P] [US1] Create `test/autonomous/background_marker_test.exs`: each of the four marker modes (`:timeout`, `:message`, `:manual`, `:explicit`) parses `task_id`; output path parses with trailing `.` stripped; list-of-content-blocks output is flattened; non-text output and unrelated text return `:none`; `explicit_call?/1` true only for `run_in_background: true` (contracts/background-detection.md §1).
- [X] T005 [P] [US1] Create the SC-001 replay fixture `test/fixtures/sessions/background_wait_014.exs`: a synthetic event stream modeled on fretboard-master 014 session `3e935ca9` (Bash call → `:timeout` marker with id and output path → watcher/Monitor call → `:session_completed` success, no read of the output).
- [X] T006 [US1] Extend `test/autonomous/phase_result_test.exs` with the 10-row table from contracts/background-detection.md §2: resolve by `Read` of the output path (row 2), by id substring in any later event (3), unrelated later calls stay stranded (4), explicit mode (5), explicit with no marker and no ids (6), marker result never resolves itself (7), non-`:ok` status returns `[]` (8), existing fixtures return `[]` (9), SC-001 fixture is non-empty (10).
- [X] T007 [P] [US1] Extend `test/autonomous/pipeline_test.exs`: `next(phase, :error, %{backgrounded: [_|_]})` returns `{:failed, {:backgrounded_command, phase, cmds}}`, takes precedence over the plain `outstanding_work?: true` clause, and `branch_drift` still wins.
- [X] T008 [P] [US1] Extend `test/autonomous/phase_step_test.exs`: `retry_reason/1` returns `"ended waiting on a backgrounded command"` when `signals[:backgrounded]` is non-empty. Branch drift is still never retried. Both gates firing yields one retry. The retry's `"phase.run"` data carries `background_retry: cmds`. A retry for another reason carries no such key (FR-002a).
- [X] T009 [P] [US1] Extend `test/autonomous/chunking_test.exs`: row B per contracts/background-detection.md §4: first backgrounding re-dispatches the same scope with `background_retried?: true`. A second fails with `{:backgrounded_command, ref, cmds}`. Ceiling reached yields `{:session_ceiling, n}`. The flag resets on cursor advance and at sweep start.
- [X] T010 [P] [US1] Extend `test/autonomous/chunk_runner_test.exs`: a `:backgrounded` signal is lifted from the session result, the re-dispatch passes `background_retry: cmds`, and a clean second session proceeds normally.
- [X] T011 [P] [US1] Extend `test/autonomous/report_test.exs`: `format_reason/1` for `{:backgrounded_command, where, [c | rest]}` renders `"<where> ended waiting on backgrounded command: <c ≤120 chars>"`, plus `" (+N more)"` when `rest != []`. A chunk ref renders its task-phase label.

### Implementation for User Story 1

- [X] T012 [US1] Create `lib/autonomous/background_marker.ex`: `parse/1` and `explicit_call?/1` with the CLI 2.1.287 regexes (contracts/background-detection.md §1). Isolate all CLI wording here, with `@spec`s.
- [X] T013 [US1] In `lib/autonomous/phase_result.ex` add the `BackgroundedCommand` struct and `backgrounded_commands/1` and `stranded_background/1` (data-model.md §1). Resolution is a later event (index > position) containing `task_id` or `output_path`. `stranded_background/1` returns `[]` unless `status == :ok`. Depends on T012.
- [X] T014 [US1] Add the `Pipeline.next/3` clause for `backgrounded` ahead of the `outstanding_work?: true` clause in `lib/autonomous/pipeline.ex`.
- [X] T015 [US1] In `lib/autonomous/phase_step.ex` extend `retry_reason/1` (branch drift keeps first place) and thread `background_retry: cmds` into the retry's `"phase.run"` data only for the backgrounding reason.
- [X] T016 [US1] Add the background gate to `lib/autonomous/actions/run_feature_phase.ex`. Order is branch drift → background → `outstanding_work?` → phase gates. Suppress for `:plan`/`:tasks` when the artifact gate is satisfied, never for implement. Return `{:error, %{outstanding_work?: true, backgrounded: cmds}}` and log at `:warning`. Forward `background_retry` to `PhaseRequest.build/3`. Depends on T003, T013.
- [X] T017 [P] [US1] Add the same gate (branch drift → background → status, no suppression) to `lib/autonomous/actions/run_auto_remediation.ex`. Depends on T013.
- [X] T018 [P] [US1] Add the same gate to `lib/autonomous/actions/run_remediation.ex`. Depends on T013.
- [X] T019 [US1] In `lib/autonomous/chunking.ex` add `background_retried?` to `ChunkState` and row B (after row 0, before row 2) with the reset rules. Depends on T014 for the reason shape.
- [X] T020 [US1] In `lib/autonomous/chunk_runner.ex` lift the `:backgrounded` signal from the chunk session result and re-dispatch with `background_retry: cmds` on row B. Depends on T003, T019.
- [X] T021 [US1] Add the `format_reason/1` clause for `{:backgrounded_command, where, cmds}` in `lib/autonomous/report.ex` (contracts/background-detection.md §5).
- [X] T022 [US1] Add action-level tests (extend the existing test file for each action, or create it if absent under `test/autonomous/actions/`): gate order, suppression only for `:plan`/`:tasks`, and no change for sessions without backgrounding. Includes the SC-001 end-to-end replay: first evaluation incomplete, one retry, then `{:backgrounded_command, :implement, cmds}`.
- [X] T023 [US1] Create `test/autonomous/integration/background_wait_test.exs` (`@moduletag :integration`) with probe 2 from quickstart §2: a real `claude` session runs `sleep 5` with `run_in_background: true`. `PhaseResult.reduce/1` plus `stranded_background/1` returns one command.

**Checkpoint**: US1 works alone. A stranded background command is never a success. Run `mise exec -- mix test` before moving on.

---

## Phase 4: User Story 2 - Long verification gates finish in the foreground (Priority: P1)

**Goal**: Every orchestrated session gets `BASH_DEFAULT_TIMEOUT_MS` and `BASH_MAX_TIMEOUT_MS`, derived from its own deadline, through both the launch env and `--settings`.

**Independent Test**: Build requests for a phase and a scaled implement chunk. Both timeout values are present on both channels, are above 10 min, and sit at least 5 min below that session's deadline. Deadlines of 10 min or less pin the CLI built-ins.

### Tests for User Story 2 ⚠️

- [X] T024 [P] [US2] Create `test/autonomous/shell_timeouts_test.exs`: the full table in contracts/session-timeouts.md §1 (3_000_000, 1_200_000, 900_000, 600_001, 600_000, 60_000, 14_400_000) plus a property over generated deadlines `d > 600_000`: `max ≤ d − 300_000` and `default ≤ max` (SC-003). Values are decimal strings.
- [X] T025 [US2] Extend `test/autonomous/phase_request_test.exs`: every phase × both containment profiles carries equal values in `metadata["claude"][:env]` and in `[:settings]` JSON. The `AUTONOMOUS_*` markers are unchanged. A chunk-sized `deadline_ms` changes the values. No `deadline_ms` uses `Config.phase_timeout/0`. Same for `build_remediation/3`. Add the adapter-level check that `ClaudeAgentSDK.Options.to_args/1` on the built options contains `"--settings"` with the JSON.

### Implementation for User Story 2

- [X] T026 [P] [US2] Create `lib/autonomous/shell_timeouts.ex`: pure `for_deadline/1`. Constants are module attributes (45 min cap, 30 min default cap, 5 min headroom, 10 min floor, CLI built-ins 120 000 / 600 000). `d ≤ 600_000` pins the built-ins (plan deviation, research R3).
- [X] T027 [US2] In `lib/autonomous/phase_request.ex` add the `:deadline_ms` option (default `Config.phase_timeout/0`) to `build/3` and `build_remediation/3`. Merge the timeouts into `env` with `Containment.session_env/1` and set `settings: Jason.encode!(%{"env" => timeouts})`. Depends on T026, and sequential after T003.
- [X] T028 [US2] Pass the enforced deadline: `lib/autonomous/actions/run_feature_phase.ex` uses `Map.get(params, :deadline_ms) || Config.phase_timeout()`. `lib/autonomous/actions/run_auto_remediation.ex` and `lib/autonomous/actions/run_remediation.ex` use `Config.phase_timeout()`. Confirm `lib/autonomous/chunk_runner.ex` already sends the scaled deadline. Depends on T027, and sequential after T016/T017/T018.
- [X] T029 [US2] Add probe 1 to `test/autonomous/integration/background_wait_test.exs`: a target `.claude/settings.json` sets `BASH_MAX_TIMEOUT_MS=60000`, a one-turn session built with a 50-min deadline echoes the variable, and the output must be `2700000` (quickstart §2). Sequential after T023. **RESOLVED (2026-10-05) by pinning a fork, `rzcastilho/jido_claude` @ `1b5d54a`, with `:settings` added to `@option_keys`; probe 1 passes live. The adapter is private-API, so the T025 `Options.to_args/1` check stays and the live probe is the adapter-level proof. Original block:** probe written and fails live — `Jido.Claude.Adapter.normalize_map_keys/1` whitelists `@option_keys` (no `:settings`), so `metadata["claude"][:settings]` is silently dropped and the target's `BASH_MAX_TIMEOUT_MS=60000` wins over the launch env (R2 assumed the adapter merges metadata straight through). The T025 `Options.to_args/1` check passes but does not exercise the adapter.

**Checkpoint**: US1 and US2 both work. P1 scope is complete.

---

## Phase 5: User Story 3 - The model is told the session is headless (Priority: P2)

**Goal**: A versioned headless rule appears in the implement task-phase, sweep, whole-list and converge prompts, and nowhere else.

**Independent Test**: Build every phase prompt. Only the four scopes contain the rule. All other prompts are byte-identical to pre-032.

### Tests for User Story 3 ⚠️

- [X] T030 [US3] Extend `test/autonomous/phase_request_test.exs`: the rule is present for `{:task_phase, _}`, `{:sweep, _}`, `:whole_list` and `:converge` (placed between `converge.md` and the feature tag). It is absent for `scope: nil` and for specify, clarify, plan, tasks, analyze, describe and remediation, which stay byte-identical. The separator is `"\n\n---\n"`.

### Implementation for User Story 3

- [X] T031 [P] [US3] Create `priv/prompts/headless_rule.md` with the four obligations in contracts/prompt-and-tools.md §1: foreground with an explicit long `timeout`, no `run_in_background` or watcher, never end the turn mid-command, and read the output file if a command is backgrounded anyway.
- [X] T032 [US3] In `lib/autonomous/phase_request.ex` append `Prompts.load("headless_rule")` to the implement task-phase, sweep and whole-list blocks and to the converge prompt (placement table, contracts/prompt-and-tools.md §1). Depends on T031, and sequential after T027.

**Checkpoint**: Prompts carry the rule where required.

---

## Phase 6: User Story 4 - Background-wait tools are unavailable to headless sessions (Priority: P2)

**Goal**: `Monitor` is excluded from every headless session under both profiles.

**Independent Test**: For every phase plus remediation, under strict and permissive, `"Monitor" in request.disallowed_tools`.

### Tests for User Story 4 ⚠️

- [X] T033 [US4] Extend `test/autonomous/phase_request_test.exs`: `"Monitor"` is in `disallowed_tools` for every pipeline phase and both remediation clauses, under both profiles. Update the existing assertion on the `@headless_disallowed` list.

### Implementation for User Story 4

- [X] T034 [US4] In `lib/autonomous/phase_request.ex` change `@headless_disallowed` to `~w(Agent Task ScheduleWakeup Monitor)`. Confirm that every `strict_permissions/1` clause, `permissive_permissions/0` and both `remediation_permissions/1` clauses reference the attribute. Sequential after T032.

**Checkpoint**: The watcher tool is gone from headless sessions.

---

## Phase 7: User Story 5 - The enforcement pack carries long timeouts without clobbering the target's settings (Priority: P3)

**Goal**: Pack contract 4. `settings.json` ships default timeouts in `env`. Install merges `env` with the target winning. The permissive preflight requires contract 4.

**Independent Test**: Install into a target whose `settings.json` has its own `env` (including one timeout key). Target entries survive and only missing pack keys are added. A permissive preflight on a contract-3 pack is refused with the upgrade hint.

### Tests for User Story 5 ⚠️

- [X] T035 [P] [US5] Extend `test/autonomous/target_pack_test.exs`: no existing settings means the pack file is written as-is. An existing `env` is preserved with its values and only absent pack keys are added (SC-004). A non-`env` key keeps overwrite semantics. A second install is byte-identical. Unparseable or non-object settings return `{:error, {:invalid_settings, ".claude/settings.json"}}` and write nothing. The permissive preflight on contract 3 returns the `:pack_outdated` error, contract 4 passes, and the strict preflight is unchanged.
- [X] T036 [P] [US5] Extend `test/autonomous/scope_guard_test.exs`: the contract probe expects `4`. The origin × profile decision matrix is untouched.

### Implementation for User Story 5

- [X] T037 [P] [US5] Add the `env` object (`BASH_DEFAULT_TIMEOUT_MS=1800000`, `BASH_MAX_TIMEOUT_MS=2700000`) to `priv/target_pack/.claude/settings.json`. Leave `permissions` and `hooks` unchanged.
- [X] T038 [P] [US5] Set `PACK_CONTRACT = 4` in `priv/target_pack/.claude/hooks/scope_guard.py` and record "4: settings.json env shell timeouts (feature 032)" in the docstring. No decision-logic change.
- [X] T039 [US5] In `lib/autonomous/target_pack.ex`: set `@pack_contract "4"`, add `merge_settings/2` (pack wins except `env`, where `Map.merge(pack_env, target_env)`), make `install/2` refuse invalid existing JSON, emit stable pretty output, and widen the `@spec` to `{:ok, map()} | {:error, term()}`. Update the permissive preflight to require contract 4 (strict unchanged).
- [X] T040 [US5] Update the callers and docs of `install/2` that assumed it never errors (`scripts/`, `docs/runbook.md` install snippet) to handle `{:error, {:invalid_settings, _}}`. Depends on T039.

**Checkpoint**: All five stories work independently.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [X] T041 [P] Update `docs/harness-contract.md` (FR-016): the CLI's built-in 10-minute Bash cap, the four marker wordings, `BASH_DEFAULT_TIMEOUT_MS`/`BASH_MAX_TIMEOUT_MS`, the `--settings` vs project-settings precedence, the `Monitor` tool, and a "re-check on CLI bump" note.
- [X] T042 [P] Add a symptom/cause/fix entry to `docs/runbook.md` (FR-015): "implement sweeps stall after a command is moved to the background", including the new `{:backgrounded_command, …}` reason and the pack upgrade step.
- [X] T043 [P] Update the "Session deadlines" paragraph in `CLAUDE.md` (FR-016): shell timeouts derive from the session deadline (max = min(45, d − 5) min), delivered through env and `--settings`, so the deadline always fires first.
- [X] T044 [P] Amend `.specify/memory/constitution.md` with PATCH 6.0.1 (research R10): wording that names the background-watcher tool in the permissive bullet, and update its Sync Impact Report.
- [X] T045 Run `mise exec -- mix compile` (warnings as errors) and the full `mise exec -- mix test`. Confirm the only changed existing cases are the deliberate ones (request metadata, disallowed list, pack contract probe, implement/converge prompts), per SC-005.
- [X] T046 Run `mise exec -- mix test --cover` and confirm coverage >90% on `BackgroundMarker`, `ShellTimeouts`, and the new `PhaseResult` functions.
- [X] T047 Run `mise exec -- mix test --include integration test/autonomous/integration/background_wait_test.exs` against the real CLI (both probes). Run the manual pack-install check from quickstart §3. Both probes pass live (2026-10-05, after the T029 vendor patch); the §3 pack-install behavior is covered by `target_pack_test` but the manual run was not done.
- [ ] T048 Field validation (SC-006, operator): upgrade the fretboard-master pack (`TargetPack.install/2` and commit), run its next wave unattended via `scripts/autonomous`, and record the outcome in this file in the style of 031's T063. Not automatable.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (1)** → **Foundational (2)** → all stories.
- **US1 (3)** and **US2 (4)** are both P1. They share files (`phase_request.ex`, the three actions, the integration test), so run them **sequentially**: US1 first (MVP), then US2.
- **US3 (5)** and **US4 (6)** edit `phase_request.ex` and run after US2, in order T032 → T034.
- **US5 (7)** touches only the pack and `target_pack.ex`. It can run in parallel with US1–US4 once Phase 2 is done.
- **Polish (8)** after the desired stories. T044 and T041–T043 can start once the behavior is settled.

### Within each story

- Tests first, and confirm they fail.
- US1 order: T012 → T013 → (T014, T015, T017, T018, T021) → T016 → T019 → T020 → T022 → T023.
- US2 order: T026 → T027 → T028 → T029.
- US5 order: (T037, T038) → T039 → T040.

### Same-file sequencing (no [P] across these)

- `lib/autonomous/phase_request.ex`: T003 → T027 → T032 → T034.
- `test/autonomous/phase_request_test.exs`: T003 → T025 → T030 → T033.
- `lib/autonomous/actions/run_feature_phase.ex`: T016 → T028. The same applies to the two remediation actions (T017/T018 → T028).
- `test/autonomous/integration/background_wait_test.exs`: T023 → T029.

## Parallel Examples

```text
# US1 tests (different files):
T004 background_marker_test.exs   T005 fixture   T007 pipeline_test   T008 phase_step_test
T009 chunking_test   T010 chunk_runner_test   T011 report_test

# US1 gates after T013:
T017 run_auto_remediation.ex   T018 run_remediation.ex

# US5 alongside anything else:
T037 settings.json   T038 scope_guard.py   T035/T036 tests

# Polish docs:
T041 harness-contract.md   T042 runbook.md   T043 CLAUDE.md   T044 constitution.md
```

## Implementation Strategy

### MVP first (US1)

1. Phase 1 → Phase 2 → Phase 3.
2. **Stop and validate**: SC-001 replay is classified incomplete, retried once, then fails with `{:backgrounded_command, …}`. The full suite is green. This alone removes the fake-success failure mode.

### Incremental delivery

1. US1 (detect) → ship.
2. US2 (timeouts) → ship. Removes the trigger. Together with US1 this is the P1 scope.
3. US3 + US4 (prompt, tool exclusion) → ship.
4. US5 (pack contract 4) → ship. Operators must re-install the pack in permissive targets.
5. Polish, then the SC-006 field run.

## Notes

- The plan flags five deviations from spec text for `/speckit-analyze`: FR-008 pinning built-ins at d ≤ 10 min, FR-005 adding the gate where it does not exist today, FR-009 covering `:whole_list`, FR-011 excluding no reader tool, and FR-013 install refusing invalid JSON. Tasks follow the plan.
- Commit after each task or logical group. Run `rtk git …` per the repo convention.
