defmodule SpeckitOrchestrator do
  @moduledoc """
  Operator facade for the orchestrator.

  `run/1` loads the backlog, starts a per-run `Coordinator`, and releases the
  first wave; features then run to terminal states in dependency-and-cap waves.
  `status/0` reports the live run. The `iex` prompt plus these two functions are
  the whole operator surface (no UI in v1).
  """

  alias SpeckitOrchestrator.{Backlog, Config, Coordinator, FeatureRunner, Ledger, Report, Worktree}

  @coordinator SpeckitOrchestrator.Coordinator

  @doc """
  Start a run. Options (all optional):

    * `:features` — explicit backlog; defaults to `Backlog.load!/1` over the
      configured repo + breakdown dir.
    * `:owner` — pid to receive `{:run_complete, report}` (defaults to caller).
    * `:runner` — override the feature runner (tests inject a fake); defaults to
      spawning `FeatureRunner` in a fresh worktree under `RunnerSup`.

  Returns `{:ok, coordinator_pid}`.
  """
  @spec run(keyword()) :: GenServer.on_start()
  def run(opts \\ []) do
    Coordinator.start_link(
      features: Keyword.get_lazy(opts, :features, &load_backlog/0),
      max_concurrency: Config.max_concurrency(),
      ledger: Ledger,
      runner: Keyword.get(opts, :runner, &default_runner/2),
      owner: Keyword.get(opts, :owner, self()),
      name: @coordinator
    )
  end

  @doc "Live run snapshot (statuses, in-flight, spend, report)."
  @spec status() :: map()
  def status, do: Coordinator.status(@coordinator)

  @doc "Print the live run status as a table (iex operator surface)."
  @spec print_status() :: :ok
  def print_status, do: status() |> Report.format_status() |> IO.puts()

  @doc """
  Prepare a previously-escalated/halted feature for re-run after a human has
  resolved it. Removes the kept worktree (the human's clarifications stay
  committed on the feature branch); the next `run/1` reuses that branch and
  re-runs the feature's pipeline (v1: from the start — mid-pipeline resume is
  v2). Returns `:ok`, `{:error, {:unknown_feature, id}}`, or a git error.
  """
  @spec resolve(String.t(), keyword()) :: :ok | {:error, term()}
  def resolve(feature_id, opts \\ []) do
    features = Keyword.get_lazy(opts, :features, &load_backlog/0)

    case Enum.find(features, &(&1.id == feature_id)) do
      nil ->
        {:error, {:unknown_feature, feature_id}}

      feature ->
        worktree = Worktree.locate(feature, opts)
        if File.dir?(worktree.path), do: Worktree.remove(worktree), else: :ok
    end
  end

  # ---- internals ----------------------------------------------------------

  defp load_backlog do
    Config.repo() |> Path.join(Config.breakdown_dir()) |> Backlog.load!()
  end

  # Real runner: each feature gets its own worktree, then runs the pipeline.
  # A worktree that can't be created (missing scaffold) fails the feature
  # rather than running it in an unguarded tree.
  defp default_runner(feature, notify) do
    Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
      case Worktree.create(feature) do
        {:ok, worktree} ->
          FeatureRunner.run(feature, worktree: worktree, ledger: Ledger, notify: notify)

        {:error, reason} ->
          notify.(feature.id, :failed, {:worktree, reason})
      end
    end)

    :ok
  end
end
