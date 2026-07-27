defmodule SpeckitOrchestrator.Recovery do
  @moduledoc """
  Thin orchestrator wiring the evidence collector to the pure decision table,
  the manifest rewrite, and the operator-facing report. Runs only on
  operator-initiated recovery (`SpeckitOrchestrator.resume_run/2`,
  `SpeckitOrchestrator.resumable_run/0`) — never automatically on boot
  (FR-010, 009 FR-014). See
  `specs/014-recovery-reconciliation/contracts/recovery-report.md`.
  """

  alias SpeckitOrchestrator.{Config, Feature, Layout, Pipeline, Release, RunManifest}
  alias SpeckitOrchestrator.Recovery.{Evidence, Reconcile, Report}

  @doc """
  Reconcile every feature in a (already read) run manifest `record` against
  its durable repository evidence and build the reconciled report —
  **performs no write** (research.md D4/T033). `reconcile_run/2` is
  `plan_run/2` plus the manifest rewrite; `Recovery.Rebuild.propose/3` (016
  US3) calls the same `Evidence`/`Reconcile` pair this function uses, via
  the shared `run_shape_of/1`/`recorded_statuses/1`/`persisted_status/1`
  helpers below, so there is exactly one reconciliation decision table.

  `opts`:
    * `:repo` — repo path for layout rebuild (default `Config.repo/0`).
    * `:git` / `:remote` — forwarded to `Evidence.collect/3` (test seams).

  A malformed `record` (missing `"features"`/`"statuses"`) fails loud as
  `{:error, :corrupt}` rather than fabricating a run (Principle II) — a
  missing/absent manifest is the caller's concern (`RunManifest.read/0`,
  already handled upstream of this call).
  """
  @spec plan_run(map(), keyword()) ::
          {:ok,
           %{
             statuses: %{String.t() => Feature.status()},
             report: Report.t(),
             resume_phases: %{String.t() => Pipeline.phase()},
             features: [Feature.t()],
             layout: Layout.t() | nil
           }}
          | {:error, term()}
  def plan_run(record, opts \\ [])

  def plan_run(%{"features" => _, "statuses" => _} = record, opts) do
    repo = Keyword.get(opts, :repo, Config.repo())
    layout = RunManifest.rebuild_layout(record, repo)
    run_shape = run_shape_of(record)
    recorded = recorded_statuses(record)

    {features, _legacy_statuses} = RunManifest.reconstruct(record)

    {rows, statuses, resume_phases, conflicts} =
      Enum.reduce(features, {[], %{}, %{}, []}, fn feature, acc ->
        reconcile_feature(feature, recorded, layout, run_shape, opts, acc)
      end)

    report = %Report{
      features: Enum.reverse(rows),
      conflicts: Enum.reverse(conflicts),
      next_runnable: next_runnable(features, statuses),
      spend: Map.get(record, "spend", 0),
      run_shape: run_shape
    }

    {:ok,
     %{
       statuses: statuses,
       report: report,
       resume_phases: resume_phases,
       features: features,
       layout: layout
     }}
  end

  def plan_run(_record, _opts), do: {:error, :corrupt}

  @doc """
  `plan_run/2` plus the manifest rewrite with the corrected statuses
  (unchanged behaviour/return shape for existing callers — `resume/2`,
  `resume_run/1`, `resumable_run/0`; research.md D4).

  `opts`: same as `plan_run/2`, plus:
    * `:manifest` — module implementing `RunManifest.write/1` (default
      `RunManifest`; tests inject a fake to avoid disk writes).
  """
  @spec reconcile_run(map(), keyword()) ::
          {:ok,
           %{
             statuses: %{String.t() => Feature.status()},
             report: Report.t(),
             resume_phases: %{String.t() => Pipeline.phase()}
           }}
          | {:error, term()}
  def reconcile_run(record, opts \\ [])

  def reconcile_run(record, opts) do
    with {:ok, plan} <- plan_run(record, opts) do
      rewrite_manifest(record, plan.features, plan.statuses, plan.layout, opts)
      {:ok, Map.take(plan, [:statuses, :report, :resume_phases])}
    end
  end

  # ---- per-feature fold ------------------------------------------------------

  defp reconcile_feature(
         feature,
         recorded,
         layout,
         run_shape,
         opts,
         {rows, statuses, resume_phases, conflicts}
       ) do
    feature_recorded = Map.get(recorded, feature.id, :pending)
    evidence = Evidence.collect(feature, layout, opts)
    reconciled = Reconcile.status(feature_recorded, evidence, run_shape)
    {status_atom, resume_phase} = persisted_status(reconciled)

    row = %{
      id: feature.id,
      slug: feature.slug,
      recorded: feature_recorded,
      reconciled: reconciled,
      resume_phase: resume_phase,
      corrected?: feature_recorded != reconciled
    }

    statuses = Map.put(statuses, feature.id, status_atom)

    resume_phases =
      if resume_phase, do: Map.put(resume_phases, feature.id, resume_phase), else: resume_phases

    conflicts =
      case reconciled do
        {:conflict, reason} -> [%{id: feature.id, reason: reason} | conflicts]
        _ -> conflicts
      end

    {[row | rows], statuses, resume_phases, conflicts}
  end

  # Maps a `Reconcile.result()` onto the `Feature.status()` persisted to the
  # manifest, plus the resume phase carried alongside it (data-model.md
  # "Entity: Reconciled status" mapping table). Public (not `defp`) —
  # `Recovery.Rebuild.propose/3` (016 US3) reuses this exact mapping so a
  # rebuild proposal's statuses agree with an ordinary resume's (D4/D9: no
  # second decision table).
  @doc false
  @spec persisted_status(Reconcile.result()) :: {Feature.status(), Pipeline.phase() | nil}
  def persisted_status(:done), do: {:done, nil}
  def persisted_status({:resume, phase}), do: {:running, phase}
  def persisted_status(:pending), do: {:pending, nil}
  def persisted_status(:escalated), do: {:escalated, nil}
  def persisted_status(:halted), do: {:halted, nil}
  def persisted_status(:failed), do: {:failed, nil}
  def persisted_status({:conflict, _reason}), do: {:blocked, nil}
  def persisted_status(:blocked), do: {:blocked, nil}

  # ---- manifest rewrite -------------------------------------------------------

  # Immediately rewrites the manifest with corrected statuses, preserving
  # features/context/spend/segment/scope verbatim (FR-009) — this rewrite runs
  # no phase and spends no budget (FR-010).
  defp rewrite_manifest(record, features, statuses, layout, opts) do
    writer = Keyword.get(opts, :manifest, RunManifest)

    writer.write(%{
      features: features,
      statuses: statuses,
      context: Map.get(record, "context", %{}),
      spend: Map.get(record, "spend", 0),
      updated_at: System.system_time(),
      layout: layout,
      segment: Map.get(record, "segment")
    })
  end

  # ---- next_runnable ----------------------------------------------------------

  # A read-only preview of what would release next under the corrected
  # statuses — the actual cap/breaker are enforced live by the Coordinator on
  # continuation; this uses the configured cap and an untripped breaker so the
  # preview reflects DAG/status correctness, not in-flight scheduling. Public
  # — `Recovery.Rebuild.propose/3` previews the same way over its (possibly
  # larger, repaired) union feature set.
  @doc false
  @spec next_runnable([Feature.t()], %{String.t() => Feature.status()}) :: [String.t()]
  def next_runnable(features, statuses) do
    features
    |> Release.next_wave(statuses, Config.max_concurrency(), false)
    |> Enum.map(& &1.id)
  end

  # ---- record parsing ---------------------------------------------------------

  # Public — shared with `Recovery.Rebuild.propose/3` so a rebuild proposal
  # reconciles under the same done-signal formula (`Reconcile.done_signal?/2`
  # is shape-aware) as an ordinary resume.
  @doc false
  @spec run_shape_of(map()) :: Reconcile.run_shape()
  def run_shape_of(%{"scope" => %{"breakdown" => slug}}) when is_binary(slug),
    do: {:breakdown, slug}

  def run_shape_of(_record), do: :ad_hoc

  # Never `String.to_atom/1` on file-sourced content (atom-table safety) — an
  # explicit mapping over the fixed, known status vocabulary, mirroring
  # `RunManifest`'s own `reconstruct_status/1` but preserving `"running"` as
  # `:running` (this feature's whole point is telling apart a stale `running`
  # from a genuinely mid-run one, not collapsing them upstream). Public —
  # `Recovery.Rebuild.propose/3` reuses this to determine each unioned
  # feature's recorded input (D9: no second decision table).
  @doc false
  @spec recorded_statuses(map()) :: %{String.t() => Feature.status()}
  def recorded_statuses(%{"statuses" => statuses}) do
    Map.new(statuses, fn {id, status} -> {id, parse_recorded_status(status)} end)
  end

  def recorded_statuses(_record), do: %{}

  defp parse_recorded_status("done"), do: :done
  defp parse_recorded_status("running"), do: :running
  defp parse_recorded_status("pending"), do: :pending
  defp parse_recorded_status("escalated"), do: :escalated
  defp parse_recorded_status("halted"), do: :halted
  defp parse_recorded_status("failed"), do: :failed
  defp parse_recorded_status("blocked"), do: :blocked
  defp parse_recorded_status(_other), do: :pending
end
