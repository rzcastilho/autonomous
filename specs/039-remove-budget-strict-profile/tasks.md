# Tasks: Remove Cost Budget Breaker and Strict Containment Profile

**Input**: Design documents from `/specs/039-remove-budget-strict-profile/`
**Prerequisites**: plan.md, spec.md, research.md (R1–R14), data-model.md, contracts/ (run-start, target-pack, operator-surfaces), quickstart.md

**Tests**: Included — plan.md/research R14 require deleting, rewriting and adding tests (FR-020, SC-001..SC-006).

**Organization**: By user story. Two removals + governance. Every command runs through mise: `mise exec -- mix …` (`warnings_as_errors` is on — a leftover reference to a deleted function fails the build, so **delete callers before definitions** in each story).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallel (different files, no dependency on an incomplete task)
- **[Story]**: US1 (cost informational), US2 (one containment behaviour), US3 (stored data, docs, governance)
- Paths relative to repo root `/Users/castilho/code/github.com/rzcastilho/autonomous`

---

## Phase 1: Setup

**Purpose**: Baseline and inventory before deleting anything.

- [X] T001 Run baseline on `mix.exs` project: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test` and confirm green before touching anything; stop and report if red
- [X] T002 Inventory references in `lib/`, `config/`, `priv/`, `scripts/`, `Dockerfile`, `test/`: run `rtk grep -n -i -E "budget|breaker|reserve|containment|strict|permissive|scope_guard|untrusted_workspace|ORCHESTRATED" lib config priv scripts Dockerfile test` and keep the list as the checklist for the sweep tasks T034 and T051 (no file written)

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Refusal of retired options, the new pure `RuntimeNotice`, and the constitution 7.0.0 amendment — so no later commit ever contradicts a constitution MUST (constitution 6.1.0 III/IV/VII still require the breaker, the strict hook and the gauge). Compile-safe; removes no runtime behaviour yet.

**⚠️ CRITICAL**: Complete before US1/US2.

- [X] T003 [P] Add `:budget_usd` and `:containment_profile` to `@retired_opts` (after existing keys, preserving order) in `lib/autonomous.ex`; `run/1`, `run_spec/2`, `resume/2`, `resume_run/1` already call `reject_retired_opts/1` first; **add** `:ok <- reject_retired_opts(opts)` as the first `with` clause of `continue_run/1` (today it runs `guard_active_run`/`find_parked_run_snapshot`/`preflight_store_capacity` before delegating to `resume/2`, so a retired option with no parked run returns `:no_parked_run` instead — contracts/run-start.md §1 "refused first"); keep feature 035 atomic continue
- [X] T004 [P] Add both keys to `@retired_app_env` in `lib/autonomous/application.ex` so boot raises naming the key
- [X] T005 [P] In `config/runtime.exs` make `AUTONOMOUS_BUDGET_USD` and `AUTONOMOUS_CONTAINMENT_PROFILE` join the retired-env `raise` block (set at all → abort naming it); do not yet delete the old mapping lines (T033 and T046 do)
- [X] T006 [P] In `lib/autonomous/live_config.ex` make `validate_field/2` for `:budget_usd` return a retired-field error naming `budget_usd` (not the generic unknown-field error); nothing applied. In the same edit remove every other budget path in that file so later removal of `Config.budget_usd/0` / `Ledger.set_budget/2` (T032/T033) compiles: the `optional(:budget_usd) => number()` typespec entry, `old_value(:budget_usd)` (calls `Config.budget_usd()`, l.70), the `dispatch({:budget_usd, amount})` clause (calls `Ledger.set_budget/2`, l.115-116), and the moduledoc budget sentence (l.12-13)
- [X] T007 [P] Create pure `lib/autonomous/runtime_notice.ex` with `container_warning/1`: `true -> nil`, `false ->` multi-line string stating run starts **outside** the container, sessions have full tool access and no in-tree deny list, `scripts/autonomous` is the supported runtime, and the run proceeds (contracts/run-start.md §4)
- [X] T008 Render the 039 why-text for `{:retired_option, :budget_usd | :containment_profile}` in `Report.format_reason/1` / preflight rendering in `lib/autonomous/report.ex` ("cost is informational; runs never stop on spend" / "there is one containment behaviour; run in the container") (depends on T003)
- [X] T009 [P] Amend `.specify/memory/constitution.md` 6.1.0 → **7.0.0** (MAJOR) per research R12: III "Container-Bounded Execution", IV "Cost Transparency; Drain, Don't Kill", V (drop breaker exit/remediation clause), VII (drop gauge/breaker, spend plain), I/Tech Stack/Quality (Ledger = cost accumulator; drop breaker test + hook red-team bullets); keep principle numbering; add Sync Impact Report
- [X] T010 [P] `docs/design-constitution.md` §185: "state chip, subject, and run spend persist in the topbar on every view" (no gauge/limit/breaker)
- [X] T011 [P] Test: `test/autonomous/retired_options_039_test.exs` — both keys (and both together, in `@retired_opts` order) refused by `run/1`, `run_spec/2`, `resume/2`, `resume_run/1`, `continue_run/1` with `{:error, {:preflight, [{:retired_option, key}]}}` — including `budget_usd: nil`, and `continue_run/1` with **no** parked run (must still be the retired-option error, not `:no_parked_run`); no run record/Coordinator/worktree created, parked run stays `:parked`; app-env boot raise per key; `LiveConfig` budget error; rendered message names the key (SC-005)
- [X] T012 [P] Test: `test/autonomous/runtime_notice_test.exs` — `container_warning(true) == nil`; `false` text contains the four required statements
- [X] T013 Run `mise exec -- mix test test/autonomous/retired_options_039_test.exs test/autonomous/runtime_notice_test.exs`; green

**Phase 2 implementation notes (2026-10-09)** — interim changes pulled forward so the suite stays green between phases; US1/US2 finish them:
- `config/config.exs` `budget_usd: 74.0` deleted now (the boot guard would refuse it); `Config.budget_usd/0` falls back to `74.0` until T033 deletes it.
- `run/1` captures `RunContext` *after* `reject_retired_opts/1` (an invalid profile value used to raise in `capture/1` first).
- `RunContext.merge/2` no longer carries `budget_usd`/`containment_profile` into merged opts (resume pipes them back into `run/1`, which now refuses them). Side effect until T043: a resumed/continued pre-039 permissive run no longer re-checks the pack — `continue_run_atomic_test` "the incident…" and `mission_control_live_test` "a refused continue flashes the pack-outdated cause verbatim" fail until the always-on pack check lands (T039/T043).
- `TriggerLive.start_opts/1` stops sending `containment_profile` (the select itself goes in T049); `ConfigLive.build_change/1` stops sending `budget_usd` (the fieldset goes in T029); the three budget-edit ConfigLive tests, the profile-lock `continue_run_atomic` cases, and the LiveConfig budget-dispatch tests are already replaced.
- `Report.format_reason/1` also renders `{:preflight, problems}`; `TriggerLive` start errors use it.
- Unrelated, already failing before this feature: `TranscriptMarkupTest` "200 KB renders in under 50 ms" (timing), and an order-dependent store-health leak that sometimes fails `FacadeE2ETest`.

**Checkpoint**: Removed options are refused everywhere and constitution 7.0.0 is in place (commit T009/T010 with or before the first removal); US1 and US2 can proceed (they touch mostly disjoint files, but both edit `lib/autonomous.ex`, `feature_runner.ex`, `coordinator.ex`, `report.ex`, `run_context.ex` — see Dependencies).

---

## Phase 3: User Story 1 — Cost is informational; runs never stop on spend (Priority: P1) 🎯 MVP

**Goal**: No code path halts, drains, refuses or fails on accumulated cost; cost still measured and shown as a plain figure.

**Independent Test**: Coordinator `:runner`-seam test records very large costs; every feature reaches `:done`, final report has no `breaker_tripped` key, `spend` equals the sum (SC-001). Topbar/report show plain spend.

### Tests first (delete / rewrite / add)

- [X] T014 [P] [US1] Rewrite `test/autonomous/ledger_test.exs` for the accumulator only: `record/3`, `spent/1`, `restore/2`, `snapshot/1 == %{committed: float}`; delete all reserve/budget/trip cases (R1)
- [X] T015 [P] [US1] Add "large spend never halts" test to `test/autonomous/coordinator_test.exs` (stub `:runner` records e.g. 10_000.0 per feature across ≥3 features; all `:done`; report has no `breaker_tripped`; `spend` = sum) (SC-001, FR-001)
- [X] T016 [P] [US1] Update `test/autonomous/release_test.exs`: third arg is `blocked?`; delete breaker-named cases, keep the truth table incl. persistence-unwritable block

### Remove the cost-breaker branches (callers before definitions)

- [X] T017 [P] [US1] `lib/autonomous/remediation.ex`: delete `Remediation.next/2` row 4 (`breaker?: true → halt`), renumber rows, drop `breaker?` signal; update `test/autonomous/remediation_test.exs`
- [X] T018 [P] [US1] `lib/autonomous/chunking.ex` + `lib/autonomous/chunk_runner.ex`: delete Row 7 and the `breaker?` signal in `decide_next`; keep `drain?`; update `test/autonomous/chunking_test.exs` and `test/autonomous/chunk_runner_test.exs`
- [X] T019 [P] [US1] `lib/autonomous/session_retry.ex`: `once/2` signal map becomes `%{drain?:}` only; update `test/autonomous/session_retry_test.exs`
- [X] T020 [P] [US1] `lib/autonomous/phase_step.ex`: `retry_allowed?/1` → `not Workers.drain_requested?()`; drop breaker reads; update `test/autonomous/phase_step_test.exs`
- [X] T021 [P] [US1] `lib/autonomous/analyze_runner.ex`: delete `{:halted, :breaker}` path and `breaker?:` signal; update `test/autonomous/analyze_runner_test.exs`
- [X] T022 [P] [US1] `lib/autonomous/interactive_clarify.ex`: delete `on_exit(:breaker)`; keep supersession-drain exit; update its tests
- [X] T023 [US1] `lib/autonomous/feature_runner.ex`: delete phase-boundary breaker halt, clarify tick/answered breaker checks and `exit_for(:breaker)`; keep `Workers.drain_requested?/0` branches beside them; update `test/autonomous/feature_runner_test.exs` and clarify-wait tests (depends on T017–T022)
- [X] T024 [US1] Remaining `breaker_tripped?` callers outside the coordinator/surface layer: `lib/autonomous/chunk_runner.ex`, `lib/autonomous/analyze_runner.ex`, `lib/autonomous/phase_step.ex`, `lib/autonomous/feature_runner.ex` (confirm T018/T020/T021/T023 removed every call). Actions (`lib/autonomous/actions/*.ex`) only call `Ledger.record/3` and are untouched. **Gate**: `rtk grep -n "breaker_tripped" lib` lists only `ledger.ex`, `coordinator.ex`, `report.ex`, `run_context.ex`, `lib/autonomous.ex`, `web/components/layouts/app.html.heex`, `web/live/config_live.ex`, `web/live/run_detail_live.ex` — those go in T025–T029 and T033
- [X] T025 [US1] `lib/autonomous/release.ex`: rename third arg `breaker_tripped?` → `blocked?` (arity unchanged); `lib/autonomous/coordinator.ex`: `blocked?/1` = `store_unwritable?(state)` only; drop `breaker_tripped` key from `status/1` and `build_report`; keep drain/park logic (depends on T023, T024)

### Operator surfaces (cost = plain figure)

- [X] T026 [P] [US1] `lib/autonomous/report.ex`: delete `[BREAKER TRIPPED]` line and `breaker_tripped` tally in `format_status/1`/final report; keep spend line; **keep** historical `{:needs_human, :breaker}` renderer (R3)
- [X] T027 [P] [US1] `lib/autonomous/coordinator_probe.ex` drop `ledger/2`; `lib/autonomous/console_projection.ex` drop ledger probe; `lib/autonomous/console_read_model.ex` `merge/3` → `merge/2`; update their tests (R11)
- [X] T028 [US1] Web: delete `cost_gauge/1` from `lib/autonomous/web/components/core_components.ex`; in `lib/autonomous/web/components/layouts.ex` (+ `app.html.heex`) show run spend as one plain mono USD figure from `Ledger.snapshot().committed`, delete breaker chip; keep `Process.whereis(Ledger)` health dot
- [X] T029 [P] [US1] `lib/autonomous/web/config_diff.ex` drop budget clauses and `parse_cents/1`; `lib/autonomous/web/live/config_live.ex` delete budget fieldset/slider; `lib/autonomous/web/live/trigger_live.ex` delete Budget row; `lib/autonomous/web/start_confirm.ex` drop budget line; other LiveViews (`run_detail_live.ex`, `mission_control_live.ex`, `pipeline_dag_live.ex`, `escalations_live.ex`) drop budget/breaker references — **keep** `clarify_outcome_label(:breaker)` as historical
- [X] T030 [P] [US1] `priv/static/assets/console.css`: delete gauge and `.breaker-chip` rules (no token changes)
- [X] T031 [P] [US1] Doc wording only: `lib/autonomous/cost.ex`, `telemetry.ex`, `workers.ex`, `store/health.ex` — remove budget/breaker prose
- [X] T032 [US1] `lib/autonomous/ledger.ex`: shrink to `record/3`, `spent/1`, `restore/2`, `snapshot/1 → %{committed: float}`; delete `reserve/2`, `set_budget/2`, `breaker_tripped?/1`, `default_budget/0` and all budget state; update `lib/autonomous/application.ex` Ledger child comment (depends on T025 and T026–T030: every surface must stop calling `breaker_tripped?`, `set_budget` and budget/reserved snapshot fields first; T006 already cleared `live_config.ex`)
- [X] T033 [US1] `lib/autonomous/run_context.ex`: remove `budget_usd` from struct, `@keys`, `capture/1`, `to_map/1`, `from_map/1` (read tolerant of the stored key); remove `Config.budget_usd/0` in `lib/autonomous/config.ex`; delete `budget_usd` default in `config/config.exs`; delete `AUTONOMOUS_BUDGET_USD` mapping in `config/runtime.exs`; fix `lib/autonomous.ex` (`set_budget`, budget capture, docs) (depends on T032)
- [X] T034 [US1] Delete/modify remaining breaker & budget test cases: `rtk grep -ln -i -E "breaker|budget|reserve" test` and fix each (coordinator, run_spec, resume_run, ledgerlite_dryrun breaker drill, live_config budget, console budget/gauge/breaker cases) per research R14
- [X] T035 [US1] Run `mise exec -- mix format && mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`; fix until green. Confirm `test/autonomous/cost_test.exs` (estimate fallback when a session reports no cost — US1 scenario 4, FR-003) stays green. Verify quickstart §2–§3 snippets

**Phase 3 implementation notes (2026-10-09)**:
- The dead `ledger` argument was threaded out of `FeatureRunner.loop/12` (was 13), `run_step`, `PhaseStep`, `AnalyzeRunner`/`ChunkRunner` ctx; `FeatureRunner` still hands the Ledger to `InitFeature` for cost recording. `Ledger.record/3` keeps its (ignored) `ref` argument so the actions' call shape is unchanged.
- Topbar spend is `<span class="topbar-spend" data-spend>` (new CSS rules use existing tokens only); the design guard's inline-style allowlist (the two gauge fill styles) is now empty — any `style=` fires.
- `RunSettingsView` drops both legacy keys now (`@dropped ~w(budget_usd containment_profile)`); `ConfigDiff.parse_cents/1` deleted with the budget field.
- Interim (until US2): `continue_run_atomic_test` "the incident…" and `mission_control_live_test` "a refused continue flashes the pack-outdated cause verbatim" still fail (always-on pack check lands in T043); the failed incident test can leave a parked run that makes `SupersessionDrainTest` order-dependent. Plus the known `TranscriptMarkupTest` timing flake.

**Checkpoint**: US1 complete and independently testable — MVP. Drain/supersession tests (026) untouched and green (FR-019).

---

## Phase 4: User Story 2 — One containment behaviour (Priority: P1)

**Goal**: Former `permissive` is the only behaviour; no profile anywhere; pack contract 6 enforced every run; non-container start warns and proceeds.

**Independent Test**: Run with no profile setting → sessions get `bypass_permissions` + full tool set; preflight accepts a contract-6 pack and rejects older; no surface mentions a profile; `strict` cannot be requested.

### Tests first

- [X] T036 [P] [US2] Rewrite `test/autonomous/phase_request_test.exs`: every phase/remediation/describe session = `:bypass_permissions`, full `@allowed_tools`, `~w(Agent Task ScheduleWakeup Monitor)` disallowed; launch env has shell timeouts (+ agent-root markers when advertised) and **no** `AUTONOMOUS_ORCHESTRATED` / `AUTONOMOUS_CONTAINMENT_PROFILE`
- [X] T037 [P] [US2] Rewrite `test/autonomous/target_pack_test.exs`: `verify/2` takes no `:profile`; always-on contract-6 check yields `{:pack_outdated, path, hint}` (hint contains `contract 6`, `TargetPack.install/2`, "commit the result") for missing/old marker, registered `scope_guard.py` hook, `permissions.deny`, committed `scope_guard.py`; `install/2` writes `autonomous-pack.json`, drops stale hook registration and file, idempotent, never clobbers constitution
- [X] T038 [P] [US2] Rewrite `test/autonomous/untrusted_gate_test.exs` to warn-only (no `:untrusted_workspace` failure produced); update agent-root tests (`test/autonomous/agent_root*_test.exs`) — no `scope_guard[` denial filter, markers/prompt note/install logging still tested (FR-015)
- [X] T039 [P] [US2] Rewrite `test/autonomous/continue_run_atomic_test.exs:278-340` pack-lag incident case to the always-on pack check; delete profile-lock cases from resume/continue tests (`{:containment_profile_locked, _}`)

### Implementation

- [X] T040 [US2] `lib/autonomous/phase_request.ex`: drop `:containment` option, `strict_permissions/1` and per-phase table; rename `@permissive_allowed_tools` → `@allowed_tools`; stop merging `Containment.session_env/1` in `session_metadata/…` (R7)
- [X] T041 [P] [US2] Remove `containment` from `lib/autonomous/describe.ex`, `lib/autonomous/feature_agent.ex`, `lib/autonomous/actions/init_feature.ex`, `run_feature_phase.ex`, `run_auto_remediation.ex`, `run_remediation.ex` (struct field, args, threading) (depends on T040)
- [X] T042 [US2] `lib/autonomous/feature_runner.ex`: drop containment threading and the `:untrusted_workspace` clause in `remediation_failure_reason/…`; `lib/autonomous/pipeline.ex`: delete the `:untrusted_workspace` gate; `lib/autonomous/chunking.ex`: delete Row U; `lib/autonomous/workspace_trust.ex`: `settle/…` loses profile arg, always warns; keep detection/`Collector` and `Report.format_reason({:untrusted_workspace, …})` historical renderer (R8)
- [X] T043 [US2] `lib/autonomous/target_pack.ex`: remove `:profile` option, `@permissive_min_contract`, `@agent_root_min_contract`, `contract_of/1`, `parse_contract/1`, `agent_root_warning/1`, `:pack_below_agent_root_contract`; add always-on `check_pack_contract/1` reading the committed tree (`git show HEAD:…`) per contracts/target-pack.md; `install/2` writes marker, deletes stale `hooks/scope_guard.py` (and empty `hooks/`)
- [X] T044 [P] [US2] Pack files: create `priv/target_pack/.claude/autonomous-pack.json` (`{"contract": 6}`); remove `hooks` key from `priv/target_pack/.claude/settings.json`; **delete** `priv/target_pack/.claude/hooks/scope_guard.py`; delete `test/autonomous/scope_guard_test.exs`
- [X] T045 [P] [US2] `lib/autonomous/agent_root.ex`: delete `denied?/1` scope_guard filter and `sudo_allowed/1` grammar references; `priv/prompts/agent_root.md` line 6 → guidance only ("never remove, purge or upgrade")
- [X] T046 [US2] `lib/autonomous/run_context.ex`: remove `containment_profile` (struct, `@keys`, `capture/1`, `to_map/1`, `from_map/1` tolerant on read); `lib/autonomous/config.ex`: delete `containment_profile/0`; `config/config.exs` / `config/runtime.exs`: delete profile defaults/mapping (retired raise from T005 stays)
- [X] T047 [US2] `lib/autonomous.ex`: delete `preflight_containment`, `guard_containment_profile/2`, `warn_agent_root_pack`, profile arg of `preflight_stacked/2`, PR-body containment note; call `TargetPack.verify/2` without profile on run/run_spec/resume/continue; add container notice step (`RuntimeNotice.container_warning(ContainerGuard.containerized?())` → `Logger.warning/1`, never an error) after pack verify (contracts/run-start.md §3). Input is `ContainerGuard.containerized?/0` unchanged (`required? and marker == "1"`): it is deliberately false under the `:test` config even inside the image, so every test that starts a run sees the warning — tests asserting on captured logs must match with `=~`, not equality, and must not treat the warning as a failure; `lib/autonomous/coordinator.ex`: drop `containment_profile` key from status/report/state
- [X] T048 [US2] Delete `lib/autonomous/containment.ex` and `test/autonomous/containment_test.exs`; `rtk grep -rn "Containment\b" lib test` must be empty
- [X] T049 [P] [US2] `lib/autonomous/report.ex` drop containment line in `format_status/1`; `lib/autonomous/web/agent_root_view.ex` → `:hidden | :available`; `lib/autonomous/web/live/config_live.ex` delete Containment fieldset and agent-root `:pack_outdated` warning; `trigger_live.ex` delete profile select/note/`set_containment_profile` event; `run_detail_live.ex` delete Containment block; `layouts.ex` delete containment chip; `lib/autonomous/web/start_confirm.ex` add container notice line when not containerized; `lib/autonomous/web/run_settings_view.ex` `@dropped ~w(budget_usd containment_profile)` (R10)
- [X] T050 [P] [US2] `priv/static/assets/console.css`: delete `.containment-chip` rules; confirm `mise exec -- mix test test/autonomous/web/design_contract_test.exs` green
- [X] T051 [US2] Delete/modify remaining profile test cases: `rtk grep -ln -i -E "containment|permissive|strict|scope_guard" test` and fix each; update `test/support` fixtures that install the old pack
- [X] T052 [US2] Run `mise exec -- mix format && mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`; green. Walk quickstart §4–§6

**Phase 4 implementation notes (2026-10-09)**:
- Resume/continue inject their own `:executor`, which made `run_stacked/4` treat them as seam-injected and skip `TargetPack.verify/2`. The three resume strategy injectors now also set `:verify_target`, so the contract-6 check runs for every run, resume, continue and `run_spec/2` at the same point as before (`preflight_stacked/1`, ahead of `begin_continue/1` — a refused continue stays parked, feature 035). Only a caller-supplied `:runner`/`:executor` skips it.
- `TargetPack.verify/2` validates its options (`Keyword.validate!/2`): passing the removed `:profile` raises. `check_pack_contract/2` reads the committed tree by default; `check_git: false` (tests) reads the working tree. The first failing check is reported (marker → settings → stale hook file).
- `WorkspaceTrust.settle/2` (was `/3`) records the observation on the result and warns; `signal_or_warn/2`, `apply_to/2` and `PhaseResult.reset_untrusted_workspace/2` are deleted with the gate (Pipeline, Chunking Row U, PhaseStep no-retry clause, AnalyzeRunner/FeatureRunner remediation reasons).
- `Describe.run/3` lost its options argument (it only carried `:containment`).
- The container notice is emitted once per start from `preflight_stacked/1` (seam-injected runs too, since the test config is never "containerized"); the Trigger page shows it as `[data-container-notice]` — rendered in `TriggerLive`, not `StartConfirm` (which stays a pure click state machine).
- Hand-built fixture repos in ~15 test files now write `.claude/autonomous-pack.json` (`{"contract": 6}`) instead of an empty `hooks/scope_guard.py`; two publish-only `continue_run/1` tests in `resume_test.exs` switched to a scaffolded repo since a seamless continue now verifies the pack.
- Suite: 2149 tests, only the known `TranscriptMarkupTest` 50 ms timing flake fails.

**Checkpoint**: US1 and US2 both complete. One behaviour, informational cost.

---

## Phase 5: User Story 3 — Stored data, docs, governance consistent (Priority: P2)

**Goal**: Legacy records load; constitution, docs and scripts agree with behaviour so later automated runs are not steered by stale rules.

**Independent Test**: Pre-039 run record opens in Report/Run Detail/resume/continue without error and never reinstates behaviour; doc sweep (quickstart §8) finds only allowed hits.

- [X] T053 [P] [US3] Test: `test/autonomous/legacy_records_039_test.exs` — settings map with `"budget_usd"`/`"containment_profile"`, terminal reason `{:needs_human, :breaker}`, clarify round `outcome: :breaker`, and `{:untrusted_workspace, …}` load through `Report`, Run Detail (keys hidden, `:breaker` labelled), `resume/2`, `continue_run/1` without error and without re-parking or profile lock (SC-004); confirm `Writer.close_clarify_round` still accepts `:breaker`
- [X] T054 [P] [US3] Test: sweep test asserting no `budget`/`containment_profile` in `RunContext.keys/0`, console form fields, and `Config` exports (SC-002)
- [X] T055 [P] [US3] Rewrite `docs/enforcement.md` (container + per-phase full set + pack contract 6), `docs/runbook.md` ("Cost breaker" → "Cost reporting"; remove profile sections; add outdated-pack reinstall steps), `docs/container.md`, `docs/workflow.md` (remove LED/BRK mermaid nodes), `docs/harness-contract.md` (touch), `README.md`; leave historical docs (`autonomous-implementation-plan.md`, `phase7-ledgerlite-runbook.md`, `control-plane-design-reference/`, earlier `specs/`)
- [X] T056 [P] [US3] Update `CLAUDE.md` (repo): remove budget-breaker/strict-vs-permissive/scope_guard/sudo-grammar prose, describe Ledger as accumulator, pack contract 6, `RuntimeNotice`, feature 039 summary
- [X] T057 [P] [US3] Scripts: `scripts/autonomous` (remove "budget per instance" warning ~l.239, fix `--agent-root` help strict wording), `scripts/container-entrypoint.sh` (remove budget warnings ~l.311-312, strict wording in `say`/comments), `Dockerfile` (sudoers comment)
- [X] T058 [US3] `scripts/container-smoke.sh`: delete strict-hook checks in `us1` (~150-162) and `us5` (~531-535), delete whole `us-trust-hook` subcommand and its usage text; keep `trust`, `sysdeps`, others; none sets a budget or `AUTONOMOUS_CONTAINMENT_PROFILE`
- [X] T059 [US3] Run the doc sweep from quickstart §8 (`rtk grep -n -i -E "budget|breaker|strict|permissive|containment_profile" lib config priv scripts docs/runbook.md docs/enforcement.md docs/container.md docs/workflow.md README.md CLAUDE.md .specify/memory/constitution.md`); only allowed hits remain (historical renderers, retired-setting refusals, constitution history, unrelated uses)

**Checkpoint**: All stories complete.

---

## Phase 6: Polish & Cross-Cutting

- [X] T060 `mise exec -- mix format --check-formatted && mise exec -- mix compile --warnings-as-errors && mise exec -- mix test` — full suite zero warnings (FR-020, SC-006)
- [X] T061 [P] `mise exec -- mix test test/autonomous/web/design_contract_test.exs` — guard green
- [X] T062 [P] Supersession/drain regression: run feature-026 tests (`rtk grep -ln "drain" test` → run them) — unchanged and green (FR-019)
- [X] T063 Container verification by hand (needs Docker): `scripts/autonomous build --agent-root`, `scripts/container-smoke.sh`, `... sysdeps`, `... trust`; record outcome in this file as a note (per 038 precedent)
- [X] T064 Walk `specs/039-remove-budget-strict-profile/quickstart.md` §1–§8 end-to-end; record deviations
- [X] T065 Update `~/.claude/projects/-Users-castilho-code-github-com-rzcastilho-autonomous/memory/MEMORY.md` (+ a memory file) only if a new durable lesson emerged (e.g. pack contract 6 marker location)

**Phase 5–6 notes (2026-10-09)**:
- Suite (T060): 2158 tests, 2 failures in the full run — the known `TranscriptMarkupTest` 50 ms timing flake, and `ConsoleProjectionResilienceTest` "stalled coordinator…" (order-dependent: the app's global `ConsoleProjection` broadcasts `coordinator: nil` reconciles on the shared topic; the `refute_received` now matches only the stub's marker). Design guard green; the 22 drain-touching test files (508 tests) green (T061/T062).
- Container (T063): `scripts/autonomous build --agent-root` OK; `scripts/container-smoke.sh` (all) 57 PASS, then `sysdeps` re-run all PASS. SKIPs: agent-auth (`SMOKE_AGENT` unset), emulator (no `/dev/kvm`), host adb, `--apt` packages. On a macOS host the script needs GNU `timeout` and util-linux `script -qec` (`pty_feed`); run with a PATH shim (uutils `coreutils` via mise linked as `timeout`, and a `script` wrapper mapping `-qec CMD FILE` → BSD `script -q FILE sh -c CMD`). Fixed a false FAIL in `sysdeps` (037): the `apt-get remove` probe ran in a fresh container where the package was not installed (exit 0); install + remove now share one container and the guard refuses (`E: … remove is disabled`, exit 100).
- Quickstart (T064): §2–§4 verified under `MIX_ENV=test mix run` (dev boot refuses on the host by design — ContainerGuard); after `install/2` + commit the only remaining verify problem on a scratch target is the template constitution, as expected. §5/§6 covered by LiveView tests and the warning in test logs; §7 above; §8 sweep: only allowed hits.

---

## Dependencies & Execution Order

- **Phase 1 → Phase 2 → Phases 3 & 4 → Phase 5 → Phase 6.**
- US1 and US2 are logically independent but **both edit** `lib/autonomous.ex`, `feature_runner.ex`, `coordinator.ex`, `report.ex`, `run_context.ex`, `chunking.ex`, `config.ex`, `console.css`, LiveViews. Run **sequentially (US1 then US2)** to avoid conflicts; [P] marks only apply within a phase.
- Within US1: T014–T016 and T017–T022 (all [P]) → T023 → T024 (gate) → T025 → surfaces T026–T031 ([P] except T028) → T032 (Ledger shrink, needs every caller gone) → T033 → T034–T035 last.
- Within US2: T036–T039 tests → T040 → T041 → T042 → T043/T044/T045 → T046 → T047 → T048 → T049/T050 → T051 → T052.
- Constitution amendment (T009/T010) is in Phase 2, ahead of any removal. US3 needs US1+US2 behaviour final (docs describe it); T053–T054 tests can start once both land.

### Parallel example (US1 breaker branches)

```text
T017 remediation.ex   T018 chunking.ex+chunk_runner.ex   T019 session_retry.ex
T020 phase_step.ex    T021 analyze_runner.ex              T022 interactive_clarify.ex
```

## Implementation Strategy

- **MVP**: Phases 1–3 (US1). Stop and validate: large spend never halts; plain spend shown.
- **Incremental**: add US2 (profile + pack contract 6), then US3 (legacy read, docs, scripts); constitution 7.0.0 already landed in Phase 2.
- Project rule: this is a spec-driven semantic change — constitution amendment ships in this feature (T009), not as a side edit.
- Commit per task group (e.g. after T013 — includes constitution, T035, T052, T059). Prefix git with `rtk`.

## Notes

- Keep historical renderers: `:breaker` clauses (`Report.format_reason/1`, `RunDetailLive.clarify_outcome_label/1`, `Writer.close_clarify_round` guard) and `{:untrusted_workspace, …}`.
- Store stays at schema v7; no migration.
- `Release.next/3` keeps arity 3 (persistence block must survive).
