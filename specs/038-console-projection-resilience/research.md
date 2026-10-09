# Research: Console Projection Survives Coordinator Timeouts

**Feature**: 038-console-projection-resilience | **Date**: 2026-10-09

No `NEEDS CLARIFICATION` remained after the spec's clarify session; the items
below resolve the design unknowns found while reading the current code.

## R1 — Where the observed crash actually happens

**Finding.** `ConsoleProjection.handle_info(:reconcile, state)` calls
`Coordinator.status/1` (a `GenServer.call` with the default 5 000 ms timeout)
*inside* the projection's own callback. When the Coordinator is slow the call
exits, the exit is not caught, and the projection dies. Its supervisor restarts
it with `ConsoleReadModel.new()`, so the feed (only ever held in memory, FR-036
of 008) is gone. While the call is blocked the projection's mailbox is stuck,
so a LiveView mounting at the same moment waits on `ConsoleProjection.read/0`
(also a 5 000 ms `GenServer.call`) and crashes too — the "page load that raced
the failure crashed as well" in the spec.

Other blocking `Coordinator.status/1` calls on the console path, each able to
crash a LiveView process the same way:

| Site | When |
|------|------|
| `MissionControlLive.coordinator_status/0` | mount `seed/1` |
| `EscalationsLive.coordinator_status/0` | mount / refresh |
| `PipelineDagLive.coordinator_status/0` | mount `seed/1` |
| `ConfigLive.coordinator_status/0` | after `apply` (broadcast) |
| `Layouts.coordinator_status/0` | **every render** of the topbar |
| `TriggerLive.live_coordinator?/0` | already catches `:exit` — unchanged |

**Decision.** Fix both halves: (a) the projection never makes a blocking call
in a callback; (b) every console call site goes through one exit-safe probe
with a fallback to the projection's last-known status.

## R2 — Offloading the reconcile probe

**Decision.** On each `:reconcile` tick the projection starts one
`Task.async/1` that runs `CoordinatorProbe.status/2` + `Ledger.snapshot/1` and
returns a tagged result; the projection handles `{ref, result}` and the
`:DOWN`. At most one probe is in flight: a tick that finds a probe still
pending is skipped (not counted as a miss — the probe's own timeout counts it).
The probe body catches `:exit`, so the task always returns normally and the
link never fires.

**Rationale.** Constitution VI "No blocking the scheduler" — long or blocking
work must not run in a callback others await. `Task.async` from a GenServer is
the standard OTP pattern for one-shot offloaded work and needs no new
supervisor child (the task is short-lived and never outlives the wait limit).

**Alternatives rejected.**
- *`try/catch :exit` around the existing synchronous call*: stops the crash,
  but the projection still blocks for up to 5 s, so concurrent
  `ConsoleProjection.read/0` callers still time out — the second observed crash
  remains.
- *A new `Task.Supervisor` child for console probes*: more tree surface for a
  task that cannot crash (it catches its own exits). Not needed.
- *Shorter Coordinator call timeout*: the spec says the wait limit is an
  existing operating value this feature does not change.

## R3 — An exit-safe Coordinator probe (boundary module)

**Decision.** New `Autonomous.CoordinatorProbe` with
`status(server, timeout) :: {:ok, map()} | :none | {:error, :timeout | :down}`.
`:none` = no registered/alive Coordinator (today's `nil`); `{:error, :timeout}`
= the call exceeded `timeout`; `{:error, :down}` = the process died mid-call.
It is the only place on the console path that calls `Coordinator.status/1`.

**Rationale.** One place to catch exits; returns tagged tuples (VI). Existing
`nil`-on-absent semantics are preserved by mapping `:none → nil` at call sites,
so a responsive Coordinator yields byte-identical views (FR-009, SC-005).

**Alternatives rejected.** Changing `Coordinator.status/1` itself to catch: it
is also used by the facade (`Autonomous.status/0`, `coordinator_active_pid/0`)
whose semantics FR-010 forbids changing.

## R4 — Mount/render-time fallback and page-load budget

**Decision.** LiveView mount/seed and the topbar call
`CoordinatorProbe.status(Coordinator, 1_000)`; on `{:error, _}` they use
`ConsoleProjection.last_known/0` — the last successful reconcile result
(`%{coordinator:, ledger:, delayed?:}`), which the projection serves without
blocking. `ConsoleProjection.read/0` and `last_known/0` become exit-safe at the
call site: a projection that is restarting (noproc / exit) yields
`ConsoleReadModel.new()` / an empty last-known, never a crashed page.

**Rationale.** SC-004 (< 3 s page load while the controller is unresponsive):
1 s probe + store reads fits; the 5 s reconcile wait limit stays unchanged for
the projection's own refresh. With a responsive Coordinator the probe answers
in microseconds, so the mount path still reads a fresh status, exactly as
today.

**Alternatives rejected.** *Always render from the projection's cached status*:
up to one reconcile interval (2 s) stale on every mount and breaks every
existing test that starts a Coordinator and mounts with `reconcile_ms: 0`
(FR-009/SC-005).

## R5 — Miss counting, delayed notice, and logging

**Decision.** The projection keeps `misses :: non_neg_integer()`.
A probe result of `{:error, _}` increments it; `{:ok, _}` or `:none` resets it
to 0. `delayed? = misses >= 2` (pure function `ConsoleDelay.delayed?/1` /
`ConsoleDelay.step/2` — see data-model). Broadcasts:

- success → `{:console, :reconciled, %{coordinator:, ledger:, delayed?: false}}`
  (the existing message, one extra key);
- miss with `misses < 2` → nothing (FR-007: a single miss shows nothing);
- miss with `misses >= 2` → `{:console, :reconciled, last_known with
  delayed?: true}` so views mark themselves delayed while keeping last-known
  status.

Logging: a single `Logger.warning` on the first miss of a streak, then at most
one per 60 s while the streak lasts, and one `Logger.info` on recovery.
Never `Logger.error`, never a restart (FR-008).

**Rationale.** Existing handlers match `%{coordinator: c, ledger: l}` — an
extra key does not break the match, so views that do not render the notice are
unaffected (FR-009). A streak-based rate limit bounds log noise for the
"never answers again" edge case.

**Alternatives rejected.** A separate `{:console, :delayed, …}` message:
every subscriber's catch-all would have to learn it; folding the flag into
`:reconciled` keeps one message carrying authority.

## R6 — History rebuild source and shape

**Finding.** Feature 023 already hydrates Mission Control **rows** from the
durable record at every seed/reconcile (`ConsoleReadModel.hydrate/3`), so rows
survive a projection restart today. What is lost is (a) the **feed**, and (b)
the projection's own feature slices (spend baseline, phase timeline, windows)
that `overlay_observed/2` uses when there is no live Coordinator.

**Decision.** On every projection start (`init` → `handle_continue(:rebuild)`)
the projection loads the instance's current run detail — the `:in_flight` run
(`Autonomous.current_run_id/0`) or else the `:parked` run
(`Store.parked_run/1`) — and folds it through a new pure
`ConsoleHistory.rebuild(run_detail) :: ConsoleReadModel.t()`:

| Recorded fact | Rebuilt feed entry (same text as the live fold) |
|---|---|
| `run.started_at` | `"run started"` (`:info`, no feature) |
| phase attempt `started_at` (pipeline phases only) | `"phase #{phase} started"` |
| phase attempt `ended_at` + `outcome` | `"phase #{phase} -> #{inspect(outcome)}"`, severity via the existing outcome→severity rule |
| feature `ended_at` + terminal `status` + `terminal_reason` | `"feature terminal #{status} (#{inspect(reason)})"` |
| feature `pr_url` (with `ended_at`) | `"PR opened: #{url}"` |

Entries are sorted chronologically, the newest 200 kept (FR-006), and stored
newest-first like the live feed. `at` is the recorded timestamp. Feature
slices come from `ConsoleHydration.from_record/3` (keys of
`feature_slice()`, `chunk_cost_seen: 0.0`); `run_key` is set to the run's key
so a later `[:speckit, :run, :start]` for the same run (a resume) does not
wipe the rebuild.

`:implement_chunk` attempts, remediation attempts, chunk/scope messages, and
`scope_narrowing_refused` are not rebuilt — they are live-only today, which
the spec accepts ("does not invent entries").

**Rationale.** Pure function over the same `run_detail/1` map the console
already uses (Constitution I; no new store query). Texts match the live fold
so a rebuilt feed is indistinguishable in shape from a live one.

**Alternatives rejected.** *Persisting the feed*: 008 FR-036 says the
projection never persists, and the spec places persisting live-only messages
out of scope. *Rebuilding in `init/1`*: blocks application boot on a store
read; `handle_continue` keeps `start_link` returning immediately.

## R7 — No duplicates between rebuilt history and live events

**Finding.** The projection attaches telemetry in `init`; events emitted while
the rebuild reads the store queue in the mailbox and are folded afterwards.
An event already recorded before the read would appear twice.

**Decision.** `ConsoleHistory.rebuild/1` returns the model plus a bounded
`rebuilt_keys` set of `{feature_id, phase, text}` for the newest rebuilt entry
per key. While the set is non-empty, a live event whose feed entry matches a
key is skipped entirely — feed *and* slice, since the rebuilt slice already
reflects it (no double-counted spend) — and the key is consumed. The set is cleared on the first successful
reconcile after rebuild (≤ one interval), by which time any mailbox backlog has
been folded. The set lives in the model, is consulted by `push_feed/2`'s
caller only, and is empty in every non-rebuild path — so FR-009 holds.

**Alternatives rejected.** *Timestamp watermark*: live entries are stamped
`DateTime.utc_now()` at fold time, not at emission, so they always look newer
than the record. *Attach after rebuild*: loses events instead of duplicating
them — worse than a bounded dedupe.

## R8 — Operator actions while the controller is unreachable (FR-004)

**Finding.** `run_unlinked/1` in Mission Control, Escalations, and Trigger is
`Task.Supervisor.async_nolink |> Task.await()` (5 s). `continue_run/1` goes
through `coordinator_active_pid/0` → `Coordinator.status/1`; a slow
Coordinator makes the await exit, crashing the LiveView. `end_run/1` touches
only the store — unaffected.

**Decision.** `run_unlinked/1` becomes `Task.yield(task, timeout) || nil`
handling: `{:ok, result}` → result; `{:exit, reason}` →
`{:error, {:controller_unreachable, reason}}`; `nil` (still running) →
`{:error, :controller_unreachable}` **without** shutting the task down (the
action may still complete; the next reconcile shows its effect — shutting it
down mid-`continue_run` could leave the run half-flipped, which 035 forbids).
The flash text is rendered through a pure helper so the wording is tested. The
facade (`continue_run/1`, `coordinator_active_pid/0`) is unchanged (FR-010).

## R9 — Delayed-status notice presentation

**Decision.** A single line on Mission Control, above the feed, rendered only
when `view.delayed?`:
`live status delayed — Coordinator.status/1 not answering; showing last known
state`. Uses existing text/border tokens and an existing notice class (no new
status color, no animation — it is not live work; Constitution VII, design
contract). Mono for `Coordinator.status/1`, sans for prose. The topbar is not
changed beyond using the probe+fallback (its chip semantics stay as is).

**Rationale.** Spec Story 3 names Mission Control; the design guard
(`design_contract_test.exs`) is the compliance check.
