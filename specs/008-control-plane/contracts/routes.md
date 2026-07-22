# Contract: Console routes & command surface

The console exposes six LiveView routes behind a fixed left nav, plus a drawer
that is a component (not a route). Each route is a **view/command surface** over
the existing facade — it invokes facade/read functions and renders their results;
it implements no pipeline logic (Constitution I). Endpoint is bound to `127.0.0.1`,
no auth pipeline (FR-035).

## Routes

| Path | LiveView | User story | Reads | Commands (writes) |
|------|----------|-----------|-------|-------------------|
| `/` | `MissionControlLive` | US1 | `Coordinator.status/0`, `Ledger.snapshot/1`, `ConsoleProjection.read/0` | — |
| `/dag` | `PipelineDagLive` | US4 | backlog features + `prereqs`, `Backlog.dependents/1`, status/projection | — |
| `/trigger` | `TriggerLive` | US2 | `Backlog.load!/1` (validate), `Config.*` | `run/1`, `run_spec/2` |
| `/escalations` | `EscalationsLive` | US3 | status (terminal features), `Checkpoint.read/1`, spec `## NEEDS HUMAN` | `resume/2`, `resolve/2` + `run/1` |
| `/transcripts` | `TranscriptsLive` | US5 | filesystem glob `<transcript_root>/<id>/*.md` | — |
| `/config` | `ConfigLive` | US6 | `Config.*`, `Ledger.snapshot/1` | live-config apply (see `live_config.md`) |

The feature drawer (`FeatureDrawerComponent`) is opened from the Mission Control
table row **and** the DAG node (FR-011, FR-026) — one component, two entry points.
It carries the same resume/full-restart actions and transcript link for a
diverted/halted feature (FR-012).

## Global chrome (all routes) — FR-001..FR-005

- **Left nav** (FR-001): six items, active one indicated. Escalations item shows a
  count badge when any feature ∈ `{:escalated, :halted, :failed}`, hidden at zero
  (FR-002).
- **Context** (FR-003): target repo (`Config.repo/0`), `claude` CLI auth health,
  orchestrator runtime health (BEAM node up / Coordinator present).
- **Status bar** (FR-004): run title + mode, cost-breaker gauge
  (`Ledger.snapshot/1`: committed/reserved/budget, proximity color, armed/tripped),
  live clock.
- **Toasts** (FR-005): every command (`run`, `run_spec`, `resume`, `resolve`,
  config apply) confirms via a transient non-blocking notification.

## Command → facade mapping (exact)

| Console action | Facade call | Success | Failure surfaced |
|----------------|-------------|---------|------------------|
| Start backlog run | `run(opts)` | navigate to `/`, toast (FR-018) | `{:error, {:preflight, problems}}` → error toast; DAG-invalid → Start disabled (FR-019) |
| Start single-spec | `run_spec(desc, opts)` | navigate to `/`, toast | `{:error, :empty_description}` → field error (FR-016) |
| Resume escalation | `resume(id, prompt: g, from: p)` | toast, feature re-enters pipeline | `{:error, :no_checkpoint \| :corrupt_checkpoint \| {:unknown_phase, _} \| {:unknown_feature, _}}` → steer to full restart / error (FR-023) |
| Full restart | `resolve(id)` then `run(features: [feature])` | toast, worktree freed, restart from phase 1 | `{:error, _}` → error toast |
| Apply config | live-config setters | toast, gauge/status-bar reflect (FR-030) | out-of-bounds → field error |

## State-fidelity requirements (FR-033, FR-034, SC-005)

- All rendered state derives from the authoritative sources above; on any outside
  change the reconcile tick (≤2 s) converges the view (SC-005).
- Lifecycle colors and the seven-phase order are identical across every surface
  (status strip, table, DAG, drawer, escalations) — one shared palette + one phase
  list (`Pipeline.phases/0`) (FR-034).
- No-active-run (Coordinator absent), empty backlog, invalid DAG, missing
  transcript, and missing/corrupt checkpoint each render a coherent state, never a
  broken layout or silent blank (SC-006).
