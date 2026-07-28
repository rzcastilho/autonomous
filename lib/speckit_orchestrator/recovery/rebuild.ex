defmodule SpeckitOrchestrator.Recovery.Rebuild do
  @moduledoc """
  Pure repair proposal for a run record already narrowed by the defect 016
  closes: unions the (possibly narrowed) record's features with the backlog
  on disk, reconciles each unioned feature against durable per-feature
  evidence — reusing `Recovery.Evidence`/`Recovery.Reconcile` and
  `Recovery`'s own `to_feature/1`/`store_recorded_status/1`/`persisted_status/1`
  helpers verbatim (research.md D9: no second decision table) — and reports
  everything it could not reconcile rather than guessing (Principle II). See
  `specs/016-resume-backlog-scope/contracts/record-recovery.md`.

  018: `record` is `Store.Query.run/1`'s run-detail map; `run.layout` and
  each feature's already-atom `status` replace
  `RunManifest.rebuild_layout/2`/`reconstruct/1`.

  Operator-invoked only, via `SpeckitOrchestrator.recover_record/1` — never
  runs automatically inside `resume/2`/`resume_run/1` (FR-019).
  """

  alias SpeckitOrchestrator.{Feature, Pipeline}
  alias SpeckitOrchestrator.Recovery
  alias SpeckitOrchestrator.Recovery.{Evidence, Reconcile, Report}

  @typedoc "Everything `propose/3` could not silently reconcile — reported, never invented."
  @type discrepancy :: %{kind: atom(), id: String.t(), detail: term()}

  @typedoc "The rebuild proposal — the preview payload of `SpeckitOrchestrator.recover_record/1`."
  @type proposal :: %{
          features: [Feature.t()],
          statuses: %{String.t() => Feature.status()},
          resume_phases: %{String.t() => Pipeline.phase()},
          discrepancies: [discrepancy()],
          report: Report.t(),
          source: %{
            record_ids: [String.t()],
            backlog_ids: [String.t()],
            backlog_root: Path.t() | nil
          }
        }

  @doc """
  Build a rebuild proposal from an already-read store run-detail `record`
  (`Store.Query.run/1`'s shape) and an already-loaded `backlog`
  (`Backlog.load!/1`). Pure aside from the evidence collection `opts`
  forward to (`Evidence.collect/3`'s own edge I/O) — never writes anything
  itself; that is `SpeckitOrchestrator.recover_record/1`'s job on `:confirm`.

  `opts`:
    * `:git` / `:remote` — forwarded to `Evidence.collect/3` (test seams).
    * `:backlog_root` — recorded verbatim into `proposal.source` for the
      caller's provenance display.

  ## Union rule

  `features` = `backlog` in backlog order, then any recorded feature the
  backlog does not name, appended in recorded order. Prereqs come from the
  backlog when the backlog names the feature, else from the record.

  ## Per-feature status

  Reconciled by the existing `Evidence` + `Reconcile` pair — the recorded
  status is the record's status where the record names the feature, else
  `:pending`. A feature the backlog no longer names keeps its recorded
  status verbatim (unreconciled — `:absent_from_backlog`); a feature the
  record never named is reconciled fresh from evidence
  (`:absent_from_record`); a `{:conflict, reason}` verdict is reported as
  `:unreconcilable` and seeded `:blocked`.

  Refuses with `{:error, {:inconsistent, discrepancies}}` — no evidence
  collected, nothing else computed — when any unioned feature names a
  prereq outside the union (FR-020): a proposal that cannot even be checked
  for readiness must never be offered for confirmation.
  """
  @spec propose(map(), [Feature.t()], keyword()) ::
          {:ok, proposal()} | {:error, {:inconsistent, [discrepancy()]}}
  def propose(%{run: run, features: store_features}, backlog, opts \\ []) do
    run_shape = run.scope
    feature_records = Map.new(store_features, &{&1.feature_id, &1})

    record_features = Enum.map(store_features, &Recovery.to_feature/1)
    backlog_ids = MapSet.new(backlog, & &1.id)
    record_only = Enum.reject(record_features, &MapSet.member?(backlog_ids, &1.id))
    features = backlog ++ record_only
    union_ids = MapSet.new(features, & &1.id)

    case prereq_discrepancies(features, union_ids) do
      [_ | _] = missing ->
        {:error, {:inconsistent, missing}}

      [] ->
        {:ok,
         build_proposal(
           run,
           features,
           backlog,
           record_features,
           backlog_ids,
           feature_records,
           run_shape,
           opts
         )}
    end
  end

  # ---- proposal assembly -----------------------------------------------------

  defp build_proposal(
         run,
         features,
         backlog,
         record_features,
         backlog_ids,
         feature_records,
         run_shape,
         opts
       ) do
    {rows, statuses, resume_phases, discrepancies} =
      Enum.reduce(features, {[], %{}, %{}, []}, fn feature, acc ->
        reconcile_union_feature(feature, backlog_ids, feature_records, run_shape, opts, acc)
      end)

    discrepancies = Enum.reverse(discrepancies)

    conflicts =
      for %{kind: :unreconcilable, id: id, detail: reason} <- discrepancies,
          do: %{id: id, reason: reason}

    report = %Report{
      features: Enum.reverse(rows),
      conflicts: conflicts,
      next_runnable: Recovery.next_runnable(features, statuses),
      spend: run.spend_usd,
      run_shape: run_shape,
      discrepancies: discrepancies
    }

    %{
      features: features,
      statuses: statuses,
      resume_phases: resume_phases,
      discrepancies: discrepancies,
      report: report,
      source: %{
        record_ids: Enum.map(record_features, & &1.id),
        backlog_ids: Enum.map(backlog, & &1.id),
        backlog_root: Keyword.get(opts, :backlog_root)
      }
    }
  end

  # ---- per-feature fold -------------------------------------------------------

  # In both the record and the backlog: reconcile normally against the
  # record's own recorded status.
  defp reconcile_union_feature(feature, backlog_ids, feature_records, run_shape, opts, acc) do
    feature_record = Map.get(feature_records, feature.id)

    cond do
      MapSet.member?(backlog_ids, feature.id) and feature_record != nil ->
        reconciled_row(
          feature,
          Recovery.store_recorded_status(feature_record),
          feature_record,
          run_shape,
          opts,
          nil,
          acc
        )

      MapSet.member?(backlog_ids, feature.id) ->
        reconciled_row(feature, :pending, nil, run_shape, opts, :absent_from_record, acc)

      true ->
        recorded_status =
          if feature_record, do: Recovery.store_recorded_status(feature_record), else: :pending

        unreconciled_row(feature, recorded_status, acc)
    end
  end

  # "In both" (`extra_kind: nil`) and "backlog only" (`extra_kind:
  # :absent_from_record`) share the same reconcile-from-evidence path; only
  # the recorded input and the resulting discrepancy differ.
  defp reconciled_row(
         feature,
         recorded_status,
         feature_record,
         run_shape,
         opts,
         extra_kind,
         {rows, statuses, resume_phases, discrepancies}
       ) do
    evidence = Evidence.collect(feature, feature_record, opts)
    reconciled = Reconcile.status(recorded_status, evidence, run_shape)
    {status_atom, resume_phase} = Recovery.persisted_status(reconciled)

    row = %{
      id: feature.id,
      slug: feature.slug,
      recorded: if(extra_kind == :absent_from_record, do: nil, else: recorded_status),
      reconciled: reconciled,
      resume_phase: resume_phase,
      corrected?: extra_kind == :absent_from_record or recorded_status != reconciled
    }

    statuses = Map.put(statuses, feature.id, status_atom)

    resume_phases =
      if resume_phase, do: Map.put(resume_phases, feature.id, resume_phase), else: resume_phases

    discrepancies =
      cond do
        extra_kind == :absent_from_record ->
          [%{kind: :absent_from_record, id: feature.id, detail: reconciled} | discrepancies]

        match?({:conflict, _reason}, reconciled) ->
          {:conflict, reason} = reconciled
          [%{kind: :unreconcilable, id: feature.id, detail: reason} | discrepancies]

        true ->
          discrepancies
      end

    {[row | rows], statuses, resume_phases, discrepancies}
  end

  # "Record only" (the backlog no longer names this feature): kept verbatim,
  # unreconciled (contracts/record-recovery.md "record only" row) — no
  # evidence collected, no resume phase inferred. If this feature is
  # confirmed back into the record, the next ordinary `resume_run/1` fully
  # reconciles it fresh from evidence, same as any other restored feature.
  defp unreconciled_row(feature, recorded_status, {rows, statuses, resume_phases, discrepancies}) do
    row = %{
      id: feature.id,
      slug: feature.slug,
      recorded: recorded_status,
      reconciled: recorded_status,
      resume_phase: nil,
      corrected?: false
    }

    statuses = Map.put(statuses, feature.id, recorded_status)

    discrepancies = [
      %{kind: :absent_from_backlog, id: feature.id, detail: recorded_status} | discrepancies
    ]

    {[row | rows], statuses, resume_phases, discrepancies}
  end

  # ---- prereq guard (FR-020) --------------------------------------------------

  defp prereq_discrepancies(features, union_ids) do
    for feature <- features,
        prereq <- feature.prereqs,
        not MapSet.member?(union_ids, prereq) do
      %{kind: :prereq_missing, id: feature.id, detail: prereq}
    end
  end
end
