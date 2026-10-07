# Implementation Plan: Fail Fast on Session Startup Failure

**Branch**: `034-session-startup-failfast` | **Date**: 2026-10-07 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/034-session-startup-failfast/spec.md`

## Summary

On 2026-10-07, fretboard-master feature 029 sat `running` for its whole
specify deadline. Its CLI had died during initialize. The cause was a torn read
of the host's `~/.claude.json`, which the `--with-login` container bind-mounts
read-write while host Claude Code sessions rewrite it.

The orchestrator never noticed, because of a link chain (research R1). The SDK
`start_link`s its client inside `PhaseSession`'s **linked** fold Task. Jido runs
the action in an **unmonitored** runner process. The client's abnormal exit
therefore killed both processes silently, Jido's reply was never sent, and the
FeatureRunner blocked in `AgentServer.call` until deadline + grace.

This plan fixes the problem in two layers.

1. **US1 — fail fast at the single choke point.** `PhaseSession.reduce/2`
   folds the stream in a `Task.Supervisor.async_nolink` Task, monitored rather
   than linked, under a new `Autonomous.SessionSup`. An SDK death becomes
   `{:exit, reason}`, which the action folds into
   `%PhaseResult{error: {:session_died, :start_failed | :ended_early, excerpt}}`
   and returns normally. A one-shot "first event" message tells the two kinds
   apart (R3). The fold Task watches its caller, so the "no orphan CLI"
   guarantee survives (R2).

   Downstream, the change mirrors 032's background-wait path. A new
   `session_died` signal feeds `Pipeline.next/3` (after branch drift) and
   `PhaseStep.retry_reason/1`, giving one retry. It also feeds a
   `Chunking.next/2` re-dispatch row and a `SessionRetry.once/2` helper for
   the remediation sites. The breaker and drain checks suppress the retry.
   `Cost` charges $0 for a session that never started. `Report.format_reason/1`
   renders the CLI's stderr excerpt on every surface.
2. **US2 — stop the race.** `--with-login` mounts the host `~/.claude.json`
   **read-only at a seed path**. The entrypoint validates it and atomically
   snapshots it into a container-private `~/.claude.json` at every start. A
   torn read at seed time is retried 5 times, then the entrypoint dies loudly
   naming the file. `~/.claude/` (credentials) stays read-write. The docs and
   smoke checks are updated.

## Technical Context

**Language/Version**: Elixir 1.20.2-otp-28 (mise-pinned), Erlang/OTP 28.5.0.6; POSIX sh + python3 (already in the image) for the entrypoint

**Primary Dependencies**: Jido 2.2 (`AgentServer` runs signal-call actions in unmonitored runners, R1); `jido_harness`/`jido_claude` (GitHub SHAs); `claude_agent_sdk` (`ClientStream` starts `Client` lazily in the stream's start fun, R1); Docker Compose overrides from feature 031

**Storage**: Mnesia. **No schema change**: new error, signal and reason tuples are open terms in existing records.

**Testing**: hermetic ExUnit. A stub stream whose start fun `start_link`s a GenServer that stops abnormally reproduces the incident without a CLI. Container checks live in `scripts/container-smoke.sh` and are run by hand.

**Target Platform**: Linux host and the feature-031 container

**Project Type**: OTP control-plane application with a LiveView console

**Performance Goals**: A session death is detected ≤ 30 s after the SDK process exits. Expected detection is sub-second (a `:DOWN` monitor message).

**Constraints**: `warnings_as_errors`. Pure core stays free of CLI and SDK knowledge (`SessionExit` walks a term generically for `stderr`). Runs with no session death are byte-identical (SC-007). Deadline values, the shell-timeout derivation and drain-don't-kill are untouched (FR-009).

**Scale/Scope**: about 12 files touched. New code: 2 modules (`SessionExit`, `SessionRetry`) and 1 supervisor child (`SessionSup`). Container: 1 compose override, the entrypoint, the smoke script, and 2 docs.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Verdict | Notes |
|---|---|---|
| I. Pure Core, Isolated Contracts | PASS | `SessionExit.classify/2` is pure and SDK-agnostic: it walks any term for a `stderr` binary, and that one fact goes into `harness-contract.md`. `Pipeline.next/3` and `Chunking.next/2` receive the extracted `session_died` signal and parse nothing. The supervision change lives at the existing boundary (`PhaseSession`). No dependency is patched. |
| II. Fail Loud at Boundaries | PASS | A silent hang becomes a named failure carrying the CLI's own words. The entrypoint dies naming an invalid seed instead of starting with a missing or partial config. |
| III. Least-Privilege Containment | PASS | Containment is untouched. US2 *narrows* the container's reach: the host config becomes read-only. |
| IV. Cost-Bounded Autonomy (Drain, Don't Kill) | PASS | The retry reuses `phase_max_retries`. The chunk retry counts against the frozen session ceiling. Breaker and drain checks suppress the retry. A never-started session is charged an actual $0. An `:ended_early` session keeps the estimate fallback ("prefer actual, fall back to estimate"). Nothing is killed: the deadline cut path is unchanged, and the new caller-death cleanup uses the same graceful `GenServer.stop`. |
| V. Human-in-the-Loop Escalation | PASS | No gate diversion changes. The outcome is `:failed`, with no new lifecycle status. |
| VI. Idiomatic Elixir/OTP | PASS | It replaces a linked Task with the OTP-idiomatic `async_nolink` under a named `Task.Supervisor`. Pattern-matched gate clauses. `@spec` on all new public functions. |
| VII. Operator Surfaces Tell the Truth | PASS | A dead session can no longer display as `running`. The reason renders as a sentence through `Report.format_reason/1` with no `inspect/1` in console markup (G-inspect). No new tokens or UI elements. |
| Quality & Test Discipline | PASS | The incident is reproduced hermetically (stub linked GenServer). Pure modules are unit-tested to > 90%. |

**Post-design re-check (after Phase 1)**: unchanged, all PASS. The one new
process is a supervisor child (`SessionSup`), which is infrastructure for an
existing per-session Task, not a new long-lived actor.

## Project Structure

### Documentation (this feature)

```text
specs/034-session-startup-failfast/
├── plan.md              # this file
├── research.md          # R1–R9: failure chain, choke point, classification, retry, cost, US2 design
├── data-model.md        # SessionDeath, error/signal/reason shapes, ChunkState field, container paths
├── quickstart.md        # validation guide
├── contracts/
│   ├── session-death.md            # US1: PhaseSession invariants, classify, gate order, retry, rendering, cost
│   └── container-login-config.md   # US2: mounts, seeding, guarantees, smoke
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks output (not created here)
```

### Source Code (repository root)

```text
lib/autonomous/
├── application.ex                 # + {Task.Supervisor, name: Autonomous.SessionSup}
├── phase_session.ex               # async_nolink fold, first-event marker, caller watch, :session_died result
├── session_exit.ex                # NEW — pure classify/2 (kind + bounded stderr excerpt)
├── session_retry.ex               # NEW — pure once/2 retry decision for remediation sites
├── pipeline.ex                    # + :error clause for %{session_died: d} after branch drift
├── phase_step.ex                  # + retry_reason clause
├── chunking.ex                    # + re-dispatch row, failure row, failure_sentence clause
├── chunk_runner.ex                # pass session_died signal through to Chunking
├── analyze_runner.ex              # SessionRetry.once/2 around remediation calls
├── feature_runner.ex              # SessionRetry.once/2 around "remediation.run"
├── cost.ex                        # + :start_failed → {0.0, :actual}
├── report.ex                      # + format_reason clause
├── actions/
│   ├── run_feature_phase.ex       # classify: add :session_died signal
│   ├── run_auto_remediation.ex    # same
│   ├── run_remediation.ex         # same
│   └── run_phase.ex               # same
└── web/live/run_detail_live.ex    # delegate session_died to Report.format_reason/1

compose.claude-login.yaml          # host ~/.claude.json → read-only seed path
scripts/container-entrypoint.sh    # seed snapshot (validate, retry, atomic mv, die loud)
scripts/container-smoke.sh         # seed checks + updated login check
docs/container.md                  # isolation + restart-to-pick-up-host-changes note
docs/harness-contract.md           # SDK client lives in the stream; stderr field fact

test/autonomous/
├── session_exit_test.exs          # NEW
├── session_retry_test.exs         # NEW
├── phase_session_test.exs         # + startup death, early death, caller death
├── pipeline_test.exs              # + gate order
├── phase_step_test.exs            # + retry/no-retry incl. breaker/drain
├── chunking_test.exs              # + rows
├── cost_test.exs                  # + clause
└── report_test.exs                # + rendering
```

**Structure Decision**: This is the existing single-project OTP layout. The
fix concentrates in `PhaseSession`, the one choke point every session-driving
site already uses. Downstream wiring copies the 032 background-wait pattern,
so each site gets the same gate, retry and rendering shape.

## Complexity Tracking

No constitution violations. Nothing to justify.
