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
  undelivered `:pending` features are reported `not_started` (019: no
  prerequisites, so nothing is ever `blocked` — see `Release.next/3`).

  ## Stop-on-first-broken-link and parking (019)

  `Release.next/3` returning `{:stopped, id, status}` (a non-done terminal —
  `:escalated`/`:halted`/`:failed` — with the breaker not tripped) means the
  chain broke: once in-flight drains to empty, the Coordinator **parks** the
  run (`Store.Writer.park_run/2`, `:in_flight -> :parked`) instead of closing
  it, and the final report's `stopped_by` names the feature and why
  (FR-017). A breaker/persistence-failure drain is unchanged from pre-019 —
  it stays `:in_flight` (unless every feature reached `:done`) for
  `resume/2`/`resume_run/1` to revisit, never parked.

  ## Persistence (018)

  The run record itself is opened by the caller (`SpeckitOrchestrator.run/1`,
  before this process starts — the runner closures it hands to `:runner`
  need the same `run_key` this process holds) via
  `Store.Writer.open_run/2`. The Coordinator's own store touch-points are:
  a tripped `Store.Health` — checked in `advance/1` at the same point as the
  breaker, releasing nothing new — `Store.Writer.park_run/2` on a genuine
  stop, and `Store.Writer.close_run/3` on an ordinary/breaker drain — so the
  run's terminal outcome is durable the moment the report is built. The
  console reads this same store via `run_detail/1` (`MissionControlLive`/
  `PipelineDagLive`/`EscalationsLive`) rather than any state this process
  holds directly.
  """

  use GenServer

  alias SpeckitOrchestrator.{Feature, Ledger, Release}
  alias SpeckitOrchestrator.Store.{Health, Writer}

  @type status :: Feature.status()

  defstruct features: %{},
            statuses: %{},
            reasons: %{},
            inflight: MapSet.new(),
            started_at: %{},
            ledger: nil,
            runner: nil,
            owner: nil,
            self_pid: nil,
            finished?: false,
            report: nil,
            run_key: nil,
            context: %{},
            layout: nil,
            stopped_by: nil

  # ---- Client API ---------------------------------------------------------

  @doc """
  Start a run. Options:

    * `:features` — list of `%Feature{}` (the validated backlog). Required.
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
    * `:context` — the run-shaping context (`RunContext.t()` or its map),
      reported in `status/0`'s snapshot.
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

  # ---- Server -------------------------------------------------------------

  @impl true
  def init(opts) do
    features = Keyword.fetch!(opts, :features)
    runner = Keyword.fetch!(opts, :runner)

    state = %__MODULE__{
      features: Map.new(features, &{&1.id, &1}),
      statuses: Keyword.get(opts, :statuses, Map.new(features, &{&1.id, :pending})),
      ledger: Keyword.get(opts, :ledger),
      runner: runner,
      owner: Keyword.get(opts, :owner),
      run_key: Keyword.get(opts, :run_key),
      context: Keyword.get(opts, :context, %{}),
      layout: Keyword.get(opts, :layout),
      self_pid: self()
    }

    {:ok, state, {:continue, :release}}
  end

  @impl true
  def handle_continue(:release, state), do: {:noreply, advance(state)}

  @impl true
  def handle_cast({:finished, id, status, reason}, state) do
    state = %{
      state
      | statuses: Map.put(state.statuses, id, status),
        reasons: Map.put(state.reasons, id, reason),
        inflight: MapSet.delete(state.inflight, id)
    }

    {:noreply, advance(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, snapshot(state), state}
  end

  # ---- orchestration ------------------------------------------------------

  # Release the next feature `Release.next/3` allows (one at a time is
  # structural — rule 3 of `next/3`, not a configured cap), then check for
  # completion.
  defp advance(%__MODULE__{finished?: true} = state), do: state

  defp advance(state) do
    state =
      case next_decision(state) do
        {:release, feature} -> spawn_feature(feature, state)
        _ -> state
      end

    maybe_finish(state)
  end

  defp next_decision(state) do
    Release.next(feature_list(state), state.statuses, blocked?(state))
  end

  defp blocked?(state), do: breaker_tripped?(state) or store_unwritable?(state)

  defp spawn_feature(%Feature{id: id} = feature, state) do
    notify = fn fid, status, reason -> notify(state.self_pid, fid, status, reason) end
    state.runner.(feature, notify)

    new_state = %{
      state
      | statuses: Map.put(state.statuses, id, :running),
        inflight: MapSet.put(state.inflight, id),
        started_at: Map.put(state.started_at, id, now_ms())
    }

    new_state
  end

  # The run ends when nothing is in flight and nothing more can be released
  # (all remaining pending features are stopped-behind, or the breaker/
  # persistence drained them). 019: a genuine stop (any non-done terminal,
  # with the breaker NOT masking it) is a **park**, not a drain — the run
  # record moves `:in_flight -> :parked` and the operator resolves it via
  # `continue_run/1`/`end_run/1` (contracts/parked-run.md). A breaker/
  # persistence-failure drain is unchanged from pre-019: it stays
  # `:in_flight` unless every feature actually reached `:done`, so
  # `resume/2`/`resume_run/1` can still find and revisit it. A no-op when
  # this run isn't store-backed (`run_key: nil`, most test Coordinators).
  defp maybe_finish(state) do
    releasable? = match?({:release, _feature}, next_decision(state))

    if MapSet.size(state.inflight) == 0 and not releasable? do
      finish_run(state)
    else
      state
    end
  end

  defp finish_run(state) do
    stopped = stopped_feature(state)
    report = build_report(state, stopped)

    if stopped && not blocked?(state) do
      park_run(state, stopped)
    else
      maybe_close_run(state, report)
    end

    if state.owner, do: send(state.owner, {:run_complete, report})
    %{state | finished?: true, report: report, stopped_by: stopped}
  end

  # The stopper `Release.next/3` would report were the breaker not tripped —
  # computed independently of `next_decision/1` so a tripped breaker (which
  # forces `next/3` to `:none` unconditionally, rule 1) never hides which
  # feature broke the chain from the final report's `stopped_by` (FR-017,
  # contracts/run-start.md § Report — `stopped_by` is non-nil whenever a
  # non-done terminal feature exists at drain, breaker or not).
  defp stopped_feature(state) do
    case Release.next(feature_list(state), state.statuses, false) do
      {:stopped, id, status} -> {id, status, Map.get(state.reasons, id)}
      _ -> nil
    end
  end

  defp park_run(%__MODULE__{run_key: nil}, _stopped), do: :ok

  defp park_run(%__MODULE__{run_key: run_key}, {id, status, reason}) do
    _ = Writer.park_run(run_key, %{stopped_by: id, status: status, reason: reason})
    :ok
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
  defp run_outcome(%{not_started: n}) when n != [], do: :mixed
  defp run_outcome(_report), do: :all_done

  defp store_health_reason do
    case Health.status() do
      {:failed, reason, _at} -> reason
      :ok -> :unknown
    end
  end

  # ---- report -------------------------------------------------------------

  defp build_report(state, stopped) do
    grouped =
      Enum.group_by(state.statuses, fn {_id, status} -> classify(status) end, fn {id, _} -> id end)

    done = ids(grouped, :done)

    %{
      done: done,
      escalated: ids(grouped, :escalated),
      halted: ids(grouped, :halted),
      failed: ids(grouped, :failed),
      not_started: ids(grouped, :pending),
      stopped_by: format_stopped(stopped),
      spend: spend(state),
      breaker_tripped: breaker_tripped?(state),
      advanced_with_findings: advanced_with_findings(state, done)
    }
  end

  # Feature 021: derived from the reasons the Coordinator already retains, so
  # `notify/4`'s arity and the `:runner` seam are unchanged — always a SUBSET
  # of `done`, never a sibling category (FR-008a).
  defp advanced_with_findings(state, done) do
    Enum.filter(done, fn id ->
      match?({:done, :advanced_with_unresolved_findings}, Map.get(state.reasons, id))
    end)
  end

  defp format_stopped(nil), do: nil
  defp format_stopped({id, status, reason}), do: %{feature_id: id, status: status, reason: reason}

  # 019: no prerequisites, so a pending feature that never released is simply
  # `:not_started` (its own `stopped_by` map, if any, says why the chain
  # never reached it) — there is no `:blocked` classification anymore.
  defp classify(status) when status in [:done, :escalated, :halted, :failed], do: status
  defp classify(_pending), do: :pending

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
           slug: feature && feature.slug
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
end
