# Quickstart: Console Projection Survives Coordinator Timeouts

**Feature**: 038-console-projection-resilience

Contracts: [contracts/console-projection-resilience.md](contracts/console-projection-resilience.md) ·
Data model: [data-model.md](data-model.md) · Decisions: [research.md](research.md)

## Prerequisites

```bash
mise exec -- mix deps.get
mise exec -- mix compile          # warnings_as_errors
```

## 1. Automated validation (default suite, hermetic)

```bash
mise exec -- mix test test/autonomous/coordinator_probe_test.exs
mise exec -- mix test test/autonomous/console_delay_test.exs
mise exec -- mix test test/autonomous/console_history_test.exs
mise exec -- mix test test/autonomous/console_projection_resilience_test.exs
mise exec -- mix test test/autonomous/web/mission_control_live_test.exs
mise exec -- mix test test/autonomous/web/design_contract_test.exs
mise exec -- mix test                                   # SC-005: whole suite unchanged
```

Expected scenarios covered (each maps to a spec item):

| Scenario | Setup | Expected |
|----------|-------|----------|
| Probe timeout (R3) | stub GenServer that sleeps past `timeout` | `{:error, :timeout}`, caller alive |
| Probe absent | no registered name | `:none` |
| Projection survives (US1-1, SC-001) | projection with `coordinator:` stub that never answers, `probe_timeout: 50`, `reconcile_ms: 20`; fold 3 phase events; wait ≥ 3 probe timeouts | process alive (same pid), `read/1` feed still has the 3 entries, new events append |
| Read during stall (US1-3) | same stub, call `read/1` while a probe is pending | answers immediately |
| Recovery (US1-2, SC-002) | release stub | next `:reconciled` has `delayed?: false` and fresh status |
| Single miss silent (US3-2) | one miss then success | no `delayed?: true` broadcast ever |
| Delayed notice (US3-1/3, SC-006) | two consecutive misses | `:reconciled` with `delayed?: true`; Mission Control renders `[data-console-delayed]`; clears on success |
| Log rate limit (FR-008) | 10 misses inside 60 s | exactly one warning (`capture_log`), no error |
| Rebuild (US2-1, SC-003) | store holds a run with 2 features × recorded attempts + 1 terminal; start projection | feed = recorded entries in order, rows from record |
| Rebuild trim (FR-006) | > 200 recorded entries | newest 200 kept, chronological |
| Rebuild dedupe (US2-2) | rebuild, then deliver the telemetry stop for the newest recorded attempt | feed has it once; slice spend not doubled |
| Parked rebuild | run `:parked` | feed shows its history |
| Empty rebuild | no run / no attempts | `ConsoleReadModel.new()` |
| Action unreachable (FR-004) | Mission Control `continue_run` with a runner that blocks past the wait | flash "could not reach run controller", LiveView alive |
| Page load during stall (FR-003, SC-004) | Coordinator name registered to a stalling stub; mount `/` | renders < 3 s with last-known state |

## 2. Manual check in a running instance (container)

```bash
scripts/autonomous console         # attach to the instance's iex
```

With a run in progress and Mission Control open in a browser:

```elixir
# Stall the Coordinator for ~15 s (three+ reconcile probes time out).
:sys.suspend(Autonomous.Coordinator); Process.sleep(15_000); :sys.resume(Autonomous.Coordinator)
```

Expected:

1. Feed and rows stay; after ~10 s the "live status delayed — `Coordinator.status/1` not answering" line appears.
2. Reloading the page during the stall loads with last-known state.
3. After resume the notice disappears within one refresh (~2 s); feed continues.
4. Instance log: one `[warning]` for the stall (plus one info on recovery), no `ConsoleProjection` crash report.

Rebuild check:

```elixir
Process.exit(Process.whereis(Autonomous.ConsoleProjection), :kill)
```

Reload Mission Control: within 5 s the feed shows the run's recorded
`run started` / `phase … started` / `phase … -> …` / `feature terminal …`
entries instead of an empty panel (SC-003). Repeat after an instance restart
(`scripts/autonomous stop` + start) with a parked run.

## Run record (T031) — 2026-10-09

Container instance on `../ledgerlite` (dev image, `--with-login`), driven over
distributed-Erlang RPC. A stub `Coordinator` (no runner, no spend) stood in for a
live run; `r000004` was the parked run in the store.

- **Stall** (`:sys.suspend` on the Coordinator for 15 s): projection pid unchanged,
  `read/1` answered in 0 ms mid-stall, feed (5 entries) kept, one
  `delayed?: true` broadcast, `last_known().delayed?` true during the stall.
  After `:sys.resume`: three `delayed?: false` reconciles, notice state cleared.
  Log: exactly one `[warning] … not answering (1 consecutive missed refreshes)`,
  one `[info] … answering again`; no crash report.
- **Rebuild** (`Process.exit(ConsoleProjection, :kill)` on a parked run): fresh
  start and post-kill restart both showed the recorded feed (4 entries, slice `004`,
  `run_key` `r000004`).
- Not exercised: browser view of the delayed line (covered by
  `mission_control_live_test`), and a live in-flight run's feed.
