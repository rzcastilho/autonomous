# Quickstart: Control Plane

Run and validate the operator console. All Elixir commands go through **mise**
(`mise exec --`) — the bare PATH is a stale global toolchain.

## Prerequisites

- Toolchain from `.tool-versions` (Elixir 1.20.2-otp-28) available via mise.
- Deps fetched (Phoenix/LiveView/Bandit added in `mix.exs`):
  ```bash
  mise exec -- mix deps.get
  mise exec -- mix compile        # warnings_as_errors is ON
  ```
- A configured target repo + breakdown dir for a backlog run (see `Config.repo/0`,
  `Config.breakdown_dir/0`), or nothing — a single-spec run needs no backlog.

## Start the console

```bash
mise exec -- mix phx.server
# or inside iex, so you can also drive the facade directly:
mise exec -- iex -S mix phx.server
```

Open **http://127.0.0.1:<port>/** (bound to loopback, no login — FR-035). Between
runs the console shows an explicit **no active run** state; the Trigger and Config
views are still usable.

## Validation scenarios

Each maps to a user story / success criterion. Drive runs from the console
(preferred) or from `iex` — the console reflects either (FR-033).

### US1 — Watch a live run (SC-001, SC-002)
1. Start a backlog run (Trigger view → **Start**, or `SpeckitOrchestrator.run/1`).
2. On **Mission Control**, confirm within ~10 s: status-count strip, backlog table
   (id, slug, status, seven-phase progress, elapsed, spend), cost gauge, telemetry
   feed.
3. Let a feature advance a phase. **Expect**: its phase strip + status update within
   5 s with no reload, and a new top entry in the feed.
4. Click a row → drawer opens with per-phase timeline, elapsed, spend, prereqs.

### US2 — Trigger a run (SC-003)
1. **Trigger → Backlog**: confirm it shows breakdown source, feature count + DAG
   validated?, max concurrency, budget. Start → navigates to Mission Control + toast.
2. **Trigger → Single-spec**: type a description → preview auto-id + derived slug.
   Empty description → clear field error, no run (FR-016).
3. Enable the **stacked PR** toggle → status bar shows PR-workflow mode, effective
   concurrency 1.
4. Invalid backlog (dangling prereq / cycle) → Start is disabled and the reason is
   surfaced (FR-019, edge case).

### US3 — Clear an escalation (SC-004)
1. With one escalated feature, open **Escalations**: see divert reason, checkpoint
   pointer (last phase, status, session id, reason), recorded run context, and the
   `## NEEDS HUMAN` clarify questions/options.
2. Enter guidance + optionally a start-phase override → **Resume**. Expect the
   feature re-enters the pipeline at the chosen phase (default = checkpoint last
   phase) and the escalation clears — no hand-built arguments (SC-004).
3. Choose **Full restart** on an unrecoverable one → restarts from phase 1 and frees
   the worktree.
4. Missing/corrupt checkpoint → console steers to full restart, not an impossible
   resume (edge case).
5. Empty escalation set → all-clear empty state (FR-024).

### US4 — Pipeline DAG (SC-006)
Open **Pipeline DAG**: each feature a node placed by dependency depth, edges
prereq→dependent, node shows id/slug/phase/status/spend, legend maps colors to
states (matching everywhere else — FR-034). Click a node → same drawer as the table.

### US5 — Transcripts (SC-006)
**Transcripts**: pick a feature + phase → renders the durable transcript with its
source path shown. Pick a phase not yet reached → explicit "not yet written", not a
blank doc (FR-028).

### US6 — Tune config (SC-005)
**Config**: set a phase model (opus/sonnet), change budget + max concurrency.
Expect the status bar/gauge reflect new values and the change governs **only** work
not yet started (forward-only — FR-032/FR-037); enabling PR workflow forces
effective concurrency 1 and shows PR base/remote.

### Cross-cutting (SC-005, SC-007)
- Change run state from `iex` while watching → console converges within 5 s (SC-005).
- Trip the breaker (low budget): gauge goes red/tripped, **no new releases** appear,
  in-flight features finish their phase then halt between phases — **never** a
  mid-phase kill on screen (SC-007).
- Let a run finish while watching → Mission Control shows drained/completed final
  counts + spend, not a still-live screen (edge case).

## Tests

```bash
mise exec -- mix test test/speckit_orchestrator/console_read_model_test.exs   # pure fold
mise exec -- mix test test/speckit_orchestrator/live_config_test.exs          # forward-only apply
mise exec -- mix test test/speckit_orchestrator/web                           # LiveView flows (facade :runner seam)
mise exec -- mix test                                                         # full hermetic suite
mise exec -- mix test --include integration                                   # opt-in real-harness (no CI runs by default)
```

LiveView tests drive `run/1`/`run_spec/2` through the injected `:runner`/
`:publisher` seams — no real `claude` CLI, no worktrees — so the default suite
stays hermetic (Constitution: Quality & Test Discipline).
