defmodule SpeckitOrchestrator.Telemetry do
  @moduledoc """
  Telemetry event names and an optional default logging handler.

  Events (emitted by `FeatureRunner`):

    * `[:speckit, :phase, :start]` — measurements `%{system_time}`, metadata
      `%{feature_id, phase, model, step}`.
    * `[:speckit, :phase, :stop]` — measurements `%{duration}`, metadata adds
      `%{outcome, cost}`.
    * `[:speckit, :phase, :exception]` — measurements `%{duration}`, metadata
      adds `%{kind, reason}`. (Emitted via `:telemetry.span/3`.)
    * `[:speckit, :feature, :terminal]` — measurements `%{cost_total}`, metadata
      `%{feature_id, status, reason}`.

  Events (emitted by `ChunkRunner`, one `:implement` step's chunk loop —
  `specs/015-implement-phase-chunking/contracts/telemetry-chunk.md` §1):

    * `[:speckit, :chunk, :start]` / `:stop` / `:exception` — the
      `[:speckit, :chunk]` `:telemetry.span/3` around one chunk session,
      metadata `%{feature_id, phase: :implement, scope, ordinal, total,
      number, title, attempt, sessions_used, ceiling, model}` (`:stop` adds
      `%{outcome, cost, completed_before, completed_after}`; `:exception`
      adds `%{kind, reason}`).
    * `[:speckit, :chunk, :resolved]` — measurements `%{}`, metadata
      `%{feature_id, match_kind, ordinal, number, title, requested}`.

  Events (emitted by `AnalyzeRunner`, one `:analyze` step's auto-remediation
  loop — `specs/017-analyze-auto-remediation/contracts/telemetry-console.md` §1):

    * `[:speckit, :remediation, :start]` / `:stop` / `:exception` — the
      `[:speckit, :remediation]` `:telemetry.span/3` around one corrective
      attempt, metadata `%{feature_id, phase: :analyze, attempt, limit,
      threshold, findings_count, max_severity, model}` (`:stop` adds
      `%{outcome, cost}`; `:exception` adds `%{kind, reason}`).

    The `[:speckit, :phase]` span for `phase: :analyze` additionally carries
    `attempt` / `limit` **only while the loop is enabled**; with the loop off
    the metadata map is byte-identical to pre-017 (FR-010, SC-007a).

  Events (run-level, no `feature_id`; `specs/016-resume-backlog-scope/contracts/manifest-guard.md`):

    * `[:speckit, :run, :scope_narrowing_refused]` — measurements
      `%{dropped_count}`, metadata `%{segment, recorded, attempted, dropped}`.
      Fires when a write would drop a currently-recorded feature id; the
      write is refused and the existing record is left untouched. Pre-018 —
      the store's write path structurally cannot narrow a run's feature set
      (018), so this event no longer fires; the handler remains harmless.

  Events (emitted by `Store.Writer` — 018, persistence-failure.md): a write
  failure is recorded in `Store.Health` and, so it is observable outside the
  breaker flag too, emitted here:

    * `[:speckit, :store, :write_failed]` — measurements `%{}`, metadata
      `%{reason}`. Fires on any aborted `Store.Writer` transaction, driving
      `FeatureRunner`'s drain check and `Coordinator`'s release check.

  Events (emitted by `SpeckitOrchestrator` — 018 Phase 6,
  contracts/capacity-and-prune.md):

    * `[:speckit, :store, :capacity_refused]` — measurements
      `%{shortfall_bytes, reclaimable_bytes}`, metadata `%{repo}`. Fires when
      `run/1`'s capacity preflight refuses (FR-031b).
    * `[:speckit, :store, :pruned]` — measurements `%{bytes_reclaimed}`,
      metadata `%{repo_id, removed}`. Fires after `prune/1` executes
      (FR-031a) — the only mechanism that removes recorded state.

  Events (emitted by `SpeckitOrchestrator` — 019, FR-018): a completed
  feature's PR publish can fail without failing the run — the local branch
  still becomes the next feature's base regardless — but never merely
  swallowed:

    * `[:speckit, :publish, :failed]` — measurements `%{}`, metadata
      `%{feature_id, reason}`. Fires when `publish_feature/3` (push + PR
      open) fails for a `:done` backlog feature.

  Call `attach_default_logger/0` from `iex` to log every event.
  """

  require Logger

  @phase [:speckit, :phase]
  @chunk [:speckit, :chunk]
  @remediation [:speckit, :remediation]
  @events [
    [:speckit, :phase, :start],
    [:speckit, :phase, :stop],
    [:speckit, :phase, :exception],
    [:speckit, :feature, :terminal],
    [:speckit, :chunk, :start],
    [:speckit, :chunk, :stop],
    [:speckit, :chunk, :exception],
    [:speckit, :chunk, :resolved],
    [:speckit, :remediation, :start],
    [:speckit, :remediation, :stop],
    [:speckit, :remediation, :exception],
    [:speckit, :run, :scope_narrowing_refused],
    [:speckit, :store, :write_failed],
    [:speckit, :store, :capacity_refused],
    [:speckit, :store, :pruned],
    [:speckit, :publish, :failed]
  ]

  @doc "The `:telemetry.span/3` prefix for phase events."
  @spec phase_span() :: [atom()]
  def phase_span, do: @phase

  @doc "The `:telemetry.span/3` prefix for chunk events."
  @spec chunk_span() :: [atom()]
  def chunk_span, do: @chunk

  @doc "The `:telemetry.span/3` prefix for auto-remediation attempt events."
  @spec remediation_span() :: [atom()]
  def remediation_span, do: @remediation

  @doc "All emitted event names."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "Attach a handler that logs every orchestrator event. Idempotent-ish."
  @spec attach_default_logger() :: :ok | {:error, :already_exists}
  def attach_default_logger do
    :telemetry.attach_many("speckit-default-logger", @events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event([:speckit, :phase, :stop], %{duration: dur}, meta, _cfg) do
    Logger.info(
      "phase #{meta.phase} feature=#{meta.feature_id} outcome=#{inspect(meta[:outcome])} " <>
        "cost=#{inspect(meta[:cost])} #{ms(dur)}ms model=#{meta.model}"
    )
  end

  def handle_event([:speckit, :feature, :terminal], meas, meta, _cfg) do
    Logger.info(
      "feature #{meta.feature_id} terminal=#{meta.status} reason=#{inspect(meta.reason)} " <>
        "cost_total=#{inspect(meas.cost_total)}"
    )
  end

  def handle_event([:speckit, :remediation, :stop], %{duration: dur}, meta, _cfg) do
    Logger.info(
      "auto-remediation attempt #{meta.attempt}/#{meta.limit} feature=#{meta.feature_id} " <>
        "outcome=#{inspect(meta[:outcome])} cost=#{inspect(meta[:cost])} #{ms(dur)}ms " <>
        "findings=#{meta.findings_count} threshold=#{meta.threshold}"
    )
  end

  def handle_event([:speckit, :run, :scope_narrowing_refused], _meas, meta, _cfg) do
    Logger.warning(
      "run scope narrowing refused: dropped=#{inspect(meta.dropped)} " <>
        "recorded=#{inspect(meta.recorded)} segment=#{inspect(meta.segment)}"
    )
  end

  def handle_event([:speckit, :store, :write_failed], _meas, meta, _cfg) do
    Logger.error("store write failed: reason=#{inspect(meta.reason)}")
  end

  def handle_event([:speckit, :store, :capacity_refused], meas, meta, _cfg) do
    Logger.warning(
      "store capacity refused run: repo=#{inspect(meta.repo)} " <>
        "shortfall_bytes=#{meas.shortfall_bytes} reclaimable_bytes=#{meas.reclaimable_bytes}"
    )
  end

  def handle_event([:speckit, :store, :pruned], meas, meta, _cfg) do
    Logger.info(
      "store pruned: repo_id=#{meta.repo_id} removed=#{inspect(meta.removed)} " <>
        "bytes_reclaimed=#{meas.bytes_reclaimed}"
    )
  end

  def handle_event([:speckit, :publish, :failed], _meas, meta, _cfg) do
    Logger.warning("feature #{meta.feature_id} PR publish failed: #{inspect(meta.reason)}")
  end

  def handle_event(_event, _meas, _meta, _cfg), do: :ok

  defp ms(native), do: System.convert_time_unit(native, :native, :millisecond)
end
