# Tasks: Container System Packages

**Input**: Design documents from `/specs/037-container-system-packages/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/ (build-options, container-start, scope-guard-exception, session-request), quickstart.md

**Tests**: Included. The plan specifies a hermetic suite (red-team matrix rows 1–20, `AgentRoot`, `PhaseRequest` byte-identical path, `TargetPack` thresholds, real entrypoint step with a stub `sudo`). Run Elixir via `mise exec -- mix test …`; `warnings_as_errors` is on. Docker checks are opt-in smoke (`scripts/container-smoke.sh sysdeps`).

**Organization**: Grouped by user story. US1 = build-time `--apt` packages (MVP, fixes the mod-player incident alone). US2 = opt-in agent root with the strict `sudo apt` exception. US3 = docs, smoke, console row, CLAUDE.md.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies on incomplete tasks)
- **[Story]**: US1–US3 from spec.md

---

## Phase 1: Setup

**Purpose**: Land the constitution change first so code arrives against a constitution that permits it (research R11, Complexity Tracking).

- [X] T001 Amend `.specify/memory/constitution.md` 6.0.2 → 6.1.0 (MINOR, FR-017): add the Principle III `strict` bullet from research.md R11 (package-manager exception requires in-container marker + verified agent-root marker; only index refresh / install / package-database queries; removal, upgrade, local package files, command-executing options and every other privileged command stay denied; relies on the container as outer boundary). Prepend a Sync Impact Report. Check dependent templates under `.specify/templates/` for stale references.

---

## Phase 2: Foundational (blocking prerequisites)

**Purpose**: Test-environment hygiene that every hook/request test depends on.

- [X] T002 Extend `@env_clear` in `test/autonomous/scope_guard_test.exs` with `AUTONOMOUS_CONTAINER` and `AUTONOMOUS_AGENT_ROOT` (the suite runs inside the image where `AUTONOMOUS_CONTAINER=1`; research R12). Existing tests must stay green unchanged.
- [X] T003 [P] Audit `test/autonomous/phase_request_test.exs` and list the "strict request is byte-identical" assertions that must pin `agent_root: false` (R12). The option does not exist until T021, so the edit itself lands there.

**Checkpoint**: Constitution amended, tests hermetic.

---

## Phase 3: User Story 1 — Operator declares system packages at image build (Priority: P1) 🎯 MVP

**Goal**: `scripts/autonomous build --apt "libasound2-dev pkg-config"` installs the packages into both dev and release images; empty = no-op; invalid names rejected before any build; unknown package fails the build naming it.

**Independent Test**: Quickstart §2–§3: bad token ⇒ exit 2 with no `docker` call; build with two packages ⇒ `dpkg -s` passes in dev and release; no-option build adds no `sudo` and no `/etc/autonomous`.

### Tests for User Story 1

- [X] T004 [P] [US1] Add wrapper tests (extend the existing wrapper/`scripts/autonomous` test file if one exists, else create `test/autonomous/container_build_options_test.exs`) running `scripts/autonomous` with a stub `docker` on `PATH`: (a) `build --apt 'pkg-config; rm -rf /'` exits 2, stderr `autonomous: invalid package name ';'`, stub never invoked; (b) `build --apt "a-b libc6-dev" --apt c++` accumulates and passes `EXTRA_APT_PACKAGES="a-b libc6-dev c++"`; (c) comma separation; (d) `--apt ""` ⇒ empty arg; (e) `--apt` on a non-`build` command ⇒ `unknown option`, exit 2; (f) usage text lists `--apt`. Contract: build-options.md.

### Implementation for User Story 1

- [X] T005 [US1] Implement `--apt <list>` in `scripts/autonomous`: repeatable, whitespace/comma split, validate every token against `^[a-z0-9][a-z0-9+.-]+(:[a-z0-9-]+)?(=[A-Za-z0-9.+~:-]+)?$` before any `docker` call (first bad token ⇒ stderr `autonomous: invalid package name '<token>'`, exit 2), accepted only with `build`, export `EXTRA_APT_PACKAGES` (tokens joined by one space) to compose, list the option in usage.
- [X] T006 [P] [US1] Add `EXTRA_APT_PACKAGES: "${EXTRA_APT_PACKAGES:-}"` to `build.args` of both `dev` and `release` in `compose.yaml`.
- [X] T007 [P] [US1] In `Dockerfile`, add at the end of the `base` stage (after the Android block) `ARG EXTRA_APT_PACKAGES=""` and a block that, only when non-empty, runs `apt-get update`, `apt-get install -y --no-install-recommends $EXTRA_APT_PACKAGES`, writes `/etc/autonomous/apt-packages` (one name per line), and cleans apt lists. Empty ⇒ no-op, no file added (FR-002). Install failure must fail the build (no `|| true`).
- [X] T008 [US1] Manual verification per quickstart §3 (build with packages, unknown-package failure names it, no-option image has no `sudo`/`/etc/autonomous`); record result in `specs/037-container-system-packages/quickstart.md` notes if findings differ.

**Checkpoint**: US1 deliverable — mod-player incident fixable by declaring packages. Strict containment untouched.

---

## Phase 4: User Story 2 — Agent installs a missing package itself (Priority: P2)

**Goal**: Image built with `--agent-root` carries passwordless `sudo` for any uid; entrypoint advertises `AUTONOMOUS_AGENT_ROOT=1` only after `sudo -n true` succeeds; strict hook (pack contract 5) allows only `sudo apt-get|apt update|install` / dpkg queries when both markers present; implement/converge prompts tell the agent; permissive and marker-less behaviour unchanged.

**Independent Test**: Hermetic: red-team rows 1–20 pass, `agent_root: false` requests byte-identical, entrypoint `agent-root` subcommand with stub `sudo` prints `1`/`0` correctly. Docker: quickstart §4.

### Tests for User Story 2

- [X] T009 [P] [US2] Extend `test/autonomous/scope_guard_test.exs` with contract-5 rows 1–20 from contracts/scope-guard-exception.md (origin × profile × markers × command shape), each pinning `AUTONOMOUS_ORCHESTRATED`, `AUTONOMOUS_CONTAINMENT_PROFILE`, `CLAUDE_CODE_ENTRYPOINT`, `AUTONOMOUS_CONTAINER`, `AUTONOMOUS_AGENT_ROOT`; plus `--contract` prints `5`. Detail strings: `sudo` without markers, `sudo (agent root allows only apt-get/apt update|install and dpkg queries)` with them. Must fail before T015.
- [X] T010 [P] [US2] Create `test/autonomous/agent_root_test.exs`: `advertised?/1` (true only for `AUTONOMOUS_CONTAINER=1` and `AUTONOMOUS_AGENT_ROOT=1`), `session_env(false) == %{}` / `session_env(true)` map, `prompt_note(false) == ""` / `prompt_note(true)` starts with `"\n\n"` and equals `Prompts.load("agent_root")`, `installs/1` over `PhaseResult` fixtures (single install, chained `update && install`, `-y --no-install-recommends` options skipped as packages, denied call with `scope_guard[` result skipped, non-install sudo ignored, no sudo ⇒ `[]`), `log_installs/3` emits one `Logger.info` per install (use `ExUnit.CaptureLog`) with the exact line format from session-request.md.
- [X] T011 [P] [US2] Extend `test/autonomous/phase_request_test.exs`: `agent_root: false` ⇒ env map and implement/converge/other prompts byte-identical to today; `agent_root: true` ⇒ env gains `AUTONOMOUS_CONTAINER=1` + `AUTONOMOUS_AGENT_ROOT=1`, note appended to `:implement` (any scope incl. `nil`) and `:converge` after the scope/headless rule and before resume/clarify/background-retry blocks, other phases and remediation prompts unchanged, permissions/tools unchanged; both `build/3` and `build_remediation/3`.
- [X] T012 [P] [US2] Extend `test/autonomous/target_pack_test.exs`: `check_pack_contract` for permissive passes at committed contract ≥ 4 and no `permissions.deny` (result shape unchanged); `install/2` writes contract 5; `agent_root_warning/1` returns `:ok` at ≥ 5, `{:warning, {:pack_below_agent_root_contract, 4, 5}}` at 4, `:unknown` when git show/probe fails.
- [X] T013 [P] [US2] Create `test/autonomous/container_agent_root_step_test.exs` in the style of `container_trust_step_test.exs`: run the real `scripts/container-entrypoint.sh agent-root` with a stub `sudo` on `PATH` — (a) no `sudo` ⇒ stdout `AUTONOMOUS_AGENT_ROOT=0`, no stderr; (b) stub exits 0 ⇒ `AUTONOMOUS_AGENT_ROOT=1` and the "agent root: available" stderr line; (c) stub exits 1 ⇒ `=0` plus the "not advertised" warning naming the uid; (d) pre-set `AUTONOMOUS_AGENT_ROOT=1` in env with no sudo ⇒ still `=0` (inherited value never honoured). Exit 0 in all cases.

### Implementation for User Story 2

- [X] T014 [P] [US2] Add `ARG WITH_AGENT_ROOT=0` and a `base`-stage block in `Dockerfile` (after the T007 block): when `1`, install `sudo`; write `/etc/sudoers.d/autonomous-agent-root` (mode `0440`, `Defaults env_keep += "DEBIAN_FRONTEND"`, `ALL ALL=(root) NOPASSWD: ALL`, validated with `visudo -cf`) and `/etc/apt/apt.conf.d/99autonomous-no-remove` (`APT::Get::Remove "false";`). `0` ⇒ no-op, no `sudo` binary (FR-006).
- [X] T015 [US2] Update `priv/target_pack/.claude/hooks/scope_guard.py`: `PACK_CONTRACT = 5`; add `agent_root_active(env)`; add `sudo_allowed(cmd)` implementing the closed grammar (shlex posix + `punctuation_chars=True`, reject backticks/`$(`/`<(`/`>(`, parens, shlex errors, `sudo` not at segment start, segment grammar for `apt-get|apt update|install`, `apt list|show|policy`, `dpkg` query flags, option allowlist, package-name regex); in the strict Bash loop skip rule `bash_sudo` only when `agent_root_active and sudo_allowed(cmd)`; extended denial detail with markers; all other rules and the redirect-outside-worktree check unchanged; fail closed on any parse problem. Depends on T001.
- [X] T016 [P] [US2] Add `--agent-root` to `scripts/autonomous`: accepted only with `build`, exports `WITH_AGENT_ROOT=1` to compose, usage lists it, `--android` dual meaning untouched. Extend T004's wrapper test file with `--agent-root` cases (misplaced option ⇒ `unknown option`, exit 2; build passes `WITH_AGENT_ROOT=1`).
- [X] T017 [P] [US2] Add `WITH_AGENT_ROOT: "${WITH_AGENT_ROOT:-0}"` to `build.args` of `dev` and `release` in `compose.yaml`. No runtime `environment:` entry.
- [X] T018 [US2] Add the `agent_root` step and `agent-root` subcommand to `scripts/container-entrypoint.sh` per contracts/container-start.md: always `unset AUTONOMOUS_AGENT_ROOT` first; if `sudo` on PATH and `sudo -n true` succeeds ⇒ export `=1` and print the "available" stderr line, if it fails ⇒ warning line with uid, no export; no `sudo` ⇒ silent. Position after `trust_workspaces`, before warnings; runs for `shell`/`console`/`release`, not `segment`/`identity`/`test`. Subcommand runs only the step and prints exactly `AUTONOMOUS_AGENT_ROOT=1|0`, exit 0.
- [X] T019 [P] [US2] Create `priv/prompts/agent_root.md` with the exact text from session-request.md and embed it in `lib/autonomous/prompts.ex`.
- [X] T020 [US2] Create `lib/autonomous/agent_root.ex` (`@moduledoc`, `advertised?/1` as the only env read defaulting to `System.get_env()`, `session_env/1`, `prompt_note/1`, `installs/1`, `log_installs/3`) per session-request.md and R8. Depends on T019.
- [X] T021 [US2] Add the `:agent_root` option (default `AgentRoot.advertised?()`) to `PhaseRequest.build/3` and `build_remediation/3` in `lib/autonomous/phase_request.ex`: merge `AgentRoot.session_env/1` into the launch env and append `AgentRoot.prompt_note/1` to the `:implement` and `:converge` prompts at the placement given in session-request.md. Then apply the T003 audit (pin `agent_root: false`). Depends on T020.
- [X] T022 [US2] In `lib/autonomous/target_pack.ex`: set `@pack_contract 5`, add `@permissive_min_contract 4` and `@agent_root_min_contract 5`, change the permissive check to `≥ 4`, add `agent_root_warning/1` (reads the committed hook; `:unknown` on probe failure). Depends on T015.
- [X] T023 [US2] In `lib/autonomous.ex`, call `TargetPack.agent_root_warning(Config.repo())` from `preflight_stacked/2` and `spec_run_opts/3` only when `AgentRoot.advertised?()` and the profile is `"strict"`; on warning emit the single `Logger.warning` text from session-request.md and still start the run; skip under test-mode `:runner`/`:executor` seams. Depends on T022, T020.
- [X] T024 [P] [US2] Call `AgentRoot.log_installs(feature, phase, result)` after each session in `lib/autonomous/actions/run_feature_phase.ex`, `lib/autonomous/actions/run_remediation.ex`, `lib/autonomous/actions/run_auto_remediation.ex`, and per chunk in `lib/autonomous/chunk_runner.ex`, alongside the existing branch-drift/untrusted-workspace post-processing. No store writes. Add one assertion per site (extend each site's existing test) that an allowed install logs and a denied one does not. Depends on T020.
- [X] T025 [US2] Run `mise exec -- mix test` on the files from T009–T013 and fix until green; run `python3 priv/target_pack/.claude/hooks/scope_guard.py --contract` ⇒ `5`.

**Checkpoint**: US2 deliverable — agent root works end to end hermetically; docker verification in quickstart §4.

---

## Phase 5: User Story 3 — Operator can find, verify and reason about it (Priority: P3)

**Goal**: Docs, runbook recovery, smoke check, console visibility, CLAUDE.md.

**Independent Test**: `container-smoke.sh sysdeps` passes/fails per image variant; Configuration page row appears only when advertised; docs follow-through under 10 minutes (SC-005).

### Tests for User Story 3

- [X] T026 [P] [US3] Create `AgentRootView` tests (pure, in `test/autonomous/web/agent_root_view_test.exs` or beside the existing config-view tests): `state(false, _) == :hidden`, `state(true, :ok) == :available`, `state(true, {:warning, {:pack_below_agent_root_contract, 4, 5}}) == {:pack_outdated, 4}`, unknown pack ⇒ `{:pack_outdated, :unknown}`. Add a `ConfigLive` render test: not advertised ⇒ page unchanged (no "Agent root"); advertised ⇒ row with `available — strict allows sudo apt-get/apt install`; outdated ⇒ plus warning text. Must also pass `design_contract_test.exs`.

### Implementation for User Story 3

- [X] T027 [US3] Create the pure view helper `AgentRootView.state/2` (data-model.md) and add the "Agent root" row to `lib/autonomous/web/live/config_live.ex`, computed from `AgentRoot.advertised?()` and `TargetPack.agent_root_warning(Config.repo())`. Existing classes/tokens only, no `inspect/1`, no new literals. Depends on T020, T022.
- [X] T028 [P] [US3] Add a `sysdeps` section to `scripts/container-smoke.sh` (and to `all`) per research R10: runs as `--user $(id -u):$(id -g)` against `${SMOKE_IMAGE:-autonomous-dev:local}`; `dpkg -s` for each entry of `/etc/autonomous/apt-packages` (SKIP when no manifest); if `sudo` exists: `sudo -n true`, entrypoint `agent-root` prints `AUTONOMOUS_AGENT_ROOT=1`, `sudo -n apt-get update && install` of `${SMOKE_SYSDEPS_PROBE:-pkg-config}` succeeds, `sudo -n apt-get remove -y` is refused; if absent: `command -v sudo` fails and `agent-root` prints `=0`.
- [X] T029 [P] [US3] Add a "System packages" section to `docs/container.md`: `--apt` (validation, repeatable, rebuild drops list, release+dev), `--agent-root` (when to enable, any-uid sudoers, start probe, no-new-privileges caveat), pack contract 5 reinstall step, smoke check, "install lasts only for this container — promote logged packages to `--apt`".
- [X] T030 [P] [US3] Add the strict package-manager exception to `docs/enforcement.md`: the exact grammar, what stays denied (remove/purge/upgrade, `-o`, local `.deb`, `sh -c`, `-E`/`-u`, substitutions, chained non-apt sudo), why `NOPASSWD: ALL` is acceptable (the hook grammar inside the container is the policy; container is the outer boundary), curl/wget unchanged, permissive/interactive unchanged.
- [X] T031 [P] [US3] Add a "Tests not run: missing system package" recovery to `docs/runbook.md`: rebuild with `--apt` (or `--agent-root`), restart instance, reinstall/commit target pack if the preflight warning shows, `Autonomous.resume/2` the feature; reference the install log line.
- [X] T032 [P] [US3] Add a feature 037 paragraph to `CLAUDE.md` (Containerized runtime section area): `--apt` / `--agent-root`, entrypoint probe, `AgentRoot`, contract 5, strict exception, preflight warning, Configuration row, smoke `sysdeps`.

**Checkpoint**: All stories independently usable and documented.

---

## Phase 6: Polish & Cross-Cutting

- [X] T033 Run the full suite `mise exec -- mix test` (SC-004: everything outside this feature unchanged) and `mise exec -- mix compile --warnings-as-errors`; confirm `design_contract_test.exs` green.
- [ ] T034 Walk `quickstart.md` §1–§6 (docker sections by hand: `scripts/container-smoke.sh sysdeps` for dev and release images, with and without each option); note any deviation back into the relevant contract/doc.
  - _Partial (2026-10-08):_ Dockerfile blocks verified in a scratch `debian:bookworm-slim` image (declared pkg installed + manifest, unknown pkg fails naming it, `--agent-root` sudoers/no-remove, uid without passwd entry fails closed, no-option image has no `sudo`/`/etc/autonomous`); `sysdeps` smoke passes on the pre-037 dev image. Still to do by hand: rebuild the real dev/release images with `--apt`/`--agent-root` and run `sysdeps` against each.
- [X] T035 Verify the byte-identical invariants: no-flag image content (no `sudo`, no `/etc/autonomous`), container start output, `PhaseRequest` env/prompt, and hook decisions match pre-037 behaviour (SC-004, FR-002, FR-010, FR-011).

---

## Dependencies & Execution Order

- **Phase 1 → 2**: T001 first; T002/T003 (T003 may finish in T021) in Foundational.
- **US1 (Phase 3)** needs only Phase 1–2 and is independent of US2/US3 → MVP stop point.
- **US2 (Phase 4)**: tests T009–T013 first (they fail until implemented). T015 needs T001. T018 and T014 are independent. T020 → T021 → T023; T015 → T022 → T023; T020 → T024. Dockerfile blocks T007 then T014 touch the same file (sequential).
- **US3 (Phase 5)**: T027 needs T020, T022; docs/smoke tasks (T028–T032) only need the contracts and can start once US2 shapes are fixed.
- **Polish**: after all desired stories.
- Same-file serialization: `scripts/autonomous` (T005 → T016), `compose.yaml` (T006 → T017), `Dockerfile` (T007 → T014), `scope_guard_test.exs` (T002 → T009), `phase_request_test.exs` (T003 → T011).

## Parallel Examples

- **US1**: T006 ∥ T007 after T005's interface is fixed; T004 alongside.
- **US2 tests**: T009 ∥ T010 ∥ T011 ∥ T012 ∥ T013.
- **US2 impl**: T014 ∥ T016 ∥ T017 ∥ T019 ∥ T018, then T020 → T021/T024 in parallel.
- **US3**: T028 ∥ T029 ∥ T030 ∥ T031 ∥ T032 together.

## Implementation Strategy

1. **MVP**: Phase 1–2 + US1 (T001–T008). Operator-declared packages resolve the incident deterministically with strict containment untouched.
2. **Increment 2**: US2 (T009–T025) — opt-in agent root; ship only with the constitution amendment (T001) already committed.
3. **Increment 3**: US3 (T026–T032) — visibility and documentation, then Polish.

Total: 35 tasks — Setup 1, Foundational 2, US1 5, US2 17, US3 7, Polish 3.
