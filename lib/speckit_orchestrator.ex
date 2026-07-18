defmodule SpeckitOrchestrator do
  @moduledoc """
  Operator facade for the orchestrator.

  `run/1` loads the backlog, starts a per-run `Coordinator`, and releases the
  first wave; features then run to terminal states in dependency-and-cap waves.
  `status/0` reports the live run. The `iex` prompt plus these two functions are
  the whole operator surface (no UI in v1).
  """

  alias SpeckitOrchestrator.{
    Backlog,
    Config,
    Coordinator,
    FeatureRunner,
    Ledger,
    PullRequest,
    Report,
    StackTracker,
    TargetPack,
    Worktree
  }

  require Logger

  @coordinator SpeckitOrchestrator.Coordinator

  @doc """
  Start a run. Options (all optional):

    * `:features` — explicit backlog; defaults to `Backlog.load!/1` over the
      configured repo + breakdown dir.
    * `:owner` — pid to receive `{:run_complete, report}` (defaults to caller).
    * `:runner` — override the feature runner (tests inject a fake); defaults to
      spawning `FeatureRunner` in a fresh worktree under `RunnerSup`.
    * `:max_concurrency` — override `Config.max_concurrency/0` for this run.
    * `:pr_workflow` — override `Config.pr_workflow?/0`. When on, the run is
      strictly sequential (cap 1), the target's `:pr_remote` is preflighted, each
      feature stacks on the previous completed feature's branch, and on `:done`
      the branch is pushed and a PR opened against that base.
    * `:publisher` — override the PR opener (tests inject a fake);
      `(repo, spec) -> {:ok, url} | {:error, term}`.

  Returns `{:ok, coordinator_pid}`, or `{:error, {:preflight, problems}}` if the
  PR workflow's remote/pack preflight fails.
  """
  @spec run(keyword()) :: GenServer.on_start() | {:error, term()}
  def run(opts \\ []) do
    if Keyword.get(opts, :pr_workflow, Config.pr_workflow?()) do
      run_stacked(opts)
    else
      start_run(opts,
        max_concurrency: Keyword.get(opts, :max_concurrency, Config.max_concurrency()),
        runner: Keyword.get(opts, :runner, &default_runner/2)
      )
    end
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

  defp start_run(opts, extra) do
    # The per-run Coordinator is a named process that outlives a drained run, so
    # a second run/1 would collide with `{:error, {:already_started, pid}}`. Stop
    # any prior one first — re-running replaces the previous run.
    stop_previous_run()

    Coordinator.start_link(
      [
        features: Keyword.get_lazy(opts, :features, &load_backlog/0),
        ledger: Ledger,
        owner: Keyword.get(opts, :owner, self()),
        name: @coordinator
      ] ++ extra
    )
  end

  defp stop_previous_run do
    case Process.whereis(@coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

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

  # ---- stacked sequential PR workflow -------------------------------------
  #
  # Two injectable seams keep this testable without real worktrees or `gh`:
  #   * `:executor` — `(feature, base, notify) -> :ok`, runs one feature branched
  #     from `base` (default: worktree + `FeatureRunner` under `RunnerSup`).
  #   * `:publisher` — `(feature, base) -> {:ok, url} | {:error, term}`, pushes the
  #     branch and opens the PR (default: `publish_feature/2`).
  # A `:runner` override bypasses stacking entirely (used to test cap-1 sequencing).

  defp run_stacked(opts) do
    test_mode? = Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor)

    with :ok <- preflight_stacked(test_mode?) do
      {:ok, tracker} = StackTracker.start_link(Config.pr_base())
      publisher = Keyword.get(opts, :publisher, &publish_feature/2)
      executor = Keyword.get(opts, :executor, &default_executor/3)
      runner = Keyword.get(opts, :runner) || stacked_runner(tracker, publisher, executor)

      start_run(opts, max_concurrency: 1, runner: runner)
    end
  end

  # Preflight the real target (pack scaffold + committed constitution + remote)
  # unless a seam is injected (tests supply their own features/executor).
  defp preflight_stacked(true), do: :ok

  defp preflight_stacked(false) do
    case TargetPack.verify(Config.repo(), check_remote: Config.pr_remote()) do
      :ok -> :ok
      {:error, problems} -> {:error, {:preflight, problems}}
    end
  end

  # Each feature branches from the current stack top; on `:done` its branch is
  # published and becomes the new top for the next feature. Cap 1 makes the
  # tracker race-free.
  defp stacked_runner(tracker, publisher, executor) do
    fn feature, notify ->
      base = StackTracker.top(tracker)
      executor.(feature, base, pr_notify(feature, base, tracker, publisher, notify))
    end
  end

  defp pr_notify(feature, base, tracker, publisher, notify) do
    fn id, status, reason ->
      if status == :done, do: publish_and_advance(feature, base, tracker, publisher)
      notify.(id, status, reason)
    end
  end

  # Best-effort: publish the feature, then advance the stack to its branch. A
  # publish failure is logged and never fails the run — the local branch still
  # exists, so the next feature stacks on it regardless.
  defp publish_and_advance(feature, base, tracker, publisher) do
    case publisher.(feature, base) do
      {:ok, url} ->
        Logger.info("feature #{feature.id} PR opened: #{url}")

      {:error, reason} ->
        Logger.warning("feature #{feature.id} publish failed: #{inspect(reason)}")
    end

    StackTracker.set_top(tracker, Worktree.locate(feature).branch)
  end

  defp default_executor(feature, base, notify) do
    Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
      case Worktree.create(feature, base: base) do
        {:ok, worktree} ->
          FeatureRunner.run(feature, worktree: worktree, ledger: Ledger, notify: notify)

        {:error, reason} ->
          notify.(feature.id, :failed, {:worktree, reason})
      end
    end)

    :ok
  end

  # Real publisher: push the feature branch, then open a PR against its base.
  defp publish_feature(feature, base) do
    wt = Worktree.locate(feature)

    with :ok <- Worktree.push(wt, Config.pr_remote()) do
      PullRequest.open(Config.repo(), %{
        head: wt.branch,
        base: base,
        title: "feat(#{feature.id}-#{feature.slug}): autonomous build",
        body:
          "Autonomous build of feature #{feature.id} (#{feature.slug}) by " <>
            "speckit_orchestrator.\n\nStacked on `#{base}`."
      })
    end
  end
end
