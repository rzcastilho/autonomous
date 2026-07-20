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
    Checkpoint,
    Config,
    Describe,
    Coordinator,
    FeatureRunner,
    Ledger,
    Pipeline,
    PullRequest,
    Report,
    SingleSpec,
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

  @doc """
  Start a run for exactly ONE feature described in free text — no breakdown
  backlog required (specs/001-single-spec-run). The id is auto-assigned and the
  slug derived (`SingleSpec.build/3`); the description is materialized as a
  one-off breakdown seed inside the feature's worktree so the existing
  `specify` phase reads it unchanged, then the feature runs as a wave of one
  through `run/1`. All safety behavior (clarify/analyze gates, cost breaker,
  containment, transcripts, worktree retention) is inherited from `run/1`
  unchanged.

  Options: same as `run/1`, plus:
    * `:repo`, `:breakdown_dir` — override target locations used to gather
      already-taken ids (tests; default `Config.repo/0`, `Config.breakdown_dir/0`).

  When the caller injects `:runner` or `:executor` (test seam), the seed is
  **not** written — there is no real worktree to write it into.

  Returns `{:error, :empty_description}` for a `nil`/empty/whitespace-only
  description with no side effect, `{:error, {:preflight, problems}}` under the
  PR workflow if the remote/pack preflight fails, or the coordinator
  `on_start` tuple.
  """
  @spec run_spec(String.t() | nil, keyword()) ::
          GenServer.on_start() | {:error, :empty_description} | {:error, term()}
  def run_spec(description, opts \\ []) do
    # Validate before gathering taken ids — an invalid description must cause
    # zero IO (no dir listing, no git call), not just zero run (Principle II).
    if blank?(description) do
      {:error, :empty_description}
    else
      case SingleSpec.build(description, gather_taken_ids(opts), opts) do
        {:error, :empty_description} = err ->
          err

        {:ok, feature} ->
          case spec_run_opts(opts, feature, description) do
            {:ok, run_opts} -> run(run_opts)
            {:error, _reason} = err -> err
          end
      end
    end
  end

  defp blank?(nil), do: true
  defp blank?(description) when is_binary(description), do: String.trim(description) == ""

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

  @doc """
  Restart a previously-escalated/halted feature at its checkpointed phase,
  reusing (or recreating from) its existing branch — the mid-pipeline
  counterpart to `resolve/1`'s full restart. Every unsafe precondition returns
  a distinct `{:error, …}` and starts no run: unknown feature id, missing or
  corrupt checkpoint, or a checkpoint phase (or `:from` override) that isn't a
  real pipeline phase.
  Options: same as `run/1` (`:features`, `:runner`, `:owner`,
  `:max_concurrency`, …, passed through unchanged), plus:

    * `:prompt` — operator guidance note carried into the resumed phase as
      `resume_prompt`; omitted/`nil` runs the phase with no note.
    * `:from` — override the start phase; takes precedence over the
      checkpoint's stored `last_phase`.

  A caller-supplied `:runner` wins over the injected resume runner. See
  `specs/005-resume-facade/contracts/resume.md`.
  """
  @spec resume(String.t(), keyword()) ::
          GenServer.on_start()
          | {:error, {:unknown_feature, String.t()}}
          | {:error, :no_checkpoint}
          | {:error, :corrupt_checkpoint}
          | {:error, {:unknown_phase, term()}}
  def resume(feature_id, opts \\ []) do
    features = Keyword.get_lazy(opts, :features, &load_backlog/0)

    with {:ok, feature} <- find_feature(features, feature_id),
         {:ok, record} <- read_checkpoint(feature_id),
         {:ok, start_phase} <- resolve_start_phase(record, opts) do
      runner =
        case Keyword.fetch(opts, :runner) do
          {:ok, r} -> r
          :error -> resume_runner(start_phase, Keyword.get(opts, :prompt))
        end

      opts
      |> Keyword.put(:features, [feature])
      |> Keyword.put(:runner, runner)
      |> run()
    end
  end

  defp find_feature(features, feature_id) do
    case Enum.find(features, &(&1.id == feature_id)) do
      nil -> {:error, {:unknown_feature, feature_id}}
      feature -> {:ok, feature}
    end
  end

  defp read_checkpoint(feature_id) do
    case Checkpoint.read(feature_id) do
      {:ok, record} -> {:ok, record}
      {:error, :no_checkpoint} -> {:error, :no_checkpoint}
      {:error, :corrupt} -> {:error, :corrupt_checkpoint}
    end
  end

  # `:from` takes precedence over the checkpoint's stored phase (validated the
  # same way). Never String.to_atom/1 on file contents (atom-table safety) —
  # guarded by Pipeline.phase?/1, catching the case where the stored string
  # never was a real atom at all (a hand-corrupted checkpoint).
  defp resolve_start_phase(%{"last_phase" => last_phase}, opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, from} -> validate_phase(from)
      :error -> parse_checkpoint_phase(last_phase)
    end
  end

  defp validate_phase(phase) do
    if Pipeline.phase?(phase), do: {:ok, phase}, else: {:error, {:unknown_phase, phase}}
  end

  defp parse_checkpoint_phase(last_phase) do
    validate_phase(String.to_existing_atom(last_phase))
  rescue
    ArgumentError -> {:error, {:unknown_phase, last_phase}}
  end

  # Reuse the kept worktree if one exists (a prior resolve/1 froze it, or the
  # feature never tore it down); else recreate it from the existing branch.
  # Never falls back to a fresh branch (FR-005, SC-005) — a missing branch is
  # a distinct worktree error, not silently re-created from HEAD.
  defp resume_runner(start_phase, prompt) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case resume_worktree(feature) do
          {:ok, worktree} ->
            FeatureRunner.run(feature,
              worktree: worktree,
              ledger: Ledger,
              notify: notify,
              start_phase: start_phase,
              resume_prompt: prompt
            )

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  defp resume_worktree(feature) do
    worktree = Worktree.locate(feature)

    cond do
      File.dir?(worktree.path) -> {:ok, worktree}
      branch_exists?(worktree.repo, worktree.branch) -> Worktree.create(feature)
      true -> {:error, :branch_missing}
    end
  end

  defp branch_exists?(repo, branch) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
        stderr_to_stdout: true
      )
    )
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

  # ---- single-spec run (specs/001-single-spec-run) -------------------------
  #
  # `run/1` already accepts an explicit `:features` list; single-spec mode
  # supplies a one-element list built by `SingleSpec` and, unless the caller
  # injected its own `:runner`/`:executor` (test seam — no real worktree to
  # seed), swaps in a seed-writing wrapper around `default_runner/2` /
  # `default_executor/3` so the existing `specify` phase reads the operator's
  # description unchanged (see contracts/run_spec.md).

  # Preflight decision made BEFORE injecting our own seed_executor — injecting
  # it first would make `run_stacked/1`'s own `:runner`/`:executor` presence
  # check think the *caller* supplied a test seam and silently skip its
  # preflight for a real run. We check against the caller's original opts, run
  # the preflight ourselves when it applies, and only then inject.
  defp spec_run_opts(opts, feature, description) do
    opts = Keyword.put(opts, :features, [feature])
    caller_test_mode? = Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor)
    pr_workflow? = Keyword.get(opts, :pr_workflow, Config.pr_workflow?())

    cond do
      caller_test_mode? ->
        {:ok, opts}

      pr_workflow? ->
        case TargetPack.verify(Config.repo(), check_remote: Config.pr_remote()) do
          :ok -> {:ok, Keyword.put(opts, :executor, seed_executor(description))}
          {:error, problems} -> {:error, {:preflight, problems}}
        end

      true ->
        {:ok, Keyword.put(opts, :runner, seed_runner(description))}
    end
  end

  # Existing breakdown ids (dir listing) + existing `feature/NNN-*` branch ids
  # (git), so an auto-assigned id never collides with — and never clobbers —
  # a prior backlog or single-spec feature (constitution Principle II).
  defp gather_taken_ids(opts) do
    repo = Keyword.get(opts, :repo, Config.repo())
    breakdown_dir = Keyword.get(opts, :breakdown_dir, Config.breakdown_dir())

    breakdown_ids(Path.join(repo, breakdown_dir)) ++ branch_ids(repo)
  end

  defp breakdown_ids(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.flat_map(names, &id_prefix/1)
      {:error, _reason} -> []
    end
  end

  defp branch_ids(repo) do
    case System.cmd("git", ["-C", repo, "branch", "--list", "feature/*"], stderr_to_stdout: true) do
      {out, 0} -> Regex.scan(~r/feature\/(\d{3,})-/, out) |> Enum.map(&Enum.at(&1, 1))
      _ -> []
    end
  end

  defp id_prefix(name) do
    case Regex.run(~r/^(\d{3,})-/, name) do
      [_, id] -> [id]
      nil -> []
    end
  end

  defp seed_runner(description) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case Worktree.create(feature) do
          {:ok, worktree} -> run_seeded(feature, worktree, description, notify)
          {:error, reason} -> notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  defp seed_executor(description) do
    fn feature, base, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case Worktree.create(feature, base: base) do
          {:ok, worktree} -> run_seeded(feature, worktree, description, notify)
          {:error, reason} -> notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  defp run_seeded(feature, worktree, description, notify) do
    case write_seed(worktree, feature, description) do
      :ok -> FeatureRunner.run(feature, worktree: worktree, ledger: Ledger, notify: notify)
      {:error, reason} -> notify.(feature.id, :failed, {:seed, reason})
    end
  end

  # Writes to <worktree>/<breakdown_dir>/<basename(feature.path)> — the exact
  # path `PhaseRequest.breakdown_ref/1` resolves for the `specify` phase — and
  # ONLY inside the worktree, never the base repo tree (containment).
  defp write_seed(worktree, feature, description) do
    path = Path.join([worktree.path, Config.breakdown_dir(), Path.basename(feature.path)])

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, SingleSpec.seed_body(feature.id, description))
    end
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
      {title, body} = pr_text(feature, base)
      PullRequest.open(Config.repo(), %{head: wt.branch, base: base, title: title, body: body})
    end
  end

  # Prefer the Claude-authored PR text the describe step wrote on :done; fall back
  # to a template if it is absent/empty.
  defp pr_text(feature, base) do
    case Describe.read_pr(feature.id) do
      {:ok, %{pr_title: t, pr_body: b}} when t != "" and b != "" ->
        {t, b}

      _ ->
        {"feat(#{feature.id}-#{feature.slug}): autonomous build",
         "Autonomous build of feature #{feature.id} (#{feature.slug}) by " <>
           "speckit_orchestrator.\n\nStacked on `#{base}`."}
    end
  end
end
