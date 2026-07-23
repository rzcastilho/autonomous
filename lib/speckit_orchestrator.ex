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
    Feature,
    FeatureRunner,
    Ledger,
    Pipeline,
    PullRequest,
    Report,
    RunContext,
    RunManifest,
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

  Captures the six run-shaping settings (`pr_workflow`, `max_concurrency`,
  `budget_usd`, `plan_stack`, `pr_base`, `pr_remote`) from the effective opts
  at call time (`RunContext.capture/1`) and threads them into every feature's
  `FeatureRunner.run/2` call, so a diverted feature's checkpoint records the
  run shape it actually ran under (FR-006) — see
  `specs/007-resume-self-sufficient/contracts/run_context.md`.

  Returns `{:ok, coordinator_pid}`, or `{:error, {:preflight, problems}}` if the
  PR workflow's remote/pack preflight fails.
  """
  @spec run(keyword()) :: GenServer.on_start() | {:error, term()}
  def run(opts \\ []) do
    # Single-slot rule (FR-005): a new run supersedes the prior manifest — the
    # fresh Coordinator's first write (from `init/1`) replaces it immediately.
    RunManifest.clear()
    run_context = RunContext.capture(opts)

    if Keyword.get(opts, :pr_workflow, Config.pr_workflow?()) do
      run_stacked(opts, run_context)
    else
      start_run(opts,
        max_concurrency: Keyword.get(opts, :max_concurrency, Config.max_concurrency()),
        context: run_context,
        runner:
          Keyword.get(opts, :runner, fn feature, notify ->
            default_runner(feature, notify, run_context)
          end)
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

  @doc """
  Preview the `id`/`slug` `run_spec/2` would assign for `description`, without
  starting a run — backs the Trigger console view's single-spec live preview
  (FR-016). Same taken-id gathering and `SingleSpec` derivation `run_spec/2`
  uses internally; a blank description previews as `nil`.
  """
  @spec preview_single_spec(String.t() | nil, keyword()) :: {String.t(), String.t()} | nil
  def preview_single_spec(description, opts \\ []) do
    if blank?(description) do
      nil
    else
      case SingleSpec.build(description, gather_taken_ids(opts), opts) do
        {:ok, feature} -> {feature.id, feature.slug}
        {:error, :empty_description} -> nil
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
  counterpart to `resolve/1`'s full restart. Identity (`slug`/`path`) is
  recovered from the checkpoint itself when no explicit/backlog feature is
  supplied, so `resume(id)` alone is sufficient — no hand-typed `%Feature{}`,
  no loadable backlog required (FR-001..004). An explicit/backlog feature for
  the id still wins over checkpoint identity when both exist. Every unsafe
  precondition returns a distinct `{:error, …}` and starts no run: unknown
  feature id (neither an explicit/backlog feature nor checkpoint identity),
  missing or corrupt checkpoint, or a checkpoint phase (or `:from` override)
  that isn't a real pipeline phase.

  Options: same as `run/1` (`:features`, `:runner`, `:owner`,
  `:max_concurrency`, …, passed through unchanged), plus:

    * `:prompt` — operator guidance note carried into the resumed phase as
      `resume_prompt`; omitted/`nil` runs the phase with no note.
    * `:from` — override the start phase; takes precedence over the
      checkpoint's stored `last_phase`.

  Also reapplies the run-shaping context (`pr_workflow`, `max_concurrency`,
  `budget_usd`, `plan_stack`, `pr_base`, `pr_remote`) the checkpoint recorded
  at the original run's start (FR-006), so the resumed run re-executes under
  its original shape without the caller re-declaring it. Precedence (fixed,
  documented once): **explicit resume opt > recorded checkpoint context >
  live Config/default** (FR-007) — the six opts above, when passed to
  `resume/2`, override the recorded value; an unrecorded/partial setting
  falls back to live `Config` and logs which settings fell back (FR-008). The
  reapplied `pr_workflow` decides worktree strategy: `false` resumes through
  the plain runner path (unchanged from 005); `true` routes the resume
  through the stacked PR-workflow executor path so cap-1 sequencing,
  preflight, stacking, and PR-on-`:done` are preserved (FR-009). A
  caller-supplied `:runner` or `:executor` still wins over either injected
  strategy (test seam). See `specs/005-resume-facade/contracts/resume.md` and
  `specs/007-resume-self-sufficient/contracts/resume.md`.
  """
  @spec resume(String.t(), keyword()) ::
          GenServer.on_start()
          | {:error, {:unknown_feature, String.t()}}
          | {:error, :no_checkpoint}
          | {:error, :corrupt_checkpoint}
          | {:error, {:unknown_phase, term()}}
  def resume(feature_id, opts \\ []) do
    with {:ok, record} <- read_checkpoint(feature_id),
         {:ok, feature} <- resolve_identity(feature_id, record, opts),
         {:ok, start_phase} <- resolve_start_phase(record, opts) do
      {merged_opts, fell_back} = RunContext.merge(opts, RunContext.from_map(record["context"]))
      log_context_fallback(feature_id, fell_back)

      run_context = RunContext.capture(merged_opts)
      pr_workflow? = Keyword.get(merged_opts, :pr_workflow, Config.pr_workflow?())
      prompt = Keyword.get(opts, :prompt)

      merged_opts
      |> Keyword.put(:features, [feature])
      |> inject_resume_strategy(pr_workflow?, start_phase, prompt, run_context)
      |> run()
    end
  end

  @doc """
  Detect & report a resumable run without starting any work (FR-008, SC-006).
  Safe to call on boot. Reads the single-slot run manifest and classifies it:
  a summary map when at least one feature is `:running`/`:pending` (an
  interrupted or never-released feature), `:none` when every feature is
  `:done` or a gate divert, or a loud error on a missing/corrupt manifest.

  See `specs/009-crash-recovery/contracts/resume_run.md`.
  """
  @spec resumable_run() ::
          {:ok, %{features: list(), statuses: map(), spend: number(), context: map()}}
          | :none
          | {:error, :no_manifest}
          | {:error, :corrupt_manifest}
  def resumable_run do
    case read_manifest() do
      {:error, _} = err ->
        err

      {:ok, record} ->
        if RunManifest.resumable?() do
          {:ok,
           %{
             features: record["features"],
             statuses: record["statuses"],
             spend: record["spend"],
             context: record["context"]
           }}
        else
          :none
        end
    end
  end

  @doc """
  Reconstruct and continue a crashed run from the durable run manifest
  (FR-006/007). `:done` and gate-diverted (`:escalated`/`:halted`/`:failed`)
  features are kept as-is and never re-run (SC-002, FR-015); `:running`
  (interrupted) and `:pending` (never released) features are reset to
  `:pending` and released in dependency-and-cap order — a checkpointed
  feature resumes at the phase after its `last_phase` (reusing feature 007's
  `resume/2` machinery); a never-started feature runs fresh from
  `Pipeline.first()`.

  Restores the `Ledger`'s committed spend from the manifest's recorded figure
  (FR-012) before any wave releases, and reapplies the manifest's run-shaping
  context (`RunContext.merge/2` precedence: explicit opt > recorded > live
  Config) so the resumed run continues under its original shape (FR-007).

  Options: same as `run/1`, plus:
    * `:force` — proceed even if a different `Coordinator` is already alive
      with an unfinished run (default `false` — refuses without it, FR-017).

  Returns `{:error, :no_manifest}` / `{:error, :corrupt_manifest}` on a
  missing/corrupt manifest, or `{:error, {:active_run, pid}}` when a live
  unfinished run is present and `:force` was not given — every failure starts
  no work (Principle II).

  See `specs/009-crash-recovery/contracts/resume_run.md`.
  """
  @spec resume_run(keyword()) ::
          GenServer.on_start()
          | {:error, :no_manifest}
          | {:error, :corrupt_manifest}
          | {:error, {:active_run, pid()}}
  def resume_run(opts \\ []) do
    with :ok <- guard_active_run(opts),
         {:ok, record} <- read_manifest() do
      {features, statuses} = RunManifest.reconstruct(record)
      Ledger.restore(Ledger, record["spend"] || 0)

      {merged_opts, fell_back} = RunContext.merge(opts, RunContext.from_map(record["context"]))
      log_context_fallback("run", fell_back)

      run_context = RunContext.capture(merged_opts)
      pr_workflow? = Keyword.get(merged_opts, :pr_workflow, Config.pr_workflow?())

      merged_opts
      |> Keyword.put(:features, features)
      |> Keyword.put(:statuses, statuses)
      |> inject_resume_run_strategy(pr_workflow?, run_context)
      |> run()
    end
  end

  defp guard_active_run(opts) do
    if Keyword.get(opts, :force, false) do
      :ok
    else
      case Process.whereis(@coordinator) do
        nil -> :ok
        pid -> if Coordinator.status(pid).finished?, do: :ok, else: {:error, {:active_run, pid}}
      end
    end
  end

  defp read_manifest do
    case RunManifest.read() do
      {:ok, record} -> {:ok, record}
      {:error, :no_manifest} -> {:error, :no_manifest}
      {:error, :corrupt} -> {:error, :corrupt_manifest}
    end
  end

  # A caller-supplied :runner/:executor still wins (test seam), same
  # precedence as inject_resume_strategy/5 below.
  defp inject_resume_run_strategy(opts, pr_workflow?, run_context) do
    cond do
      Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor) ->
        opts

      pr_workflow? ->
        Keyword.put(opts, :executor, resume_run_executor(run_context))

      true ->
        Keyword.put(opts, :runner, resume_run_runner(run_context))
    end
  end

  defp resume_run_runner(run_context) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        dispatch_resume(feature, nil, notify, run_context)
      end)

      :ok
    end
  end

  # Executor shape for the PR workflow — `base` (the stack's current top) is
  # used only for a never-started :pending feature; a checkpointed feature
  # ignores it and reuses/recreates its own existing worktree/branch.
  defp resume_run_executor(run_context) do
    fn feature, base, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        dispatch_resume(feature, base, notify, run_context)
      end)

      :ok
    end
  end

  defp dispatch_resume(feature, base, notify, run_context) do
    case Checkpoint.read(feature.id) do
      {:ok, record} -> run_from_checkpoint(feature, record, notify, run_context)
      {:error, :no_checkpoint} -> run_fresh(feature, base, notify, run_context)
      {:error, :corrupt} -> notify.(feature.id, :failed, {:checkpoint, :corrupt})
    end
  end

  defp run_from_checkpoint(feature, record, notify, run_context) do
    case resolve_start_phase(record, []) do
      {:ok, start_phase} ->
        case resume_worktree(feature) do
          {:ok, worktree} ->
            FeatureRunner.run(feature,
              worktree: worktree,
              ledger: Ledger,
              notify: notify,
              start_phase: start_phase,
              run_context: run_context
            )

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end

      {:error, reason} ->
        notify.(feature.id, :failed, reason)
    end
  end

  defp run_fresh(feature, base, notify, run_context) do
    create_opts = if base, do: [base: base], else: []

    case Worktree.create(feature, create_opts) do
      {:ok, worktree} ->
        FeatureRunner.run(feature,
          worktree: worktree,
          ledger: Ledger,
          notify: notify,
          run_context: run_context
        )

      {:error, reason} ->
        notify.(feature.id, :failed, {:worktree, reason})
    end
  end

  # FR-007/008: explicit resume opt > recorded context > live Config/default.
  # A caller-supplied :runner/:executor still wins (test seam) regardless of
  # the effective pr_workflow — checked here rather than at run/1 since resume
  # must choose runner vs executor based on the *reapplied* pr_workflow.
  defp inject_resume_strategy(opts, pr_workflow?, start_phase, prompt, run_context) do
    cond do
      Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor) ->
        opts

      pr_workflow? ->
        Keyword.put(opts, :executor, resume_executor(start_phase, prompt, run_context))

      true ->
        Keyword.put(opts, :runner, resume_runner(start_phase, prompt, run_context))
    end
  end

  defp log_context_fallback(_feature_id, []), do: :ok

  defp log_context_fallback(feature_id, fell_back) do
    Logger.info(
      "feature #{feature_id} resume: no recorded context for #{inspect(fell_back)} — " <>
        "falling back to live Config"
    )
  end

  # FR-002/003/004: an explicit/backlog feature wins over checkpoint identity
  # whenever both exist; else the checkpoint's own slug/path rebuilds the
  # feature; else unknown-feature. A best-effort backlog load never raises
  # past resume/2 — a missing/unloadable backlog is non-fatal once checkpoint
  # identity is available (FR-004).
  defp resolve_identity(feature_id, record, opts) do
    features = resolve_features(opts)

    case Enum.find(features, &(&1.id == feature_id)) do
      nil -> checkpoint_identity(feature_id, record)
      feature -> {:ok, feature}
    end
  end

  defp resolve_features(opts) do
    case Keyword.fetch(opts, :features) do
      {:ok, features} -> features
      :error -> best_effort_backlog()
    end
  end

  defp best_effort_backlog do
    load_backlog()
  rescue
    _ -> []
  end

  defp checkpoint_identity(feature_id, %{"slug" => slug, "path" => path})
       when is_binary(slug) and is_binary(path) do
    {:ok, %Feature{id: feature_id, slug: slug, path: path, status: :pending}}
  end

  defp checkpoint_identity(feature_id, _record), do: {:error, {:unknown_feature, feature_id}}

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
  defp resolve_start_phase(%{"last_phase" => last_phase} = record, opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, from} -> validate_phase(from)
      :error -> parse_checkpoint_phase(last_phase, Map.get(record, "status"))
    end
  end

  defp validate_phase(phase) do
    if Pipeline.phase?(phase), do: {:ok, phase}, else: {:error, {:unknown_phase, phase}}
  end

  defp parse_checkpoint_phase(last_phase, status) do
    with {:ok, phase} <- validate_phase(String.to_existing_atom(last_phase)) do
      resume_from_phase(phase, status)
    end
  rescue
    ArgumentError -> {:error, {:unknown_phase, last_phase}}
  end

  # An "in_progress" checkpoint records the phase that already completed
  # cleanly (FR-001) — resume continues at the *next* phase, not a re-run of
  # one already done. A divert checkpoint (escalated/halted/failed, or an
  # old-shape record with no status at all) records the phase that needs
  # re-running itself — unchanged from feature 007.
  defp resume_from_phase(phase, "in_progress") do
    case Pipeline.next(phase, :ok, %{}) do
      {:cont, next} -> {:ok, next}
      {:done, :done} -> {:ok, phase}
    end
  end

  defp resume_from_phase(phase, _status), do: {:ok, phase}

  # Reuse the kept worktree if one exists (a prior resolve/1 froze it, or the
  # feature never tore it down); else recreate it from the existing branch.
  # Never falls back to a fresh branch (FR-005, SC-005) — a missing branch is
  # a distinct worktree error, not silently re-created from HEAD.
  defp resume_runner(start_phase, prompt, run_context) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case resume_worktree(feature) do
          {:ok, worktree} ->
            FeatureRunner.run(feature,
              worktree: worktree,
              ledger: Ledger,
              notify: notify,
              start_phase: start_phase,
              resume_prompt: prompt,
              run_context: run_context
            )

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  # PR-workflow resume counterpart to resume_runner/3 — same worktree
  # reuse/recreate logic, but shaped as an `:executor` (feature, base, notify)
  # so run_stacked/1's stacked_runner wraps it with stacking + preflight +
  # PR-on-:done (FR-009). `base` (the current stack top) is ignored: a resumed
  # feature reuses/recreates its own existing worktree/branch, not a fresh one
  # branched off the stack.
  defp resume_executor(start_phase, prompt, run_context) do
    fn feature, _base, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case resume_worktree(feature) do
          {:ok, worktree} ->
            FeatureRunner.run(feature,
              worktree: worktree,
              ledger: Ledger,
              notify: notify,
              start_phase: start_phase,
              resume_prompt: prompt,
              run_context: run_context
            )

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  # Restores the located/recreated worktree before the caller re-runs the
  # interrupted phase (FR-003) — discards any uncommitted partial output a
  # crash left behind. A harmless no-op on a freshly created worktree.
  defp resume_worktree(feature) do
    worktree = Worktree.locate(feature)

    result =
      cond do
        File.dir?(worktree.path) -> {:ok, worktree}
        branch_exists?(worktree.repo, worktree.branch) -> Worktree.create(feature)
        true -> {:error, :branch_missing}
      end

    with {:ok, wt} <- result do
      _ = Worktree.restore(wt)
      {:ok, wt}
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

    base = [
      features: Keyword.get_lazy(opts, :features, &load_backlog/0),
      ledger: Ledger,
      owner: Keyword.get(opts, :owner, self()),
      name: @coordinator
    ]

    # Only forwarded when the caller (resume_run/1) supplied it — an absent key
    # preserves Coordinator.init/1's own all-:pending default (FR-006).
    base =
      case Keyword.fetch(opts, :statuses) do
        {:ok, statuses} -> Keyword.put(base, :statuses, statuses)
        :error -> base
      end

    Coordinator.start_link(base ++ extra)
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
  defp default_runner(feature, notify, run_context) do
    Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
      case Worktree.create(feature) do
        {:ok, worktree} ->
          FeatureRunner.run(feature,
            worktree: worktree,
            ledger: Ledger,
            notify: notify,
            run_context: run_context
          )

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
    run_context = RunContext.capture(opts)

    cond do
      caller_test_mode? ->
        {:ok, opts}

      pr_workflow? ->
        case TargetPack.verify(Config.repo(), check_remote: Config.pr_remote()) do
          :ok -> {:ok, Keyword.put(opts, :executor, seed_executor(description, run_context))}
          {:error, problems} -> {:error, {:preflight, problems}}
        end

      true ->
        {:ok, Keyword.put(opts, :runner, seed_runner(description, run_context))}
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

  defp seed_runner(description, run_context) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case Worktree.create(feature) do
          {:ok, worktree} -> run_seeded(feature, worktree, description, notify, run_context)
          {:error, reason} -> notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  defp seed_executor(description, run_context) do
    fn feature, base, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case Worktree.create(feature, base: base) do
          {:ok, worktree} -> run_seeded(feature, worktree, description, notify, run_context)
          {:error, reason} -> notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  defp run_seeded(feature, worktree, description, notify, run_context) do
    case write_seed(worktree, feature, description) do
      :ok ->
        FeatureRunner.run(feature,
          worktree: worktree,
          ledger: Ledger,
          notify: notify,
          run_context: run_context
        )

      {:error, reason} ->
        notify.(feature.id, :failed, {:seed, reason})
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

  defp run_stacked(opts, run_context) do
    test_mode? = Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor)

    with :ok <- preflight_stacked(test_mode?) do
      {:ok, tracker} = StackTracker.start_link(Config.pr_base())
      publisher = Keyword.get(opts, :publisher, &publish_feature/2)

      executor =
        Keyword.get(opts, :executor, fn feature, base, notify ->
          default_executor(feature, base, notify, run_context)
        end)

      runner = Keyword.get(opts, :runner) || stacked_runner(tracker, publisher, executor)

      start_run(opts, max_concurrency: 1, context: run_context, runner: runner)
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

  defp default_executor(feature, base, notify, run_context) do
    Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
      case Worktree.create(feature, base: base) do
        {:ok, worktree} ->
          FeatureRunner.run(feature,
            worktree: worktree,
            ledger: Ledger,
            notify: notify,
            run_context: run_context
          )

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
