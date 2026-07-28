defmodule SpeckitOrchestrator.Coordinator do
  @moduledoc """
  Run-level control plane. Holds the backlog and per-feature statuses, releases
  features in dependency-and-cap-respecting waves, reacts to each feature's
  terminal notification, and emits a final report when the run drains.

  ## Design note (deviation from the plan's "Jido agent + actions")

  The Coordinator is a plain `GenServer`, not a Jido agent. It is the supervisor
  of Task-based `FeatureRunner`s reacting to asynchronous `{:finished, ...}`
  notifications — a textbook GenServer. Modelling it as a Jido agent would push
  process-spawning into action bodies, which the plan itself flags as a purity
  hazard. Jido remains the substrate for the autonomous units (`FeatureAgent`).

  The runner-spawning is an injected seam (`:runner`) so the wave/DAG/breaker
  logic is fully unit-testable without a CLI, worktrees, or agents. The facade
  (`SpeckitOrchestrator.run/0`) supplies the real runner.

  ## Breaker

  A tripped `Ledger` breaker releases **no new** features; in-flight features
  drain (finish their current phase, then halt — enforced in `FeatureRunner`).
  When the in-flight set empties with nothing releasable, the run finalizes;
  undelivered `:pending` features are reported as `blocked` or `not_started`.

  ## Persistence (018)

  The run record itself is opened by the caller (`SpeckitOrchestrator.run/1`,
  before this process starts — the runner closures it hands to `:runner`
  need the same `run_key` this process holds) via
  `Store.Writer.open_run/2`. The Coordinator's own store touch-points are:
  a tripped `Store.Health` — checked in `advance/1` at the same point as the
  breaker, releasing nothing new — and `Store.Writer.close_run/3` on drain,
  so the run's terminal outcome is durable the moment the report is built.

  The pre-018 `:manifest` seam keeps writing alongside the store through
  Phase 3 — `MissionControlLive`/`PipelineDagLive`/`EscalationsLive` still
  read `RunManifest` until Phase 7 re-points them at `run_detail/1`
  (T074–T077); removed only at the clean break (FR-037, T072), same
  dual-write shape `Transcripts`/`PhaseStep` already use.
  """

  use GenServer

  alias SpeckitOrchestrator.{Feature, Ledger, Release, RunContext, RunManifest}
  alias SpeckitOrchestrator.Store.{Health, Writer}

  @type status :: Feature.status()

  defstruct features: %{},
            statuses: %{},
            inflight: MapSet.new(),
            started_at: %{},
            cap: 2,
            ledger: nil,
            runner: nil,
            owner: nil,
            self_pid: nil,
            finished?: false,
            report: nil,
            manifest: nil,
            run_key: nil,
            context: %{},
            layout: nil

  # ---- Client API ---------------------------------------------------------

  @doc """
  Start a run. Options:

    * `:features` — list of `%Feature{}` (the validated backlog). Required.
    * `:max_concurrency` — cap (default `Config.max_concurrency/0`).
    * `:ledger` — `Ledger` server for the breaker (optional; no breaker if nil).
    * `:runner` — `fun (feature, notify)` that starts the feature's work and
      arranges for `notify.(id, status, reason)` on terminal. Required.
    * `:owner` — pid to receive `{:run_complete, report}` (optional).
    * `:name` — process name (optional).
    * `:statuses` — seed `%{feature_id => status}` map (default: all
      `:pending`) — lets a crash-recovered run reconstruct which features are
      already `:done`/diverted so they are never re-released (FR-006, SC-002).
    * `:run_key` — this run's store `{repo_id, run_id}` (018), already opened
      by the caller via `Store.Writer.open_run/2`; `nil` for a store-less
      test Coordinator, in which case the health check and `close_run/3` are
      silent no-ops.
    * `:context` — the run-shaping context (`RunContext.t()` or its map)
      recorded into the manifest alongside each write (FR-007), also
      reported in `status/0`'s snapshot.
    * `:manifest` — module implementing `RunManifest`'s `write/1` (default
      `RunManifest`; tests inject a fake). Written on `init`, each
      `spawn_feature`, and each feature's `{:finished, ...}` notification —
      best-effort, never affects wave logic. Kept alongside the store
      through Phase 3 (see moduledoc).
    * `:layout` — the run's resolved `%Layout{}` (`RepoIdentity` + `Layout`,
      FR-011), resolved once at facade preflight and held here so every
      runner spawned for this run carries it (optional; `nil` for tests
      without one).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Current run snapshot: statuses, in-flight ids, spend, finished?/report."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Notify the coordinator a feature reached a terminal status."
  @spec notify(GenServer.server(), String.t(), status(), term()) :: :ok
  def notify(server, id, status, reason),
    do: GenServer.cast(server, {:finished, id, status, reason})

  @doc """
  Live-config apply (`contracts/live_config.md`): update the wave cap for
  subsequent releases. Forward-only — `Release.next_wave` picks up the new
  cap at its next computation; never affects in-flight work.

  Refused with `{:error, :stacked_run}` when the run is a stacked PR run and
  `n > 1`: that shape pins the cap to 1 so each feature can branch from the
  previous one's published branch (`run_stacked/3`), and releasing a second
  feature concurrently would race `StackTracker` and stack a PR on the wrong
  base. Lowering back to 1 is always allowed.
  """
  @spec set_cap(GenServer.server(), pos_integer()) :: :ok | {:error, :stacked_run}
  def set_cap(server \\ __MODULE__, n) when is_integer(n) and n >= 1 do
    GenServer.call(server, {:set_cap, n})
  end

  # ---- Server -------------------------------------------------------------

  @impl true
  def init(opts) do
    features = Keyword.fetch!(opts, :features)
    runner = Keyword.fetch!(opts, :runner)

    state = %__MODULE__{
      features: Map.new(features, &{&1.id, &1}),
      statuses: Keyword.get(opts, :statuses, Map.new(features, &{&1.id, :pending})),
      cap: Keyword.get(opts, :max_concurrency, default_cap()),
      ledger: Keyword.get(opts, :ledger),
      runner: runner,
      owner: Keyword.get(opts, :owner),
      manifest: Keyword.get(opts, :manifest, RunManifest),
      run_key: Keyword.get(opts, :run_key),
      context: Keyword.get(opts, :context, %{}),
      layout: Keyword.get(opts, :layout),
      self_pid: self()
    }

    write_manifest(state)

    {:ok, state, {:continue, :release}}
  end

  @impl true
  def handle_continue(:release, state), do: {:noreply, advance(state)}

  @impl true
  def handle_cast({:finished, id, status, _reason}, state) do
    state = %{
      state
      | statuses: Map.put(state.statuses, id, status),
        inflight: MapSet.delete(state.inflight, id)
    }

    write_manifest(state)

    {:noreply, advance(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, snapshot(state), state}
  end

  # The stacked PR run's cap-1 invariant outranks a live-config edit: refuse
  # wholly (no cap change, no app-env mirror) rather than silently clamping,
  # so the operator learns the edit did not take (Constitution II).
  def handle_call({:set_cap, n}, _from, state) do
    if n > 1 and RunContext.stacked?(state.context) do
      {:reply, {:error, :stacked_run}, state}
    else
      Application.put_env(:speckit_orchestrator, :max_concurrency, n)
      {:reply, :ok, %{state | cap: n}}
    end
  end

  # ---- orchestration ------------------------------------------------------

  # Release everything the DAG + cap + breaker allow, then check for completion.
  defp advance(%__MODULE__{finished?: true} = state), do: state

  defp advance(state) do
    wave =
      Release.next_wave(
        feature_list(state),
        state.statuses,
        state.cap,
        breaker_tripped?(state) or store_unwritable?(state)
      )

    state = Enum.reduce(wave, state, &spawn_feature/2)
    maybe_finish(state)
  end

  defp spawn_feature(%Feature{id: id} = feature, state) do
    notify = fn fid, status, reason -> notify(state.self_pid, fid, status, reason) end
    state.runner.(feature, notify)

    new_state = %{
      state
      | statuses: Map.put(state.statuses, id, :running),
        inflight: MapSet.put(state.inflight, id),
        started_at: Map.put(state.started_at, id, now_ms())
    }

    write_manifest(new_state)

    new_state
  end

  # The run ends when nothing is in flight and nothing more can be released
  # (all remaining pending features are blocked, or the breaker/persistence
  # drained them). Closes the store's run record on drain (018, R7 "run
  # drained" boundary) — but ONLY when every feature actually reached `:done`
  # (`run_outcome/1` is `:all_done`). A gate divert (escalated/halted),
  # `:failed`, or anything left `blocked`/`not_started` (a breaker or
  # persistence-failure drain) is exactly what `resume/2`/`resume_run/1`
  # exist to revisit — closing the record there would make
  # `Store.current_run_key/1` unable to find it again, breaking resume
  # outright. The run instead stays `:in_flight` until either a later wave
  # of THIS same Coordinator finishes it for real, or a fresh `run/1`
  # supersedes it. A no-op when this run isn't store-backed (`run_key: nil`,
  # most test Coordinators).
  defp maybe_finish(state) do
    releasable =
      Release.next_wave(
        feature_list(state),
        state.statuses,
        state.cap,
        breaker_tripped?(state) or store_unwritable?(state)
      )

    if MapSet.size(state.inflight) == 0 and releasable == [] do
      report = build_report(state)
      maybe_close_run(state, report)
      if state.owner, do: send(state.owner, {:run_complete, report})
      %{state | finished?: true, report: report}
    else
      state
    end
  end

  defp maybe_close_run(%__MODULE__{run_key: nil}, _report), do: :ok

  defp maybe_close_run(%__MODULE__{run_key: run_key}, report) do
    if run_outcome(report) == :all_done do
      _ = Writer.close_run(run_key, :all_done, spend_usd: report.spend)
    end

    # Independent of whether this drain also closed the run — a write
    # failure anywhere during this run's lifetime makes its completeness
    # suspect regardless of how "done" the final report looks, so
    # `resumable/1` reports `gap_possible?` either way (FR-010a).
    if Health.failed?(), do: Writer.flag_record_incomplete(run_key, store_health_reason())
    :ok
  end

  defp run_outcome(%{halted: h}) when h != [], do: :halted
  defp run_outcome(%{escalated: e}) when e != [], do: :escalated
  defp run_outcome(%{failed: f}) when f != [], do: :failed
  defp run_outcome(%{blocked: b, not_started: n}) when b != [] or n != [], do: :mixed
  defp run_outcome(_report), do: :all_done

  defp store_health_reason do
    case Health.status() do
      {:failed, reason, _at} -> reason
      :ok -> :unknown
    end
  end

  # ---- report -------------------------------------------------------------

  defp build_report(state) do
    grouped =
      Enum.group_by(state.statuses, fn {_id, status} -> classify(state, status) end, fn {id, _} ->
        id
      end)

    %{
      done: ids(grouped, :done),
      escalated: ids(grouped, :escalated),
      halted: ids(grouped, :halted),
      failed: ids(grouped, :failed),
      blocked: blocked_ids(state),
      not_started: not_started_ids(state),
      spend: spend(state),
      breaker_tripped: breaker_tripped?(state)
    }
  end

  # A pending feature is `:blocked` when a prereq ended non-done, else it simply
  # never got released (breaker drain / cap exhaustion at finalize).
  defp classify(_state, status) when status in [:done, :escalated, :halted, :failed], do: status
  defp classify(_state, _pending), do: :pending

  defp blocked_ids(state) do
    for {id, :pending} <- state.statuses,
        Release.blocked?(state.features[id], state.statuses),
        do: id
  end

  defp not_started_ids(state) do
    for {id, :pending} <- state.statuses,
        not Release.blocked?(state.features[id], state.statuses),
        do: id
  end

  defp ids(grouped, key), do: grouped |> Map.get(key, []) |> Enum.sort()

  # ---- helpers ------------------------------------------------------------

  defp snapshot(state) do
    per_feature =
      Map.new(state.statuses, fn {id, status} ->
        feature = state.features[id]

        {id,
         %{
           status: status,
           elapsed_ms: elapsed_ms(state, id),
           slug: feature && feature.slug,
           prereqs: (feature && feature.prereqs) || []
         }}
      end)

    %{
      statuses: state.statuses,
      per_feature: per_feature,
      totals: state.statuses |> Map.values() |> Enum.frequencies(),
      inflight: MapSet.to_list(state.inflight),
      spend: spend(state),
      breaker_tripped: breaker_tripped?(state),
      finished?: state.finished?,
      report: state.report,
      layout: state.layout,
      # This run's own shape, so consumers (the console status bar) report what
      # is actually running rather than re-deriving it from live global Config,
      # which any later edit or another run would have moved out from under them.
      cap: state.cap,
      context: state.context
    }
  end

  defp elapsed_ms(state, id) do
    case Map.get(state.started_at, id) do
      nil -> nil
      started -> now_ms() - started
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp feature_list(state), do: Map.values(state.features)

  defp breaker_tripped?(%__MODULE__{ledger: nil}), do: false
  defp breaker_tripped?(%__MODULE__{ledger: ledger}), do: Ledger.breaker_tripped?(ledger)

  # A store-less Coordinator (`run_key: nil`, most tests) never treats the
  # store as unwritable — the seam is inert without a real run to record
  # against, same shape as `breaker_tripped?/1` with a `nil` ledger.
  defp store_unwritable?(%__MODULE__{run_key: nil}), do: false
  defp store_unwritable?(%__MODULE__{run_key: _}), do: Health.failed?()

  defp spend(%__MODULE__{ledger: nil}), do: 0.0
  defp spend(%__MODULE__{ledger: ledger}), do: Ledger.spent(ledger)

  # Best-effort manifest write (Principle I — the seam keeps the wave/DAG/
  # breaker scheduler unit-testable without disk); a write failure never
  # affects wave logic (data-model.md Entity 3). Kept alongside the store
  # through Phase 3 (see moduledoc).
  defp write_manifest(state) do
    state.manifest.write(%{
      features: feature_list(state),
      statuses: state.statuses,
      context: state.context,
      spend: spend(state),
      updated_at: System.system_time(),
      layout: state.layout
    })

    state
  end

  defp default_cap, do: SpeckitOrchestrator.Config.max_concurrency()
end
