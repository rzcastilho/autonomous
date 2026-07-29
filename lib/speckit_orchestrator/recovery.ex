defmodule SpeckitOrchestrator.Recovery do
  @moduledoc """
  Thin orchestrator wiring the evidence collector to the pure decision table,
  the store correction write, and the operator-facing report. Runs only on
  operator-initiated recovery (`SpeckitOrchestrator.resume_run/2`,
  `SpeckitOrchestrator.resumable/1`) — never automatically on boot (FR-010,
  009 FR-014). See `specs/014-recovery-reconciliation/contracts/recovery-report.md`.

  018: `record` is `Store.Query.run/1`'s run-detail map (`%{run:, features:,
  ...}`) instead of the JSON run manifest — an absent/damaged store record is
  the caller's concern (`Store.Query.run/1`, already handled upstream of this
  call). `run.layout` and each feature's already-atom `status` replace
  `RunManifest.rebuild_layout/2`/`reconstruct/1`; no rebuild, no string
  parsing.
  """

  alias SpeckitOrchestrator.{Feature, Layout, Pipeline, Release}
  alias SpeckitOrchestrator.Recovery.{Evidence, Reconcile, Report}
  alias SpeckitOrchestrator.Store.Writer

  @doc """
  Reconcile every feature in a (already read) store run-detail `record`
  against its durable repository evidence and build the reconciled report —
  **performs no write** (research.md D4/T033). `reconcile_run/2` is
  `plan_run/2` plus persisting genuine `:done` corrections back through the
  store; `Recovery.Rebuild.propose/3` (016 US3) calls the same
  `Evidence`/`Reconcile` pair this function uses, via the shared
  `persisted_status/1`/`store_recorded_status/1` helpers below, so there is
  exactly one reconciliation decision table.

  `opts`:
    * `:git` / `:remote` — forwarded to `Evidence.collect/3` (test seams).
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

  def plan_run(%{run: run, features: features} = detail, opts) do
    layout = run.layout
    run_shape = run.scope

    {rows, statuses, resume_phases, conflicts} =
      Enum.reduce(features, {[], %{}, %{}, []}, fn feature_record, acc ->
        reconcile_feature(feature_record, run_shape, opts, acc)
      end)

    feature_structs = Enum.map(features, &to_feature/1)

    report = %Report{
      features: Enum.reverse(rows),
      conflicts: Enum.reverse(conflicts),
      next_runnable: next_runnable(feature_structs, statuses),
      spend: spend_of(detail),
      run_shape: run_shape
    }

    {:ok,
     %{
       statuses: statuses,
       report: report,
       resume_phases: resume_phases,
       features: feature_structs,
       layout: layout
     }}
  end

  def plan_run(_record, _opts), do: {:error, :corrupt}

  # T040: the run's own `spend_usd` is only set at `close_run/3` — an
  # in-flight run being reconciled *before* a resume is still `0.0` there,
  # so the report's spend is the cost-entry roll-up instead (attributable
  # across a resume, same source `restore_ledger/1` seeds the `Ledger` from).
  defp spend_of(%{cost_entries: entries}) do
    Enum.reduce(entries, 0.0, &(&1.amount_usd + &2))
  end

  defp spend_of(_detail), do: 0.0

  @doc """
  `plan_run/2` plus persisting through the store any feature reconciliation
  proved genuinely `:done` but the store did not yet record as terminal
  (unchanged return shape for existing callers — `resume/2`, `resume_run/1`,
  `resumable/1`; research.md D4). A `{:resume, phase}`/`{:conflict, _}`
  reconciliation is resume-time-only classification with nothing to persist
  — the store already holds `:pending` for a feature not yet terminal.

  `opts`: same as `plan_run/2`, plus:
    * `:writer` — module implementing `Store.Writer`'s write API (default
      `Store.Writer`; tests inject a fake to avoid store writes).
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

  def reconcile_run(%{run: run} = record, opts) do
    with {:ok, plan} <- plan_run(record, opts) do
      write_corrections(run.key, plan.report.features, opts)
      {:ok, Map.take(plan, [:statuses, :report, :resume_phases])}
    end
  end

  def reconcile_run(record, opts), do: plan_run(record, opts)

  # ---- per-feature fold ------------------------------------------------------

  defp reconcile_feature(
         feature_record,
         run_shape,
         opts,
         {rows, statuses, resume_phases, conflicts}
       ) do
    feature = to_feature(feature_record)
    feature_recorded = store_recorded_status(feature_record)
    evidence = Evidence.collect(feature, feature_record, opts)
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

  # A store `feature_run` never records `:running` explicitly (no writer
  # transitions it there) — a feature that has executed at least one phase
  # (a checkpoint or a recorded phase attempt exists) but has no terminal
  # status is exactly the pre-018 `"running"` case: interrupted mid-run, not
  # never-released. `Reconcile.status/3`'s clause 5 (mid-run resume) depends
  # on this distinction, so it is derived here rather than trusting the
  # store's coarser `:pending` at face value.
  @doc false
  @spec store_recorded_status(map()) :: Feature.status()
  def store_recorded_status(%{status: :pending} = f) do
    if f.checkpoint != nil or f.phase_attempts != [], do: :running, else: :pending
  end

  def store_recorded_status(%{status: status}), do: status

  # Public — `Recovery.Rebuild.propose/3` (016 US3) reuses this exact
  # store-record -> `%Feature{}` mapping (D9: no second decision table).
  @doc false
  @spec to_feature(map()) :: Feature.t()
  def to_feature(f),
    do: %Feature{
      id: f.feature_id,
      number: Map.get(f, :number) || String.to_integer(f.feature_id),
      slug: f.slug,
      path: f.path,
      group: Map.get(f, :group, :backlog),
      created_at: Map.get(f, :created_at)
    }

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

  # ---- store correction write (018) ------------------------------------------

  # Persists only a genuine `:done` correction — reconciliation proved a
  # feature actually finished (a done-signal in evidence) that the store did
  # not yet record as terminal, e.g. after a persistence-failure drain
  # (FR-010a) left the last write short. `{:resume, phase}`/`{:conflict, _}`
  # are resume-time-only classifications with nothing to persist — the store
  # already holds `:pending` correctly for a non-terminal feature.
  defp write_corrections(run_key, feature_rows, opts) do
    writer = Keyword.get(opts, :writer, Writer)

    Enum.each(feature_rows, fn row ->
      if row.reconciled == :done and row.recorded != :done do
        writer.record_feature_terminal(run_key, row.id, :done, :reconciled_done_signal, [])
      end
    end)
  end

  # ---- next_runnable ----------------------------------------------------------

  # A read-only preview of what would release next under the corrected
  # statuses — the actual breaker is enforced live by the Coordinator on
  # continuation; this uses an untripped breaker so the preview reflects
  # ordering/status correctness, not in-flight scheduling. `Release.next/3`
  # is the one-feature-at-a-time decision (FR-006, no cap parameter). Public
  # — `Recovery.Rebuild.propose/3` previews the same way over its (possibly
  # larger, repaired) union feature set.
  @doc false
  @spec next_runnable([Feature.t()], %{String.t() => Feature.status()}) :: [String.t()]
  def next_runnable(features, statuses) do
    case Release.next(features, statuses, false) do
      {:release, feature} -> [feature.id]
      _ -> []
    end
  end
end
