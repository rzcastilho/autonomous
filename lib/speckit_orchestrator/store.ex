defmodule SpeckitOrchestrator.Store do
  @moduledoc """
  Persistence boundary facade (018) — the module the `SpeckitOrchestrator.*`
  operator facade and the console call through. Ties `Store.Writer` (writes)
  and `Store.Query` (reads) together behind one module and declares the
  behaviour a test double can stand in for.
  """

  alias SpeckitOrchestrator.Store.{Query, Writer}

  @type run_key :: {binary(), binary()}

  @callback open_run(binary(), map()) :: {:ok, binary()} | {:error, term()}
  @callback add_features(run_key(), [map()]) :: :ok | {:error, term()}
  @callback record_phase_attempt(run_key(), map()) :: :ok | {:error, term()}
  @callback record_remediation_attempt(run_key(), map()) :: :ok | {:error, term()}
  @callback record_feature_started(run_key(), binary()) :: :ok | {:error, term()}
  @callback record_feature_terminal(run_key(), binary(), atom(), term(), keyword()) ::
              :ok | {:error, term()}
  @callback record_pr_url(run_key(), binary(), binary()) :: :ok | {:error, term()}
  @callback record_escalation(run_key(), map()) :: :ok | {:error, term()}
  @callback resolve_escalation(tuple(), map()) :: :ok | {:error, term()}
  @callback record_settings_amendment(run_key(), map(), term()) :: :ok | {:error, term()}
  @callback close_run(run_key(), atom(), keyword()) :: :ok | {:error, term()}
  @callback flag_record_incomplete(run_key(), term()) :: :ok | {:error, term()}
  @callback prune_run(run_key()) :: :ok | {:error, term()}
  @callback runs(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback run(run_key()) :: {:ok, map()} | {:error, term()}
  @callback checkpoint(run_key(), binary()) :: {:ok, map()} | {:error, term()}
  @callback transcript(tuple()) :: {:ok, map()} | {:error, term()}
  @callback in_flight_run(binary()) :: {:ok, map()} | :none | {:error, term()}
  @callback parked_run(binary()) :: {:ok, map()} | :none | {:error, term()}
  @callback capacity() :: map()
  @callback run_bytes(run_key()) :: non_neg_integer()

  @doc "See `Store.Writer.open_run/2`."
  @spec open_run(binary(), map()) :: {:ok, binary()} | {:error, term()}
  def open_run(repo_id, opts), do: Writer.open_run(repo_id, opts)

  @doc "See `Store.Writer.add_features/2`."
  @spec add_features(run_key(), [map()]) :: :ok | {:error, term()}
  def add_features(run_key, features), do: Writer.add_features(run_key, features)

  @doc "See `Store.Writer.record_phase_attempt/2`."
  @spec record_phase_attempt(run_key(), map()) :: :ok | {:error, term()}
  def record_phase_attempt(run_key, payload), do: Writer.record_phase_attempt(run_key, payload)

  @doc "See `Store.Writer.record_remediation_attempt/2`."
  @spec record_remediation_attempt(run_key(), map()) :: :ok | {:error, term()}
  def record_remediation_attempt(run_key, payload),
    do: Writer.record_remediation_attempt(run_key, payload)

  @doc "See `Store.Writer.record_feature_started/2`."
  @spec record_feature_started(run_key(), binary()) :: :ok | {:error, term()}
  def record_feature_started(run_key, feature_id),
    do: Writer.record_feature_started(run_key, feature_id)

  @doc "See `Store.Writer.record_feature_terminal/5`."
  @spec record_feature_terminal(run_key(), binary(), atom(), term(), keyword()) ::
          :ok | {:error, term()}
  def record_feature_terminal(run_key, feature_id, status, reason, opts \\ []),
    do: Writer.record_feature_terminal(run_key, feature_id, status, reason, opts)

  @doc "See `Store.Writer.record_pr_url/3`."
  @spec record_pr_url(run_key(), binary(), binary()) :: :ok | {:error, term()}
  def record_pr_url(run_key, feature_id, url), do: Writer.record_pr_url(run_key, feature_id, url)

  @doc "See `Store.Writer.record_escalation/2`."
  @spec record_escalation(run_key(), map()) :: :ok | {:error, term()}
  def record_escalation(run_key, escalation), do: Writer.record_escalation(run_key, escalation)

  @doc "See `Store.Writer.resolve_escalation/2`."
  @spec resolve_escalation(tuple(), map()) :: :ok | {:error, term()}
  def resolve_escalation(escalation_id, resolution),
    do: Writer.resolve_escalation(escalation_id, resolution)

  @doc "See `Store.Writer.record_settings_amendment/3`."
  @spec record_settings_amendment(run_key(), map(), term()) :: :ok | {:error, term()}
  def record_settings_amendment(run_key, changes, effective_after),
    do: Writer.record_settings_amendment(run_key, changes, effective_after)

  @doc "See `Store.Writer.close_run/3`."
  @spec close_run(run_key(), atom(), keyword()) :: :ok | {:error, term()}
  def close_run(run_key, outcome, opts \\ []), do: Writer.close_run(run_key, outcome, opts)

  @doc "See `Store.Writer.flag_record_incomplete/2`."
  @spec flag_record_incomplete(run_key(), term()) :: :ok | {:error, term()}
  def flag_record_incomplete(run_key, halt_reason),
    do: Writer.flag_record_incomplete(run_key, halt_reason)

  @doc "See `Store.Query.runs/2`."
  @spec runs(binary(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def runs(repo_id, filters \\ []), do: Query.runs(repo_id, filters)

  @doc "See `Store.Query.run/1`."
  @spec run(run_key()) :: {:ok, map()} | {:error, term()}
  def run(run_key), do: Query.run(run_key)

  @doc "See `Store.Query.checkpoint/2`."
  @spec checkpoint(run_key(), binary()) :: {:ok, map()} | {:error, term()}
  def checkpoint(run_key, feature_id), do: Query.checkpoint(run_key, feature_id)

  @doc "See `Store.Query.transcript/1`."
  @spec transcript(tuple()) :: {:ok, map()} | {:error, term()}
  def transcript(attempt_id), do: Query.transcript(attempt_id)

  @doc "See `Store.Query.in_flight_run/1`."
  @spec in_flight_run(binary()) :: {:ok, map()} | :none | {:error, term()}
  def in_flight_run(repo_id), do: Query.in_flight_run(repo_id)

  @doc "See `Store.Query.parked_run/1`."
  @spec parked_run(binary()) :: {:ok, map()} | :none | {:error, term()}
  def parked_run(repo_id), do: Query.parked_run(repo_id)

  @doc "See `Store.Query.capacity/0`."
  @spec capacity() :: map()
  def capacity, do: Query.capacity()

  @doc "See `Store.Query.run_bytes/1`."
  @spec run_bytes(run_key()) :: non_neg_integer()
  def run_bytes(run_key), do: Query.run_bytes(run_key)

  @doc "See `Store.Writer.prune_run/1`."
  @spec prune_run(run_key()) :: :ok | {:error, term()}
  def prune_run(run_key), do: Writer.prune_run(run_key)

  @doc """
  `{repo_id, run_id}` of `repo_id`'s current `:in_flight` run, or `nil` if
  none — the single lookup every edge module (`FeatureRunner`, `AnalyzeRunner`,
  `ChunkRunner`, `Coordinator`) uses to find the run it should record against,
  without threading a freshly-minted `run_id` through pre-built runner
  closures (018 Phase 3).
  """
  @spec current_run_key(binary()) :: run_key() | nil
  def current_run_key(repo_id) do
    case Query.in_flight_run(repo_id) do
      {:ok, %{run_id: run_id}} -> {repo_id, run_id}
      _ -> nil
    end
  end
end
