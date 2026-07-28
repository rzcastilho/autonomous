defmodule SpeckitOrchestrator.Store.Writer do
  @moduledoc """
  Internal write API (018, contracts/store-api.md § 3) — one transaction per
  durable boundary (contracts/schema.md § Transaction boundaries). Every
  function returns `:ok | {:error, reason}` (`open_run/2` returns
  `{:ok, run_id}`, `record_escalation/2` writes the row and returns `:ok`); an
  aborted transaction is reported to `Store.Health.record_failure/2` before
  the error is returned — no function raises into the caller (FR-010).
  """

  alias SpeckitOrchestrator.Store.{Health, Ids, Migrations, Mnesia, Records}

  @terminal_statuses [:done, :escalated, :halted, :failed, :ended_by_supersession]

  @type run_key :: {binary(), binary()}

  @doc """
  Open a new run for `repo_id` (R7 "run start" boundary, one transaction):
  bumps the per-repository sequence, supersedes any prior `:in_flight` run
  for the same repository — and marks that run's non-terminal features
  `:ended_by_supersession` — then writes the new `run`, `run_settings`, and
  every `feature_run` row (FR-023, FR-034, SC-012).
  """
  @spec open_run(binary(), %{
          required(:features) => [
            %{feature_id: binary(), slug: binary(), path: binary(), prereqs: [binary()]}
          ],
          required(:settings) => map(),
          required(:scope) => term(),
          required(:layout) => map()
        }) :: {:ok, binary()} | {:error, term()}
  def open_run(repo_id, %{features: features, settings: settings, scope: scope, layout: layout})
      when is_binary(repo_id) do
    run_transaction(fn ->
      seq = next_seq!(repo_id)
      run_id = Ids.run_id(seq)
      run_key = Ids.run_key(repo_id, run_id)

      supersede_in_flight!(repo_id, run_id)

      now = DateTime.utc_now()

      Mnesia.write(
        Records.encode(%Records.Run{
          key: run_key,
          repo_id: repo_id,
          run_id: run_id,
          state: :in_flight,
          outcome: nil,
          outcome_index: :in_flight,
          started_at: now,
          ended_at: nil,
          duration_ms: nil,
          spend_usd: 0.0,
          record_complete?: true,
          halt_reason: nil,
          scope: scope,
          layout: layout,
          superseded_by: nil,
          schema_version: Migrations.current_version()
        })
      )

      Mnesia.write(
        Records.encode(%Records.RunSettings{
          run_key: run_key,
          settings: settings,
          captured_at: now
        })
      )

      Enum.each(features, fn f ->
        Mnesia.write(
          Records.encode(%Records.FeatureRun{
            key: Ids.feature_key(repo_id, run_id, f.feature_id),
            run_key: run_key,
            feature_id: f.feature_id,
            slug: f.slug,
            path: f.path,
            prereqs: f.prereqs,
            status: :pending,
            terminal_reason: nil,
            worktree_path: nil,
            branch: nil,
            pr_description: nil,
            started_at: nil,
            ended_at: nil
          })
        )
      end)

      {:ok, run_id}
    end)
  end

  @doc """
  Add features to an already-open run that its record never named (016 US3
  record-recovery's union rule), one transaction — each written exactly as
  `open_run/2` would (`status: :pending`), skipping any `feature_id` already
  present rather than overwriting it. Never used automatically; only via
  `SpeckitOrchestrator.recover_record/1`'s `:confirm` write.
  """
  @spec add_features(run_key(), [
          %{feature_id: binary(), slug: binary(), path: binary(), prereqs: [binary()]}
        ]) :: :ok | {:error, term()}
  def add_features({repo_id, run_id} = run_key, features) do
    run_transaction(fn ->
      Enum.each(features, fn f ->
        key = Ids.feature_key(repo_id, run_id, f.feature_id)

        case Mnesia.read(:speckit_feature_run, key, :write) do
          [] ->
            Mnesia.write(
              Records.encode(%Records.FeatureRun{
                key: key,
                run_key: run_key,
                feature_id: f.feature_id,
                slug: f.slug,
                path: f.path,
                prereqs: f.prereqs,
                status: :pending,
                terminal_reason: nil,
                worktree_path: nil,
                branch: nil,
                pr_description: nil,
                started_at: nil,
                ended_at: nil
              })
            )

          _ ->
            :ok
        end
      end)

      :ok
    end)
  end

  @doc """
  Record one finished phase attempt (R7 "phase attempt end" boundary, one
  transaction): the `phase_attempt` row, its `cost_entry` (if `:cost` is
  given), the feature's `checkpoint` — superseded in place (if `:checkpoint`
  is given) — and the `transcript` (if `:transcript` is given), keyed
  identically to the phase attempt so neither can be separated from the other
  (FR-035).
  """
  @spec record_phase_attempt(run_key(), %{
          required(:attempt) => map(),
          optional(:cost) => %{amount_usd: float(), kind: :actual | :estimate} | nil,
          optional(:checkpoint) => map() | nil,
          optional(:transcript) => binary() | nil
        }) :: :ok | {:error, term()}
  def record_phase_attempt({repo_id, run_id} = run_key, %{attempt: attempt} = payload) do
    run_transaction(fn ->
      attempt_id =
        Ids.attempt_id(repo_id, run_id, attempt.feature_id, attempt.phase, attempt.ordinal)

      feature_key = Ids.feature_key(repo_id, run_id, attempt.feature_id)

      Mnesia.write(
        Records.encode(%Records.PhaseAttempt{
          attempt_id: attempt_id,
          run_key: run_key,
          feature_key: feature_key,
          phase: attempt.phase,
          ordinal: attempt.ordinal,
          step: attempt.step,
          label: attempt.label,
          started_at: attempt.started_at,
          ended_at: attempt.ended_at,
          duration_ms: attempt.duration_ms,
          outcome: attempt.outcome,
          model: attempt.model,
          cost_usd: attempt.cost_usd,
          cost_kind: attempt.cost_kind,
          substep: Map.get(attempt, :substep),
          session_id: Map.get(attempt, :session_id),
          error: Map.get(attempt, :error)
        })
      )

      write_cost_entry(attempt_id, run_key, Map.get(payload, :cost))
      write_checkpoint(run_key, feature_key, Map.get(payload, :checkpoint))
      write_transcript(attempt_id, Map.get(payload, :transcript))

      :ok
    end)
  end

  @doc """
  Record one bounded-loop remediation attempt (R7 "remediation attempt end"
  boundary, one transaction): the corrective step's own `phase_attempt`
  (`phase: :auto_remediation` — distinct from the pre-phase `:remediation`
  step's own attempt-1 row, so the two never collide on the same attempt_id),
  the `remediation_attempt` row referencing it, its `cost_entry`, and
  `transcript` — all keyed off that same phase attempt.
  """
  @spec record_remediation_attempt(run_key(), %{
          required(:remediation) => map(),
          required(:phase_attempt) => map(),
          optional(:cost) => %{amount_usd: float(), kind: :actual | :estimate} | nil,
          optional(:transcript) => binary() | nil
        }) :: :ok | {:error, term()}
  def record_remediation_attempt(
        {repo_id, run_id} = run_key,
        %{remediation: r, phase_attempt: pa} = payload
      ) do
    run_transaction(fn ->
      feature_key = Ids.feature_key(repo_id, run_id, r.feature_id)
      attempt_id = Ids.attempt_id(repo_id, run_id, r.feature_id, :auto_remediation, r.ordinal)

      Mnesia.write(
        Records.encode(%Records.PhaseAttempt{
          attempt_id: attempt_id,
          run_key: run_key,
          feature_key: feature_key,
          phase: :auto_remediation,
          ordinal: r.ordinal,
          step: pa.step,
          label: pa.label,
          started_at: pa.started_at,
          ended_at: pa.ended_at,
          duration_ms: pa.duration_ms,
          outcome: pa.outcome,
          model: pa.model,
          cost_usd: pa.cost_usd,
          cost_kind: pa.cost_kind,
          substep: Map.get(pa, :substep),
          session_id: Map.get(pa, :session_id),
          error: Map.get(pa, :error)
        })
      )

      Mnesia.write(
        Records.encode(%Records.RemediationAttempt{
          id: Ids.ordinal_id(repo_id, run_id, r.feature_id, r.ordinal),
          run_key: run_key,
          feature_key: feature_key,
          ordinal: r.ordinal,
          findings: r.findings,
          max_severity: r.max_severity,
          outcome: r.outcome,
          cost_usd: r.cost_usd,
          attempt_limit: r.attempt_limit,
          threshold: r.threshold,
          model: r.model,
          attempt_id: attempt_id
        })
      )

      write_cost_entry(attempt_id, run_key, Map.get(payload, :cost))
      write_transcript(attempt_id, Map.get(payload, :transcript))

      :ok
    end)
  end

  @doc """
  Write one feature's checkpoint on its own, for the single boundary where the
  phase attempt it belongs to was already committed by an earlier transaction:
  the analyze loop's failure/breaker paths, where `AnalyzeRunner` recorded the
  analyze run before the corrective step ran. Every other boundary MUST go
  through `record_phase_attempt/2`, which writes the attempt and its checkpoint
  together (FR-006) — this function does not weaken that, because the attempt
  this checkpoint refers to is already durable when it is called.
  """
  @spec record_checkpoint(run_key(), binary(), map()) :: :ok | {:error, term()}
  def record_checkpoint({repo_id, run_id} = run_key, feature_id, checkpoint) do
    run_transaction(fn ->
      write_checkpoint(run_key, Ids.feature_key(repo_id, run_id, feature_id), checkpoint)
      :ok
    end)
  end

  @doc """
  Record a feature's terminal status (R7 "feature terminal" boundary, one
  transaction): the `feature_run` status/reason/`ended_at`, and — only on
  `:done` — deletes the feature's `checkpoint` (a `:done` feature is never
  resumed). `opts[:pr_description]` (`%{pr_title:, pr_body:}` or `nil`) is
  written in the same transaction — the store's replacement for the deleted
  `Describe.write_pr/3`; omitted/`nil` leaves the field unchanged.
  """
  @spec record_feature_terminal(run_key(), binary(), atom(), term(), keyword()) ::
          :ok | {:error, term()}
  def record_feature_terminal(run_key, feature_id, status, reason, opts \\ [])

  def record_feature_terminal({repo_id, run_id}, feature_id, status, reason, opts)
      when status in @terminal_statuses do
    run_transaction(fn ->
      feature_key = Ids.feature_key(repo_id, run_id, feature_id)

      case Mnesia.read(:speckit_feature_run, feature_key, :write) do
        [tuple] ->
          case Records.decode(:speckit_feature_run, tuple) do
            {:ok, feature} ->
              updated = %{
                feature
                | status: status,
                  terminal_reason: reason,
                  ended_at: DateTime.utc_now(),
                  pr_description: Keyword.get(opts, :pr_description) || feature.pr_description
              }

              Mnesia.write(Records.encode(updated))
              if status == :done, do: Mnesia.delete(:speckit_checkpoint, feature_key)
              :ok

            {:error, damaged} ->
              Mnesia.abort(damaged)
          end

        [] ->
          Mnesia.abort({:absent, feature_key})
      end
    end)
  end

  @doc """
  Record an escalation or halt (FR-025), one transaction. `escalation` is
  `%{feature_id:, kind:, phase:, reason:, evidence:, severity: (optional)}`.
  """
  @spec record_escalation(run_key(), map()) :: :ok | {:error, term()}
  def record_escalation({repo_id, run_id} = run_key, escalation) do
    run_transaction(fn ->
      ordinal = next_escalation_ordinal(run_key, escalation.feature_id)

      Mnesia.write(
        Records.encode(%Records.Escalation{
          id: Ids.ordinal_id(repo_id, run_id, escalation.feature_id, ordinal),
          run_key: run_key,
          feature_id: escalation.feature_id,
          kind: escalation.kind,
          phase: escalation.phase,
          severity: Map.get(escalation, :severity),
          reason: escalation.reason,
          evidence: escalation.evidence,
          raised_at: DateTime.utc_now(),
          resolution: nil
        })
      )

      :ok
    end)
  end

  @doc "Record a resolution against an existing escalation (FR-026). Never deletes the row."
  @spec resolve_escalation(tuple(), map()) :: :ok | {:error, term()}
  def resolve_escalation(escalation_id, resolution) do
    run_transaction(fn ->
      case Mnesia.read(:speckit_escalation, escalation_id, :write) do
        [tuple] ->
          case Records.decode(:speckit_escalation, tuple) do
            {:ok, escalation} ->
              Mnesia.write(Records.encode(%{escalation | resolution: resolution}))
              :ok

            {:error, damaged} ->
              Mnesia.abort(damaged)
          end

        [] ->
          Mnesia.abort({:absent, escalation_id})
      end
    end)
  end

  @doc "Record a live-config amendment (FR-027), one transaction. `changes` is changed keys only, old -> new."
  @spec record_settings_amendment(run_key(), map(), term()) :: :ok | {:error, term()}
  def record_settings_amendment({repo_id, run_id} = run_key, changes, effective_after) do
    run_transaction(fn ->
      ordinal = next_amendment_ordinal(run_key)

      Mnesia.write(
        Records.encode(%Records.SettingsAmendment{
          id: Ids.amendment_id(repo_id, run_id, ordinal),
          run_key: run_key,
          ordinal: ordinal,
          changes: changes,
          effective_at: DateTime.utc_now(),
          effective_after: effective_after
        })
      )

      :ok
    end)
  end

  @doc "Close a drained run with its final `outcome` (R7 \"run drained\" boundary, one transaction)."
  @spec close_run(run_key(), atom(), keyword()) :: :ok | {:error, term()}
  def close_run(run_key, outcome, opts \\ []) do
    run_transaction(fn ->
      case Mnesia.read(:speckit_run, run_key, :write) do
        [tuple] ->
          case Records.decode(:speckit_run, tuple) do
            {:ok, run} ->
              now = DateTime.utc_now()

              updated = %{
                run
                | state: :completed,
                  outcome: outcome,
                  outcome_index: outcome,
                  ended_at: now,
                  duration_ms: DateTime.diff(now, run.started_at, :millisecond),
                  spend_usd: Keyword.get(opts, :spend_usd, run.spend_usd),
                  record_complete?: Keyword.get(opts, :record_complete?, true)
              }

              Mnesia.write(Records.encode(updated))
              :ok

            {:error, damaged} ->
              Mnesia.abort(damaged)
          end

        [] ->
          Mnesia.abort({:absent, run_key})
      end
    end)
  end

  @doc """
  Delete every row of `run_key` across all twelve tables, one transaction
  (FR-031a, contracts/capacity-and-prune.md § Prune). The caller
  (`SpeckitOrchestrator.prune/1`, via `Store.Prune.plan/3`) has already
  established the run is neither `:in_flight` nor resumable before calling
  this — an in-flight or resumable run is never passed here. Transcripts have
  no direct `run_key` index; they are reached through the run's
  `phase_attempt` rows, which share the same `attempt_id` (FR-035 — a
  transcript is never pruned out of step with the attempt it belongs to).
  """
  @spec prune_run(run_key()) :: :ok | {:error, term()}
  def prune_run(run_key) do
    run_transaction(fn ->
      attempt_ids =
        :speckit_phase_attempt
        |> Mnesia.index_read(run_key, :run_key)
        |> Enum.map(&elem(&1, 1))

      delete_by_index(:speckit_settings_amendment, run_key)
      delete_by_index(:speckit_feature_run, run_key)
      delete_by_index(:speckit_phase_attempt, run_key)
      delete_by_index(:speckit_checkpoint, run_key)
      delete_by_index(:speckit_escalation, run_key)
      delete_by_index(:speckit_remediation_attempt, run_key)
      delete_by_index(:speckit_cost_entry, run_key)
      Enum.each(attempt_ids, &Mnesia.delete(:speckit_transcript, &1))
      Mnesia.delete(:speckit_run_settings, run_key)
      Mnesia.delete(:speckit_run, run_key)

      :ok
    end)
  end

  @doc """
  Flag a run's record incomplete after a persistence-failure drain (FR-010,
  FR-010a) — one transaction, best-effort: if this write itself fails, the run
  stays `:in_flight` with its last successful `updated_at`, which is itself
  the incompleteness signal `resumable/1` reports as `gap_possible?: true`.
  """
  @spec flag_record_incomplete(run_key(), term()) :: :ok | {:error, term()}
  def flag_record_incomplete(run_key, halt_reason) do
    run_transaction(fn ->
      case Mnesia.read(:speckit_run, run_key, :write) do
        [tuple] ->
          case Records.decode(:speckit_run, tuple) do
            {:ok, run} ->
              Mnesia.write(
                Records.encode(%{run | record_complete?: false, halt_reason: halt_reason})
              )

              :ok

            {:error, damaged} ->
              Mnesia.abort(damaged)
          end

        [] ->
          Mnesia.abort({:absent, run_key})
      end
    end)
  end

  # ---- internal ------------------------------------------------------------

  defp run_transaction(fun) do
    case Mnesia.transaction(fun) do
      {:ok, result} ->
        result

      {:error, reason} ->
        Health.record_failure(reason)
        :telemetry.execute([:speckit, :store, :write_failed], %{}, %{reason: reason})
        {:error, reason}
    end
  end

  defp next_seq!(repo_id) do
    {seq, origin, local_path} =
      case Mnesia.read(:speckit_seq, repo_id, :write) do
        [{:speckit_seq, ^repo_id, next_seq, origin, local_path}] -> {next_seq, origin, local_path}
        [] -> {1, nil, nil}
      end

    Mnesia.write({:speckit_seq, repo_id, seq + 1, origin, local_path})
    seq
  end

  defp supersede_in_flight!(repo_id, new_run_id) do
    :speckit_run
    |> Mnesia.index_read(repo_id, :repo_id)
    |> Enum.each(fn tuple ->
      case Records.decode(:speckit_run, tuple) do
        {:ok, %Records.Run{state: :in_flight} = run} -> supersede_run!(run, new_run_id)
        _ -> :ok
      end
    end)
  end

  defp supersede_run!(%Records.Run{} = run, new_run_id) do
    Mnesia.write(Records.encode(%{run | state: :superseded, superseded_by: new_run_id}))

    :speckit_feature_run
    |> Mnesia.index_read(run.key, :run_key)
    |> Enum.each(fn tuple ->
      case Records.decode(:speckit_feature_run, tuple) do
        {:ok, %Records.FeatureRun{status: status} = feature}
        when status not in @terminal_statuses ->
          Mnesia.write(
            Records.encode(%{
              feature
              | status: :ended_by_supersession,
                ended_at: DateTime.utc_now()
            })
          )

        _ ->
          :ok
      end
    end)
  end

  defp write_cost_entry(_id, _run_key, nil), do: :ok

  defp write_cost_entry(id, run_key, %{amount_usd: amount, kind: kind}) do
    Mnesia.write(
      Records.encode(%Records.CostEntry{
        id: id,
        run_key: run_key,
        amount_usd: amount,
        kind: kind,
        recorded_at: DateTime.utc_now()
      })
    )
  end

  defp write_checkpoint(_run_key, _feature_key, nil), do: :ok

  defp write_checkpoint(run_key, feature_key, checkpoint) do
    Mnesia.write(
      Records.encode(%Records.Checkpoint{
        key: feature_key,
        run_key: run_key,
        phase: checkpoint.phase,
        last_completed_phase: checkpoint.last_completed_phase,
        status: checkpoint.status,
        reason: Map.get(checkpoint, :reason),
        session_id: Map.get(checkpoint, :session_id),
        implement_chunk: Map.get(checkpoint, :implement_chunk),
        analyze_remediation: Map.get(checkpoint, :analyze_remediation),
        updated_at: DateTime.utc_now()
      })
    )
  end

  defp write_transcript(_attempt_id, nil), do: :ok

  defp write_transcript(attempt_id, body) when is_binary(body) do
    Mnesia.write(
      Records.encode(%Records.Transcript{
        attempt_id: attempt_id,
        body: body,
        bytes: byte_size(body),
        written_at: DateTime.utc_now()
      })
    )
  end

  defp delete_by_index(table, run_key) do
    table
    |> Mnesia.index_read(run_key, :run_key)
    |> Enum.each(&Mnesia.delete(table, elem(&1, 1)))
  end

  defp next_escalation_ordinal(run_key, feature_id) do
    :speckit_escalation
    |> Mnesia.index_read(run_key, :run_key)
    |> Enum.count(fn tuple -> elem(tuple, 3) == feature_id end)
    |> Kernel.+(1)
  end

  defp next_amendment_ordinal(run_key) do
    :speckit_settings_amendment
    |> Mnesia.index_read(run_key, :run_key)
    |> length()
    |> Kernel.+(1)
  end
end
