# Phase 0 Research: Control Plane

All unknowns from Technical Context resolved below. Backend surfaces were mapped
against the live code (module + function signatures cited).

## R1. Web stack — Phoenix LiveView

**Decision**: Phoenix `~> 1.7` + Phoenix LiveView `~> 1.0`, served by **Bandit**,
no Ecto, no assets pipeline beyond LiveView's bundled JS.

**Rationale**: The console is a live view of in-node BEAM state (Coordinator,
Ledger, telemetry). LiveView renders server-side from that state and pushes diffs
over a WebSocket — real-time (FR-010) with almost no client JS and no separate
frontend build. It is the idiomatic BEAM fit and keeps Constitution I intact: the
UI is a thin boundary calling the existing facade. No database is needed
(FR-036), so Ecto is omitted.

**Alternatives rejected**:
- *SPA (React/…) + Phoenix Channels* — adds a JS build, a second language, and a
  serialization contract for zero benefit at this scale (1 operator, 6 views, ~7
  features).
- *Static page + polling `status/0`* — cannot meet the "no operator reload"
  requirement (FR-010) cleanly and wastes the telemetry stream already emitted.

## R2. Live-update transport — telemetry → PubSub → LiveView

**Finding**: There is **no pub/sub anywhere** in the orchestrator today. The only
push is `Coordinator`'s `{:run_complete, report}` to its `:owner`, and only at
end-of-run. `Coordinator.status/0` is a synchronous poll. However, rich phase
signals already exist as `:telemetry` events emitted by `FeatureRunner`:
`[:speckit, :phase, :start|:stop|:exception]` and `[:speckit, :feature, :terminal]`
(`SpeckitOrchestrator.Telemetry.events/0`).

**Decision**: Introduce a boot-started `ConsoleProjection` GenServer that:
1. attaches a `:telemetry` handler to `Telemetry.events/0` at startup;
2. folds each event into a per-feature read-model (current phase, per-phase
   outcome/cost, a bounded recent-events feed) via a **pure** `ConsoleReadModel`
   function;
3. broadcasts the changed slice on a `Phoenix.PubSub` topic (`"console:run"`);
4. runs a reconcile tick (≤2 s) that re-reads `Coordinator.status/0` +
   `Ledger.snapshot/1` and merges, so state converges to authoritative even when
   it changes from outside the console (FR-033 / SC-005).

LiveViews `subscribe` on mount, seed from `Coordinator.status/0` +
`Ledger.snapshot/1` + `ConsoleProjection.read/0`, and apply broadcast diffs.

**Rationale**: The telemetry stream is the lowest-latency signal for phase moves
(SC-002). PubSub decouples N LiveViews from the single projection. The reconcile
tick is the safety net for the "authoritative wins" requirement and for state the
telemetry stream doesn't carry (e.g. a run started/stopped out of band).
`Phoenix.PubSub` is already a transitive dep (via `jido_signal`) — promote it to a
direct dep.

**Alternatives rejected**: each LiveView attaching its own telemetry handler
(handler churn on mount/unmount, duplicated fold, no shared bounded feed); pure
polling (higher latency, misses the cheap phase-start signal).

## R3. The "current phase" gap

**Finding**: `Coordinator.status/0`'s `per_feature` carries `%{status, elapsed_ms}`
but **not** the feature's current pipeline phase. The seven-phase progress
indicator (FR-007 / FR-008) and per-phase timeline (FR-011) therefore cannot come
from the Coordinator snapshot.

**Decision**: The `ConsoleProjection` derives current phase and per-phase
outcome/cost from the telemetry stream: `[:speckit, :phase, :start]` sets the
active phase (`meta.phase`, `meta.model`); `:stop` records that phase's
`outcome`/`cost` and advances; `[:speckit, :feature, :terminal]` finalizes. Phase
order is the authoritative `Pipeline.phases/0`:
`[:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge]`. This is the
sole piece of run state the console *computes* rather than reads — and it is a
projection of authoritative events, not a second source of truth.

## R4. Forward-only config apply (FR-032 / FR-037)

**Finding**: `Config` accessors all read `Application.get_env/3` **at call time**.
`Config.model_for/1` is called per phase inside `FeatureRunner`, so a change to the
`:models` app env naturally takes effect only for phases not yet started —
forward-only for free. But `max_concurrency` is captured into `Coordinator` state
(`cap`) at run start, and `budget` into `Ledger` state at start; changing app env
alone does not retune a running Coordinator/Ledger.

**Decision**: Split by mechanism, all forward-only:
- **Model routing** → `Application.put_env(:speckit_orchestrator, :models, …)`.
  Effect is inherently forward-only (next `model_for/1` call). No running-process
  change needed.
- **Max concurrency** → add `Coordinator.set_cap/2` (a `GenServer.call` that
  updates `state.cap`); the next `Release.next_wave` uses the new cap → forward-only
  wave sizing. Also mirror into app env for consistency of display.
- **Budget** → add `Ledger.set_budget/2` (updates `state.budget`); subsequent
  `reserve`/`breaker_tripped?` decisions use it → forward-only breaker behavior.
- **PR workflow / base / remote** → app env; PR mode forces effective cap to 1
  (surfaced), and is only fully meaningful at run start, so the Config view shows
  it and applies base/remote to the current run's later PRs where applicable.

These two tiny setters (`Coordinator.set_cap/2`, `Ledger.set_budget/2`) are the
**only** backend additions beyond the web tree; both are additive and preserve the
drain-don't-kill invariants (a lowered budget can trip the breaker on the *next*
decision but never kills an in-flight phase — SC-007). The live-config contract
(`contracts/live_config.md`) fixes precedence and the never-retroactive rule.

**Alternatives rejected**: restart the Coordinator/Ledger on a config change
(kills in-flight work — violates Principle IV); persist config as cross-run
defaults (violates FR-037's "not persisted").

## R5. Transcript reading

**Finding**: `SpeckitOrchestrator.Transcripts` is **write-only** — it has no
list/read function. Durable transcripts live at
`<Config.transcript_root()>/<feature_id>/NN-<phase>.md` (the copy that survives
worktree teardown).

**Decision**: The Transcripts view (and a small `console` filesystem helper) globs
`<transcript_root>/<feature_id>/*.md`, maps `NN-<phase>` filenames to the phase
picker, reads the selected file, and shows its absolute path (FR-027). A phase the
feature hasn't reached has no file → the view shows an explicit "not yet written"
state, never a blank document (FR-028). Read-only; no change to `Transcripts`.

## R6. Pipeline DAG layout

**Decision**: Layered top-down layout computed server-side. Node depth = longest
prerequisite chain (features with no prereqs at layer 0; each node one layer below
its deepest prereq). Edges come from each feature's `prereqs` (forward) /
`Backlog.dependents/1` (reverse). Render as inline SVG/HTML in the LiveView; node
color = lifecycle status (shared palette). At ~7 nodes no graph-layout library is
warranted.

**Rationale**: Deterministic, dependency-driven placement answers the "why isn't X
running yet?" question (US4) and reuses existing prereq data. Node selection opens
the same feature drawer (FR-026) — one drawer component, two entry points.

## R7. Access / bind / no-auth (FR-035)

**Decision**: Bandit endpoint bound to `127.0.0.1` (configurable to a trusted
interface), no authentication pipeline, no accounts. LiveView's session/CSRF token
stays enabled (default) for socket integrity, but there is no login. This is
explicitly scoped to a single trusted local operator; multi-user/remote exposure
is out of scope for v1 and would require revisiting auth before changing the bind.

## R8. No active run / lifecycle edges

**Finding**: `Coordinator` is started **per-run** under a registered name and does
not exist between runs (`Process.whereis/1` → `nil`); a new `run/1` stops the prior
one first.

**Decision**: Every view treats an absent Coordinator as the explicit
"no active run" state (FR-036 / SC-006), from which only the Trigger and Config
views are actionable. When a run finishes, `finished?: true` + the final `report`
render a drained/completed run (final counts + spend) rather than a still-live
screen (edge case / SC-006). The bounded recent-events feed caps its length
(edge case).

## Resolved unknowns summary

| Unknown | Resolution |
|---------|-----------|
| Frontend stack | Phoenix LiveView + Bandit, no Ecto (R1) |
| Real-time transport | telemetry → ConsoleProjection → PubSub, reconcile tick (R2) |
| Current phase source | derived from phase telemetry, order = `Pipeline.phases/0` (R3) |
| Forward-only config | app env + `Coordinator.set_cap/2` + `Ledger.set_budget/2` (R4) |
| Transcript access | glob `<transcript_root>/<id>/*.md`; Transcripts stays write-only (R5) |
| DAG rendering | server-side layered layout from prereqs, inline SVG (R6) |
| Access model | loopback bind, no auth (R7) |
| No-run / drained states | absent Coordinator = no-run; `finished?`+report = drained (R8) |
