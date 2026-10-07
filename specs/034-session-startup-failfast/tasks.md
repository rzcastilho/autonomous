---

description: "Task list for 034 — fail fast on session startup failure"
---

# Tasks: Fail Fast on Session Startup Failure

**Input**: Design documents from `/specs/034-session-startup-failfast/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/session-death.md, contracts/container-login-config.md, quickstart.md

**Tests**: Included. Plan and quickstart require hermetic ExUnit coverage (stub linked GenServer reproduces the incident), pure modules > 90%. Container checks live in `scripts/container-smoke.sh` (run by hand).

**Organization**: By user story. US1 (P1) = fail fast on session death. US2 (P2) = container config isolation. US2 is fully independent of US1 (different files) and can run in parallel with it.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: parallelizable (different files, no dependency on incomplete tasks)
- **[Story]**: US1 / US2
- All Elixir commands via `mise exec -- mix …`; `warnings_as_errors` is on

---

## Phase 1: Setup

**Purpose**: Baseline before touching the choke point.

- [X] T001 Run `mise exec -- mix test` on branch `034-session-startup-failfast` and record that the baseline suite is green (no file change; failing baseline must be understood before proceeding)
- [X] T002 [P] Read `lib/autonomous/phase_session.ex`, `lib/autonomous/phase_step.ex`, `lib/autonomous/chunking.ex`, and the 032 background-wait path (`backgrounded` signal, `background_retried?`, `PhaseResult.stranded_background/1`) to copy its gate/retry/render shape; no file change

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Pure classifier and supervisor that every US1 task depends on.

- [X] T003 [P] Create pure module `Autonomous.SessionExit` in `lib/autonomous/session_exit.ex` with `@spec classify(term(), boolean()) :: %{kind: :start_failed | :ended_early, excerpt: String.t()}` per contracts/session-death.md C2: `started?` false → `:start_failed`, true → `:ended_early`; depth-first walk of tuples/lists/maps/structs for first binary under a `:stderr` key; fallback `inspect(reason, limit: 50, printable_limit: 2000)`; collapse whitespace runs, trim, slice to 2,000 graphemes; empty → `"no output captured"`; total, never raises
- [X] T004 [P] Create `test/autonomous/session_exit_test.exs`: stderr extracted from nested `ProcessExit`-shaped term (three tuples deep, plain maps, no SDK struct names), inspect fallback, 2,000-char bound, whitespace collapse, empty → `"no output captured"`, kind from `started?`, non-raising on odd terms (improper lists, pids, funs)
- [X] T005 Add `{Task.Supervisor, name: Autonomous.SessionSup}` to the app supervision tree in `lib/autonomous/application.ex` (before consumers of it; alongside `RunnerSup`)

**Checkpoint**: `SessionExit` tested; `SessionSup` running. US1 and US2 can start.

---

## Phase 3: User Story 1 — Session death fails the phase promptly with a clear reason (Priority: P1) 🎯 MVP

**Goal**: A session that dies at startup or ends early becomes a normal `{:session_died, kind, excerpt}` result within seconds, retried once, then a `:failed` terminal rendered readably on every surface.

**Independent Test**: Stub stream whose start fun `start_link`s a GenServer that stops abnormally → `PhaseSession.reduce/2` returns `{:session_died, :start_failed, _}` in < 5 s with a 60 s deadline while the calling test process survives; `PhaseStep` retries once then fails with `{:session_died, phase, _}`; no retry under breaker/drain; worker not left registered.

### Tests for US1

- [X] T006 [P] [US1] Extend `test/autonomous/phase_session_test.exs`: (a) linked GenServer stub stopping with `{:initialize_failed, …}` before any event → `error: {:session_died, :start_failed, excerpt}` in < 5 s under a 60 s deadline, caller test process stays alive (I1); (b) stub yields one event then dies → `:ended_early`, `session_id` kept if seen; (c) kill the caller mid-fold → stub server's `terminate/2` runs (I2); (d) deadline cut still stops the fold Task's link set (I3); (e) one `Logger.warning` per death with kind + excerpt (I4, `ExUnit.CaptureLog`); (f) normal stream unchanged
- [X] T007 [P] [US1] Extend `test/autonomous/pipeline_test.exs`: `:error` clause order per C3 — `branch_drift` beats `session_died`; `session_died` beats `backgrounded` and `outstanding_work?`; result `{:failed, {:session_died, phase, d}}`; no change to non-death paths
- [X] T008 [P] [US1] Extend `test/autonomous/phase_step_test.exs`: death → retry → success advances with two history entries (first stays visible, US1-2); death → retry → death fails with `{:session_died, phase, _}`; breaker tripped and drain requested each suppress the retry (FR-010); `ensure_recorded/3` satisfied; `retry_reason/1` strings `"failed to start"` / `"ended without a result"`; budget is `phase_max_retries`
- [X] T009 [P] [US1] Extend `test/autonomous/chunking_test.exs`: first death re-dispatches same scope with `session_died_retried?` set and counts against frozen session ceiling; second death → `{:failed, {:session_died, ref, d}}`; flag resets when task-phase advances (same lifecycle as `background_retried?`); `failure_sentence/1` clause
- [X] T010 [P] [US1] Create `test/autonomous/session_retry_test.exs`: `SessionRetry.once/2` decision — retry on first death, none on second, none when breaker tripped, none when drain requested, passthrough for non-death outcomes
- [X] T011 [P] [US1] Extend `test/autonomous/cost_test.exs`: `{:session_died, :start_failed, _}` → `{0.0, :actual}`; `:ended_early` keeps existing estimate fallback; other shapes unchanged
- [X] T012 [P] [US1] Extend `test/autonomous/report_test.exs`: `format_reason/1` for phase (`"specify session failed to start: <e>"`), task-phase (`~s(task-phase 3 "Title" session ended without a result: <e>)`), and `{:remediation, n}` shapes; no raw terms; run `design_contract_test.exs` stays clean (no `inspect/1` in console markup, G-inspect)

### Implementation for US1

- [X] T013 [US1] Rework `PhaseSession.reduce/2` in `lib/autonomous/phase_session.ex` per contracts C1/R2/R3: fold in `Task.Supervisor.async_nolink(Autonomous.SessionSup, …)`; `Stream.transform` wrapper ahead of `PhaseResult.reduce/1` sends one-shot `{ref, :session_started}` to parent on first event; fold Task monitors its caller and on `:DOWN` stops its linked servers via the existing `stop_server/1` / `GenServer.stop(pid, :normal, grace)` path then exits; on `Task.yield` `{:exit, reason}` check mailbox for the marker, build `SessionExit.classify(reason, started?)`, return `%PhaseResult{status: :error, error: {:session_died, kind, excerpt}}` (keep `session_id` if seen); `Logger.warning` once per death; `cut/2` keeps stopping the Task's link set; deadline/grace values untouched (FR-009)
- [X] T014 [P] [US1] Add `:session_died` signal (`%{kind:, excerpt:}`) to the classifier of `lib/autonomous/actions/run_feature_phase.ex` when `error` matches `{:session_died, _, _}` (covers phases and implement chunks)
- [X] T015 [P] [US1] Same signal in `lib/autonomous/actions/run_auto_remediation.ex`
- [X] T016 [P] [US1] Same signal in `lib/autonomous/actions/run_remediation.ex`
- [X] T017 [P] [US1] Same signal in `lib/autonomous/actions/run_phase.ex`
- [X] T018 [US1] Add `Pipeline.next/3` `:error` clause for `%{session_died: d}` → `{:failed, {:session_died, phase, d}}` in `lib/autonomous/pipeline.ex`, placed after branch-drift and ahead of backgrounded/incomplete-session (C3)
- [X] T019 [US1] Add `PhaseStep.retry_reason/1` clause in `lib/autonomous/phase_step.ex` after branch-drift, before background: `"failed to start"` / `"ended without a result"` by `kind`; reuse `phase_max_retries`; breaker/drain checks suppress retry; ensure a death appends a history entry `%{phase:, outcome: :error, error: {:session_died, kind, excerpt}}` for every attempt; retry warning names feature, phase, attempt, excerpt (FR-013)
- [X] T020 [US1] Add `session_died_retried?` field (default `false`) to `ChunkState` and the re-dispatch row + failure row to `Chunking.next/2` in `lib/autonomous/chunking.ex`, plus `failure_sentence/1` clause delegating to `Report.format_reason/1`
- [X] T021 [US1] Pass the `session_died` signal through to `Chunking` in `lib/autonomous/chunk_runner.ex` (breaker/drain checked before the re-dispatch, same as the existing retry sites)
- [X] T022 [P] [US1] Create pure `Autonomous.SessionRetry` in `lib/autonomous/session_retry.ex` with `@spec once/2` — decision over outcome plus breaker and drain predicates (retry once on `session_died`, never when breaker tripped or `Workers.drain_requested?/0`)
- [X] T023 [US1] Wrap remediation calls with `SessionRetry.once/2` in `lib/autonomous/analyze_runner.ex` (auto-remediation); on exhaustion fail with `{:session_died, {:remediation, attempt}, d}`
- [X] T024 [US1] Wrap the `"remediation.run"` call with `SessionRetry.once/2` in `lib/autonomous/feature_runner.ex`; same failure shape; no commit on drift unchanged
- [X] T025 [P] [US1] Add `Cost.for_phase/2` clause `(_, %PhaseResult{error: {:session_died, :start_failed, _}})` → `{0.0, :actual}` in `lib/autonomous/cost.ex` (C6)
- [X] T026 [US1] Add `Report.format_reason/1` clauses in `lib/autonomous/report.ex` (C5) reusing `background_where/1`; ensure `print_status/0` / final report use it
- [X] T027 [US1] Delegate `session_died` in `RunDetailLive.format_legacy_reason/1` to `Report.format_reason/1` in `lib/autonomous/web/live/run_detail_live.ex`; render excerpt as text in existing mono reason component, no `inspect/1`, no new token
- [X] T028 [P] [US1] Record in `docs/harness-contract.md`: SDK `Client` is started inside the stream's start fun (linked to the fold Task), and exit terms carry the CLI message in a `stderr` field (the one contract `SessionExit` relies on)
- [X] T029 [US1] Run `mise exec -- mix test` (full suite incl. `design_contract_test.exs`) and `mix compile --warnings-as-errors`; fix regressions; confirm SC-007 (no-death runs unchanged)

**Checkpoint**: US1 complete and independently verifiable via hermetic suite (quickstart §1).

---

## Phase 4: User Story 2 — Container does not read a half-written host CLI config (Priority: P2)

**Goal**: With `--with-login`, sessions read a container-private, atomically-seeded copy of `~/.claude.json`; host file mounted read-only at a seed path.

**Independent Test**: `scripts/container-smoke.sh us1` — valid seed → `$HOME/.claude.json` regular file, not a mount, byte-equal to seed; invalid seed (`{`) → non-zero exit naming seed path.

- [X] T030 [P] [US2] Change `compose.claude-login.yaml`: mount `${HOME}/.claude.json` read-only at `/home/autonomous/.claude.host.json:ro` for both `dev` and `console` (YAML anchor `&login-mounts`); keep `${HOME}/.claude:/home/autonomous/.claude` read-write; leave `scripts/autonomous` precondition as is
- [X] T031 [US2] Add seeding to `scripts/container-entrypoint.sh` before the credentials warning (§5) and before the BEAM starts, per contracts/container-login-config.md: no-op if seed absent; validate seed as JSON object with python3, retry 5 × 200 ms; write `$HOME/.claude.json.tmp.$$`, `chmod 600`, atomic `mv`; `die "host CLI config <seed path> is not valid JSON: <parser message>"` after retries; `die` naming the stale mount and fix if `$HOME/.claude.json` is itself a mount point
- [X] T032 [US2] Update `scripts/container-smoke.sh`: change the "mounted login only" agent check `-v` to the read-only seed mount; add non-agent checks (valid seed → regular file, not mountpoint, byte-equal; invalid seed `{` → non-zero exit and seed path in error); `SMOKE_AGENT=1` keeps the real `claude -p` check
- [X] T033 [P] [US2] Update `docs/container.md`: describe isolation (private re-seeded copy, container writes never reach host), that host-side login/trust changes after start need a container restart (FR-019), and the entrypoint failure message
- [X] T034 [US2] Run `scripts/container-smoke.sh us1` and confirm the new seed checks pass (and, if available, race stress from quickstart §3)

**Checkpoint**: US2 verifiable by smoke; no Elixir changes.

---

## Phase 5: Polish & Cross-Cutting

- [X] T035 [P] Add the 034 summary to `CLAUDE.md` (session-death detection under "Session deadlines"; container seed isolation under "Containerized runtime") and, if the runbook describes failed-reason handling, a line in `docs/runbook.md`
- [X] T036 Run `mise exec -- mix test --cover`; confirm > 90% on `SessionExit` and `SessionRetry`
- [ ] T037 Walk quickstart §2 (corrupt container copy → specify fails to start within ~30 s, one retry logged, feature `failed`, `Autonomous.workers/0` empty, spend $0) and note the result in `specs/034-session-startup-failfast/quickstart.md`

---

## Dependencies & Execution Order

- Setup (T001–T002) → Foundational (T003–T005) → US1 / US2.
- **US2 has no dependency on Foundational or US1**; it may start any time (T030–T034 touch only compose/shell/docs).
- Within US1: tests T006–T012 can be written first (they fail until implementation). T013 (PhaseSession) needs T003 + T005. T014–T017 need T013. T018 → T019 (pipeline before step retry semantics); T020 → T021; T022 → T023, T024; T025–T028 independent after T013. T029 last.
- File conflicts (no [P]): T013, T018, T019, T020, T021, T023, T024, T026, T027 each own a distinct file but have logical ordering above.

## Parallel Examples

```text
# After Foundational:
Stream A (US1): T006–T012 tests in parallel → T013 → T014–T017 in parallel → T018/T019 → T020/T021 → T022–T024 → T025–T028 → T029
Stream B (US2): T030 ∥ T033 → T031 → T032 → T034
```

## Implementation Strategy

- **MVP = US1.** It alone removes the 50-minute hang; a torn config then costs one quick retry. Ship after T029.
- **Then US2** removes the trigger (torn `~/.claude.json` read). Shell/compose only, low risk.
- Behavior unchanged for runs with no session death (SC-007) — verified by T029.
