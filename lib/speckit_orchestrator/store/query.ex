defmodule SpeckitOrchestrator.Store.Query do
  @moduledoc """
  Internal read API (018, contracts/store-api.md § 4). Transactional for
  anything feeding a resume, a gate, a cost decision, an export, or a prune
  (contracts/schema.md § Read discipline) — `capacity/0`'s measurement is the
  one exception, pure metadata that needs no transaction.
  """

  alias SpeckitOrchestrator.Config
  alias SpeckitOrchestrator.Store.{Ids, Mnesia, Records}

  @doc """
  `repo_id`'s runs, most recent first (FR-021), successful and unsuccessful
  alike. A damaged row is reported as `%{run_id:, damaged: true, reason:}`
  rather than dropped or defaulted (FR-008). Options: `:outcome` (atom or
  list), `:feature` (feature id), `:limit`, `:before` (run_id).
  """
  @spec runs(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def runs(repo_id, filters \\ []) do
    case Mnesia.transaction(fn ->
           :speckit_run
           |> Mnesia.index_read(repo_id, :repo_id)
           |> Enum.map(&decode_run_summary/1)
         end) do
      {:ok, summaries} ->
        {:ok,
         summaries
         |> Enum.sort_by(& &1.run_id, :desc)
         |> apply_filters(filters)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Everything about one run except transcript bodies (FR-022)."
  @spec run({binary(), binary()}) ::
          {:ok, map()} | {:error, :absent} | {:error, {:damaged, term(), term()}}
  def run(run_key) do
    Mnesia.transaction(fn ->
      case Mnesia.read(:speckit_run, run_key) do
        [] ->
          {:error, :absent}

        [tuple] ->
          case Records.decode(:speckit_run, tuple) do
            {:ok, run} -> {:ok, build_run_detail(run)}
            {:error, _} = damaged -> damaged
          end
      end
    end)
    |> unwrap()
  end

  @doc "One feature's durable resume pointer."
  @spec checkpoint({binary(), binary()}, binary()) ::
          {:ok, map()} | {:error, :absent} | {:error, {:damaged, term(), term()}}
  def checkpoint({repo_id, run_id}, feature_id) do
    key = Ids.feature_key(repo_id, run_id, feature_id)

    Mnesia.transaction(fn ->
      case Mnesia.read(:speckit_checkpoint, key) do
        [] -> {:error, :absent}
        [tuple] -> Records.decode(:speckit_checkpoint, tuple)
      end
    end)
    |> unwrap()
  end

  @doc "On-demand retrieval of one phase attempt's transcript, verbatim (FR-029)."
  @spec transcript(tuple()) ::
          {:ok, map()} | {:error, :absent} | {:error, {:damaged, term(), term()}}
  def transcript(attempt_id) do
    Mnesia.transaction(fn ->
      case Mnesia.read(:speckit_transcript, attempt_id) do
        [] -> {:error, :absent}
        [tuple] -> Records.decode(:speckit_transcript, tuple)
      end
    end)
    |> unwrap()
  end

  @doc "The `:in_flight` run for `repo_id`, if any (FR-034)."
  @spec in_flight_run(binary()) :: {:ok, map()} | :none | {:error, term()}
  def in_flight_run(repo_id) do
    Mnesia.transaction(fn ->
      :speckit_run
      |> Mnesia.index_read(repo_id, :repo_id)
      |> Enum.find_value(fn tuple ->
        case Records.decode(:speckit_run, tuple) do
          {:ok, %Records.Run{state: :in_flight} = run} -> run_summary(run)
          _ -> nil
        end
      end)
    end)
    |> case do
      {:ok, nil} -> :none
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Store capacity measurement: transcript bytes (`disc_only_copies`'
  `:memory`, already bytes) and whole-store bytes (a `File.stat/1` sum over
  the store dir) — neither reads table contents.
  """
  @spec capacity() :: %{used_bytes: non_neg_integer(), transcript_bytes: non_neg_integer()}
  def capacity do
    %{
      used_bytes: store_dir_bytes(),
      transcript_bytes: Mnesia.table_info(:speckit_transcript, :memory)
    }
  end

  # ---- internal -------------------------------------------------------------

  defp unwrap({:ok, inner}), do: inner
  defp unwrap({:error, reason}), do: {:error, reason}

  defp decode_run_summary(tuple) do
    case Records.decode(:speckit_run, tuple) do
      {:ok, run} ->
        run_summary(run)

      {:error, {:damaged, key, reason}} ->
        %{run_id: damaged_run_id(key), damaged: true, reason: reason}
    end
  end

  defp damaged_run_id({_repo_id, run_id}), do: run_id
  defp damaged_run_id(other), do: other

  defp run_summary(run) do
    %{
      key: run.key,
      run_id: run.run_id,
      state: run.state,
      outcome: run.outcome,
      started_at: run.started_at,
      ended_at: run.ended_at,
      duration_ms: run.duration_ms,
      spend_usd: run.spend_usd,
      record_complete?: run.record_complete?,
      halt_reason: run.halt_reason,
      superseded_by: run.superseded_by,
      scope: run.scope,
      layout: run.layout,
      feature_statuses: feature_statuses_for(run.key)
    }
  end

  defp feature_statuses_for(run_key) do
    :speckit_feature_run
    |> Mnesia.index_read(run_key, :run_key)
    |> Enum.reduce(%{}, fn tuple, acc ->
      case Records.decode(:speckit_feature_run, tuple) do
        {:ok, f} -> Map.put(acc, f.feature_id, f.status)
        {:error, _} -> acc
      end
    end)
  end

  defp build_run_detail(run) do
    settings = read_one(:speckit_run_settings, run.key)
    amendments = index_read_decoded(:speckit_settings_amendment, run.key, :run_key)

    features =
      :speckit_feature_run
      |> Mnesia.index_read(run.key, :run_key)
      |> index_decode(:speckit_feature_run)
      |> Enum.map(&feature_detail/1)

    %{
      run: run_summary(run),
      settings: (settings && settings.settings) || %{},
      amendments: amendments,
      cost_entries:
        :speckit_cost_entry
        |> Mnesia.index_read(run.key, :run_key)
        |> index_decode(:speckit_cost_entry)
        |> Enum.sort_by(& &1.id),
      features: features
    }
  end

  defp feature_detail(f) do
    %{
      feature_id: f.feature_id,
      slug: f.slug,
      path: f.path,
      prereqs: f.prereqs,
      status: f.status,
      terminal_reason: f.terminal_reason,
      branch: f.branch,
      worktree_path: f.worktree_path,
      pr_description: f.pr_description,
      started_at: f.started_at,
      ended_at: f.ended_at,
      phase_attempts:
        :speckit_phase_attempt
        |> Mnesia.index_read(f.key, :feature_key)
        |> index_decode(:speckit_phase_attempt)
        |> Enum.sort_by(& &1.attempt_id),
      escalations:
        :speckit_escalation
        |> Mnesia.index_read(f.run_key, :run_key)
        |> index_decode(:speckit_escalation)
        |> Enum.filter(&(&1.feature_id == f.feature_id)),
      remediation_attempts:
        :speckit_remediation_attempt
        |> Mnesia.index_read(f.key, :feature_key)
        |> index_decode(:speckit_remediation_attempt)
        |> Enum.sort_by(& &1.ordinal),
      checkpoint: read_one(:speckit_checkpoint, f.key)
    }
  end

  defp read_one(table, key) do
    case Mnesia.read(table, key) do
      [tuple] ->
        case Records.decode(table, tuple) do
          {:ok, record} -> record
          {:error, _} -> nil
        end

      [] ->
        nil
    end
  end

  defp index_read_decoded(table, value, attr) do
    table |> Mnesia.index_read(value, attr) |> index_decode(table)
  end

  defp index_decode(tuples, table) do
    Enum.flat_map(tuples, fn tuple ->
      case Records.decode(table, tuple) do
        {:ok, record} -> [record]
        {:error, _} -> []
      end
    end)
  end

  defp apply_filters(summaries, filters) do
    summaries
    |> filter_outcome(Keyword.get(filters, :outcome))
    |> filter_feature(Keyword.get(filters, :feature))
    |> filter_before(Keyword.get(filters, :before))
    |> limit(Keyword.get(filters, :limit))
  end

  defp filter_outcome(summaries, nil), do: summaries

  defp filter_outcome(summaries, outcome) when is_atom(outcome),
    do: filter_outcome(summaries, [outcome])

  defp filter_outcome(summaries, outcomes) when is_list(outcomes) do
    Enum.filter(summaries, &(Map.get(&1, :outcome) in outcomes))
  end

  defp filter_feature(summaries, nil), do: summaries

  defp filter_feature(summaries, feature_id) do
    Enum.filter(summaries, fn s ->
      Map.has_key?(Map.get(s, :feature_statuses, %{}), feature_id)
    end)
  end

  defp filter_before(summaries, nil), do: summaries
  defp filter_before(summaries, run_id), do: Enum.filter(summaries, &(&1.run_id < run_id))

  defp limit(summaries, nil), do: summaries
  defp limit(summaries, n), do: Enum.take(summaries, n)

  defp store_dir_bytes do
    dir = Config.store_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, acc ->
          case File.stat(Path.join(dir, entry)) do
            {:ok, %File.Stat{size: size}} -> acc + size
            _ -> acc
          end
        end)

      {:error, _} ->
        0
    end
  end
end
