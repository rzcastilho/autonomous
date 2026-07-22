# Contract: ConsoleProjection & PubSub

The live-update path that satisfies FR-010 (no-reload updates), FR-009 (telemetry
feed), FR-033/SC-005 (converge to authoritative), and the FR-008 phase indicator
that the Coordinator snapshot cannot supply (research R3).

## Processes

- **`ConsoleProjection`** — one boot-started GenServer (added to the app
  supervision tree). Owns the console read-model and the bounded feed.
- **`Phoenix.PubSub`** — one instance (`SpeckitOrchestrator.PubSub`) added to the
  supervision tree. Topic: `"console:run"`.

## Telemetry subscription

On `init`, `ConsoleProjection` attaches to `SpeckitOrchestrator.Telemetry.events/0`:

| Event | Fold effect |
|-------|-------------|
| `[:speckit, :phase, :start]` | set feature `current_phase = meta.phase`, `phases[phase].state = :active`, `model = meta.model`; push `EventEntry` |
| `[:speckit, :phase, :stop]` | `phases[phase] = {state: :completed, outcome: meta.outcome, cost: meta.cost}`; add cost to `spend`; push `EventEntry` |
| `[:speckit, :phase, :exception]` | mark active phase errored; push `EventEntry(severity: error)` |
| `[:speckit, :feature, :terminal]` | finalize feature; `spend = meas.cost_total` if higher; push `EventEntry` (severity by status) |

The fold is delegated to a **pure** function
`ConsoleReadModel.apply_event(model, event_name, measurements, metadata) :: model`
so it is unit-testable with synthetic events (no telemetry, no CLI). The GenServer
is a thin owner: fold → store → broadcast diff.

## Broadcast messages (topic `"console:run"`)

```elixir
{:console, :feature_updated, %{id: String.t(), feature: FeatureView.slice()}}
{:console, :feed, EventEntry.t()}                 # one appended entry
{:console, :reconciled, %{coordinator: snapshot, ledger: ledger_snapshot}}
{:console, :run_finished, report_map}             # from Coordinator :owner {:run_complete, report}, re-broadcast
```

LiveViews `Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, "console:run")` on
`mount` (connected only) and update assigns per message. No message carries
authority on its own — `:reconciled` is the source of truth and supersedes drift.

## Read API (seed on mount)

```elixir
ConsoleProjection.read() :: %{
  features: %{id => %{current_phase, phases, spend}},
  feed:     [EventEntry]        # bounded, newest first
}
```

A LiveView seeds full state = `merge(Coordinator.status/0, Ledger.snapshot/1,
ConsoleProjection.read/0)`. `merge/3` is pure and shared by seed and reconcile.

## Reconcile tick (FR-033, SC-005)

`ConsoleProjection` runs a `:timer.send_interval(reconcile_ms, :reconcile)` (default
`reconcile_ms = 2000`, ≤ the 5 s budget of SC-002/SC-005). On tick:
1. read `Coordinator.status/0` (or note absence → no-active-run) and
   `Ledger.snapshot/1`;
2. broadcast `{:console, :reconciled, …}`.

This is the safety net for state that never flows through telemetry (a run started
or stopped out of band, a feature resolved externally). Authoritative state always
wins; the projection is only a low-latency accelerator for phase moves.

## Bounded feed (edge case)

The feed is a fixed-capacity ring (default 200 entries), newest first. Appends drop
the oldest — a long run never grows console memory without limit.

## Invariants

- The projection **derives**, never persists (FR-036); on `ConsoleProjection`
  restart it rebuilds from `Coordinator.status/0` + subsequent telemetry.
- The projection never mutates orchestrator state — read/subscribe only.
- Phase order everywhere is `Pipeline.phases/0`; status→color is the shared palette
  (FR-034).
