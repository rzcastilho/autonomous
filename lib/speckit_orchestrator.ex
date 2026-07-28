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
    Feature,
    FeatureRunner,
    Layout,
    Ledger,
    Pipeline,
    PullRequest,
    Recovery,
    Remediation,
    Report,
    RepoIdentity,
    RunContext,
    SingleSpec,
    StackTracker,
    Store,
    TargetPack,
    Worktree
  }

  alias SpeckitOrchestrator.Store.{Capacity, Export, Migrations, Prune, Writer}

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
    * `:run_key` — a resume path (016/018) that already resolved the store's
      `{repo_id, run_id}` to continue (`resume/2`, `resume_run/1`) supplies
      it here, skipping `Store.Writer.open_run/2` entirely so the resumed
      run writes into its existing record instead of superseding it. Absent
      (default) — a fresh run opens (and, per FR-034, supersedes any prior
      in-flight run for the repo).

  Captures the six run-shaping settings (`pr_workflow`, `max_concurrency`,
  `budget_usd`, `plan_stack`, `pr_base`, `pr_remote`) from the effective opts
  at call time (`RunContext.capture/1`) and threads them into every feature's
  `FeatureRunner.run/2` call, so a diverted feature's checkpoint records the
  run shape it actually ran under (FR-006) — see
  `specs/007-resume-self-sufficient/contracts/run_context.md`.

  Preflights repository identity (`RepoIdentity.resolve/1`) and the run
  directory `Layout` (FR-011) before releasing any wave: a repo with no
  `origin` remote is refused with `{:error, {:preflight, [{:no_origin, repo}]}}`
  and starts no work (FR-002, SC-004). `run_spec/2` inherits this same
  preflight, since it delegates to `run/1` once its single-feature seed is
  prepared.

  Also preflights the analyze auto-remediation settings (017, FR-011): an
  out-of-range `:auto_remediation_attempt_limit`, an unrecognized
  `:auto_remediation_threshold` or an unknown `:auto_remediation_model` refuses
  the run with e.g. `{:error, {:preflight, [{:invalid_attempt_limit, 0}]}}` and
  starts no work — no clamping, no silent default.

  Also preflights the store (018, FR-009/FR-031b): unwritable at start, or
  under its capacity ceiling with no reclaimable headroom, both refuse with
  `{:error, {:preflight, [...]}}` before a single phase runs and before the
  prior in-flight run (if any) is superseded.

  Returns `{:ok, coordinator_pid}`, or `{:error, {:preflight, problems}}` if
  the remediation-settings, layout, store, or PR workflow remote/pack
  preflight fails.
  """
  @spec run(keyword()) :: GenServer.on_start() | {:error, term()}
  def run(opts \\ []) do
    run_context = RunContext.capture(opts)

    # Auto-remediation settings are validated *first* (017, FR-011): an invalid
    # threshold/limit/model refuses the run before any side effect at all —
    # before the store run opens and before a run directory is ensured.
    # Never clamped, never defaulted around.
    with {:ok, _settings} <- preflight_remediation(run_context),
         {:ok, layout} <- preflight_layout(opts),
         {:ok, run_key} <- open_or_continue_run(opts, run_context, layout) do
      opts = Keyword.put(opts, :features, resolve_features(opts, layout))

      if Keyword.get(opts, :pr_workflow, Config.pr_workflow?()) do
        run_stacked(opts, run_context, layout, run_key)
      else
        start_run(opts,
          max_concurrency: Keyword.get(opts, :max_concurrency, Config.max_concurrency()),
          context: run_context,
          layout: layout,
          run_key: run_key,
          runner:
            Keyword.get(opts, :runner, fn feature, notify ->
              default_runner(feature, notify, run_context, layout)
            end)
        )
      end
    end
  end

  # 018: a resume path already resolved the run to continue (`:run_key`) —
  # writing into the existing record, never superseding it. A fresh run
  # opens a new one, which *does* supersede any prior in-flight run for this
  # repo (FR-023/FR-034), inside the same transaction — preflighted for
  # writability and capacity first (FR-009/FR-031b), so a refusal supersedes
  # nothing.
  defp open_or_continue_run(opts, run_context, layout) do
    case Keyword.fetch(opts, :run_key) do
      {:ok, run_key} ->
        {:ok, run_key}

      :error ->
        with :ok <- preflight_store_writable(),
             :ok <- preflight_store_capacity() do
          repo_id = RepoIdentity.partition(Config.repo())
          features = resolve_features(opts, layout)

          case Store.open_run(repo_id, %{
                 features: store_features(features),
                 settings: RunContext.to_map(run_context),
                 scope: layout_scope(layout),
                 layout: layout
               }) do
            {:ok, run_id} -> {:ok, {repo_id, run_id}}
            {:error, reason} -> {:error, {:preflight, [{:store_open_failed, reason}]}}
          end
        end
    end
  end

  defp preflight_store_writable do
    if Store.Health.failed?() do
      {:error, {:preflight, [{:store_unwritable, Store.Health.status()}]}}
    else
      :ok
    end
  end

  defp preflight_store_capacity do
    {:ok, capacity} = store_capacity()

    case capacity.status do
      :ok ->
        :ok

      :refusing ->
        :telemetry.execute(
          [:speckit, :store, :capacity_refused],
          %{
            shortfall_bytes: capacity.shortfall_bytes,
            reclaimable_bytes: capacity.reclaimable_bytes
          },
          %{repo: Config.repo()}
        )

        {:error, {:preflight, [{:store_capacity, capacity}]}}
    end
  end

  defp resolve_features(opts, layout) do
    Keyword.get_lazy(opts, :features, fn -> load_backlog(layout) end)
  end

  defp store_features(features) do
    Enum.map(features, &%{feature_id: &1.id, slug: &1.slug, path: &1.path, prereqs: &1.prereqs})
  end

  defp layout_scope(%Layout{breakdown_root: nil}), do: :ad_hoc
  defp layout_scope(%Layout{in_repo_rel: rel}), do: {:breakdown, Path.basename(rel)}

  # FR-011: the loop's three knobs go through the single validator
  # (`Remediation.Settings.validate/1`, reached via the captured context so an
  # explicit opt, a recorded value and the live `Config` default all resolve the
  # same way) before any work starts. Refusals surface in the same
  # `{:error, {:preflight, problems}}` shape as every other launch refusal.
  defp preflight_remediation(run_context) do
    case Remediation.Settings.from_context(run_context) do
      {:ok, settings} -> {:ok, settings}
      {:error, reason} -> {:error, {:preflight, [reason]}}
    end
  end

  # Repository-identity + Layout resolution (FR-011), once per run. `:layout`
  # lets a caller that already resolved one (a resume path rebuilding it from
  # the manifest's recorded segment+scope, T033, or `run_spec/2`'s ad-hoc
  # preflight) skip re-deriving it.
  defp preflight_layout(opts) do
    case Keyword.fetch(opts, :layout) do
      {:ok, %Layout{} = layout} ->
        {:ok, layout}

      :error ->
        repo = Config.repo()

        with {:ok, segment} <- RepoIdentity.resolve(repo),
             {:ok, scope} <- resolve_scope(opts, repo),
             {:ok, layout} <- Layout.build(repo, segment, scope),
             :ok <- Layout.ensure(layout) do
          {:ok, layout}
        else
          {:error, :no_origin} -> {:error, {:preflight, [{:no_origin, repo}]}}
          {:error, reason} -> {:error, {:preflight, [reason]}}
        end
    end
  end

  # T013/T023: an explicit `:scope` (run_spec/2's ad-hoc run) or `:slug`/
  # `:package` (an operator-selected breakdown package) always wins. Failing
  # that, the sole package directory under `specs/autonomous/breakdown/` is
  # selected automatically (FR-007); zero packages found falls back to the
  # pre-slug-selection placeholder scope (keeps a bare `:features`-supplying
  # caller — most unit tests, and any pre-012 flat-layout repo — working with
  # no explicit `:slug`); 2+ packages with none selected is genuinely
  # ambiguous and refused loud rather than guessed (FR-010).
  defp resolve_scope(opts, repo) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        case Keyword.get(opts, :slug) || Keyword.get(opts, :package) do
          nil -> default_breakdown_scope(repo)
          slug -> {:ok, {:breakdown, slug}}
        end
    end
  end

  defp default_breakdown_scope(repo) do
    dir = Path.join([repo, Config.specs_root(), "breakdown"])

    case package_slugs(dir) do
      [slug] -> {:ok, {:breakdown, slug}}
      [] -> {:ok, {:breakdown, Path.basename(Config.breakdown_dir())}}
      slugs -> {:error, {:ambiguous_breakdown_package, slugs}}
    end
  end

  defp package_slugs(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort()
      {:error, _reason} -> []
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
    * `:repo`, `:ad_hoc_dir` — override target locations used to gather
      already-taken ids (tests; default `Config.repo/0`,
      `Layout.in_repo_rel(:ad_hoc)` joined onto `:repo`).

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
        resolve_store_escalation(feature_id)
        worktree = Worktree.locate(feature, opts)
        if File.dir?(worktree.path), do: Worktree.remove(worktree), else: :ok
    end
  end

  # Records the escalation's resolution (018, FR-026) against the feature's
  # current in-flight run, if one has an unresolved escalation open for it —
  # a silent no-op with nothing to resolve or no store-backed run (most unit
  # tests calling this facade directly).
  defp resolve_store_escalation(feature_id) do
    case current_run_key() do
      nil -> :ok
      run_key -> resolve_open_escalation(Store.run(run_key), feature_id)
    end
  end

  defp resolve_open_escalation({:ok, detail}, feature_id) do
    feature_record = Enum.find(detail.features, &(&1.feature_id == feature_id))
    escalation = feature_record && Enum.find(feature_record.escalations, &(&1.resolution == nil))
    if escalation, do: Store.resolve_escalation(escalation.id, %{resolved_at: DateTime.utc_now()})
    :ok
  end

  defp resolve_open_escalation(_error, _feature_id), do: :ok

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
    * `:remediation_prompt` — operator correction instruction (feature 013).
      **Non-blank** ⇒ a single remediation step runs and completes before the
      target phase, letting the model fix what a read-only gate (e.g.
      `analyze`) only evaluates. **Blank**/absent (default) ⇒ no step; the
      resume is byte-identical to today's.
    * `:remediation_model` — model alias (`"opus"`/`"sonnet"`) for the
      remediation step only; `nil` defaults to `Config.model_for(start_phase)`.
      An unknown alias returns `{:error, {:unknown_model, alias}}` and starts
      no run. Independent of the target phase's own model routing and of
      `:prompt` (FR-010/FR-011).
    * `:from_task_phase` — an explicit starting task-phase (ordinal
      `pos_integer()` or `TaskPhaseRef.t()`) for a chunked `implement` resume,
      overriding the checkpoint's recorded `implement_chunk` position
      (checkpoint-implement-chunk.md §3-4). Honoured only when the resolved
      `start_phase == :implement`; ignored otherwise. `resume/2` always sets
      `reset_implement_sessions: true` on `FeatureRunner.run/2` regardless of
      whether this option is given (FR-013b — resuming is an explicit human
      grant of more session budget).
    * `:force` — proceed despite a live unfinished run, matching
      `resume_run/1`'s option of the same name (016, FR-010a); default
      `false`.

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

  **016 — whole-run continuation**: `resume/2` no longer starts a run
  containing only the named feature. It restores the *entire* recorded run
  (every feature the manifest still names), reconciles each restored feature
  against durable evidence (`Recovery.reconcile_run/2`, reused from 014), and
  applies every option above to the **named feature only** — every other
  restored feature keeps its reconciled status and dispatches (or stays put)
  exactly as `resume_run/1` already would. See
  `specs/016-resume-backlog-scope/contracts/resume-scope.md`. A live
  unfinished run refuses with `{:error, {:active_run, pid}}` (FR-010a) before
  anything else is read. With no readable manifest, behaviour is unchanged
  from pre-016 — a single-feature run (FR-009, D8).
  """
  @spec resume(String.t(), keyword()) ::
          GenServer.on_start()
          | {:error, {:unknown_feature, String.t()}}
          | {:error, :no_checkpoint}
          | {:error, :corrupt_checkpoint}
          | {:error, {:unknown_phase, term()}}
          | {:error, {:unknown_model, String.t()}}
          | {:error, {:active_run, pid()}}
  def resume(feature_id, opts \\ []) do
    remediation_model = Keyword.get(opts, :remediation_model)

    with :ok <- guard_active_run(opts),
         {:ok, run_key, detail} <- read_current_run(),
         {:ok, feature_record} <- find_feature_record(detail, feature_id),
         {:ok, feature} <- resolve_identity(feature_id, feature_record, opts),
         {:ok, start_phase} <- resolve_start_phase(feature_record.checkpoint, opts),
         {:ok, _resolved} <- Config.remediation_model(start_phase, remediation_model) do
      {merged_opts, fell_back} = RunContext.merge(opts, RunContext.from_map(detail.settings))
      log_context_fallback(feature_id, fell_back)

      run_context = RunContext.capture(merged_opts)
      prompt = Keyword.get(opts, :prompt)
      remediation_prompt = Keyword.get(opts, :remediation_prompt)
      start_task_phase = task_phase_override(start_phase, opts)

      with {:ok, scope} <- restore_run_scope(detail, merged_opts) do
        scope = merge_resume_target(scope, feature)
        pr_workflow? = Keyword.get(scope.merged_opts, :pr_workflow, Config.pr_workflow?())

        scope.merged_opts
        |> maybe_put_layout(detail.run.layout)
        |> Keyword.put(:features, scope.features)
        |> Keyword.put(:statuses, dispatch_statuses(scope.statuses, scope.resume_phases))
        |> Keyword.put(:run_key, run_key)
        |> inject_resume_scope_strategy(
          feature.id,
          pr_workflow?,
          start_phase,
          prompt,
          remediation_prompt,
          remediation_model,
          run_context,
          detail.run.layout,
          scope.layout,
          start_task_phase,
          scope.resume_phases,
          run_key
        )
        |> run()
      end
    end
  end

  defp find_feature_record(detail, feature_id) do
    case Enum.find(detail.features, &(&1.feature_id == feature_id)) do
      nil -> {:error, :no_checkpoint}
      feature_record -> {:ok, feature_record}
    end
  end

  # 018: `record` is `Store.Query.run/1`'s run-detail map — reconciles every
  # feature against durable evidence (`Recovery.reconcile_run/2`), restores
  # the `Ledger`'s committed spend from the run's `speckit_cost_entry`
  # roll-up (T040 — attributable across a resume, not a single recorded
  # scalar), and reapplies the recorded run-shaping context. `opts` may
  # already carry context overrides (e.g. resume/2's own context merge) —
  # `RunContext.merge/2` never overrides a key already present, so merging
  # again here is idempotent.
  # A resume starts new phases, which record — refused on the same capacity
  # basis as a fresh `run/1` (contracts/capacity-and-prune.md § What a
  # refusal does and does not block), before any state mutation
  # (`restore_ledger/1`) below.
  defp restore_run_scope(detail, opts) do
    with :ok <- preflight_store_capacity(),
         {:ok, %{statuses: statuses, resume_phases: resume_phases}} <-
           Recovery.reconcile_run(detail) do
      features = Enum.map(detail.features, &Recovery.to_feature/1)
      restore_ledger(detail.cost_entries)

      layout = Keyword.get(opts, :layout) || detail.run.layout

      {merged_opts, fell_back} = RunContext.merge(opts, RunContext.from_map(detail.settings))
      log_context_fallback("run", fell_back)

      run_context = RunContext.capture(merged_opts)

      {:ok,
       %{
         features: features,
         statuses: statuses,
         resume_phases: resume_phases,
         layout: layout,
         run_context: run_context,
         merged_opts: merged_opts
       }}
    end
  end

  # T040: seed from the run's cost-entry roll-up (attributable per boundary)
  # instead of a single recorded scalar — idempotent/monotonic via
  # `Ledger.restore/2` regardless of how many times a resume attempt sums it.
  defp restore_ledger(cost_entries) do
    total = Enum.reduce(cost_entries, 0.0, &(&1.amount_usd + &2))
    Ledger.restore(Ledger, total)
  end

  # T009 (contracts/resume-scope.md steps 8-9): append the target feature
  # when the restored set omits it (FR-008); force its seed status to
  # :pending; delete it from resume_phases so the operator's resolved start
  # phase (D2) governs instead of the reconciled one.
  defp merge_resume_target(scope, feature) do
    features =
      if Enum.any?(scope.features, &(&1.id == feature.id)) do
        scope.features
      else
        scope.features ++ [feature]
      end

    %{
      scope
      | features: features,
        statuses: Map.put(scope.statuses, feature.id, :pending),
        resume_phases: Map.delete(scope.resume_phases, feature.id)
    }
  end

  # T010 (contracts/resume-scope.md "Dispatch matrix"): the target id
  # dispatches through today's byte-identical resume_runner/8 /
  # resume_executor/8 (G5); every other restored feature dispatches through
  # resume_run/1's existing checkpoint-driven dispatch_resume/7.
  defp split_resume_runner(target_id, target_runner, run_context, layout, resume_phases, run_key) do
    fn feature, notify ->
      if feature.id == target_id do
        target_runner.(feature, notify)
      else
        Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
          dispatch_resume(feature, nil, notify, run_context, layout, resume_phases, run_key)
        end)

        :ok
      end
    end
  end

  defp split_resume_executor(
         target_id,
         target_executor,
         run_context,
         layout,
         resume_phases,
         run_key
       ) do
    fn feature, base, notify ->
      if feature.id == target_id do
        target_executor.(feature, base, notify)
      else
        Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
          dispatch_resume(feature, base, notify, run_context, layout, resume_phases, run_key)
        end)

        :ok
      end
    end
  end

  # A caller-supplied :runner/:executor still wins (test seam), same
  # precedence as inject_resume_run_strategy/6. `target_layout` and
  # `scope_layout` both come from the same store `run.layout` (018 collapses
  # what were once two possibly-different rebuilds into one, since both the
  # target and every other restored feature read the same run record).
  defp inject_resume_scope_strategy(
         opts,
         target_id,
         pr_workflow?,
         start_phase,
         prompt,
         remediation_prompt,
         remediation_model,
         run_context,
         target_layout,
         scope_layout,
         start_task_phase,
         resume_phases,
         run_key
       ) do
    cond do
      Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor) ->
        opts

      pr_workflow? ->
        target_executor =
          resume_executor(
            start_phase,
            prompt,
            remediation_prompt,
            remediation_model,
            run_context,
            target_layout,
            start_task_phase,
            run_key
          )

        Keyword.put(
          opts,
          :executor,
          split_resume_executor(
            target_id,
            target_executor,
            run_context,
            scope_layout,
            resume_phases,
            run_key
          )
        )

      true ->
        target_runner =
          resume_runner(
            start_phase,
            prompt,
            remediation_prompt,
            remediation_model,
            run_context,
            target_layout,
            start_task_phase,
            run_key
          )

        Keyword.put(
          opts,
          :runner,
          split_resume_runner(
            target_id,
            target_runner,
            run_context,
            scope_layout,
            resume_phases,
            run_key
          )
        )
    end
  end

  # FR-021/checkpoint-implement-chunk.md §3: an explicit `:from_task_phase`
  # only means something for a chunked `implement` resume — any other
  # resolved start phase has no chunk loop to steer, so the override is
  # dropped rather than silently carried into an unrelated phase.
  defp task_phase_override(:implement, opts), do: Keyword.get(opts, :from_task_phase)
  defp task_phase_override(_start_phase, _opts), do: nil

  defp maybe_put_layout(opts, nil), do: opts
  defp maybe_put_layout(opts, %Layout{} = layout), do: Keyword.put_new(opts, :layout, layout)

  @doc """
  Detect & report a resumable run without starting any work (FR-008, SC-006).
  Safe to call on boot. Looks up `repo_id`'s current in-flight store run
  (018) and classifies it: a summary map — plus `gap_possible?`, `true` when
  a persistence-failure drain left the record incomplete (FR-010a) — when at
  least one feature is non-terminal (interrupted or never-released), `:none`
  when every feature is `:done` or a gate divert, or a loud error on a
  missing/damaged run record.

  See `specs/009-crash-recovery/contracts/resume_run.md`.
  """
  @spec resumable(String.t()) ::
          {:ok,
           %{
             report: Recovery.Report.t(),
             statuses: %{String.t() => Feature.status()},
             resume_phases: %{String.t() => Pipeline.phase()},
             gap_possible?: boolean()
           }}
          | :none
          | {:error, :no_manifest}
          | {:error, :corrupt_manifest}
          | {:error, term()}
  def resumable(repo_id) do
    case Store.current_run_key(repo_id) do
      nil ->
        {:error, :no_manifest}

      run_key ->
        case Store.run(run_key) do
          {:error, {:damaged, _key, _reason}} -> {:error, :corrupt_manifest}
          {:error, reason} -> {:error, reason}
          {:ok, detail} -> resumable_from_detail(detail)
        end
    end
  end

  defp resumable_from_detail(detail) do
    if resumable_detail?(detail) do
      with {:ok, reconciled} <- Recovery.reconcile_run(detail) do
        {:ok, Map.put(reconciled, :gap_possible?, not detail.run.record_complete?)}
      end
    else
      :none
    end
  end

  defp resumable_detail?(%{features: features}) do
    Enum.any?(
      features,
      &(&1.status not in [:done, :escalated, :halted, :failed, :ended_by_supersession])
    )
  end

  @doc "`resumable/1` for the configured `Config.repo/0`."
  @spec resumable_run() ::
          {:ok,
           %{
             report: Recovery.Report.t(),
             statuses: %{String.t() => Feature.status()},
             resume_phases: %{String.t() => Pipeline.phase()},
             gap_possible?: boolean()
           }}
          | :none
          | {:error, :no_manifest}
          | {:error, :corrupt_manifest}
          | {:error, term()}
  def resumable_run do
    resumable(RepoIdentity.partition(Config.repo()))
  end

  @doc """
  A repository's runs, most recent first, successful and unsuccessful alike
  (018, FR-021, US2). Never loads transcript content (FR-036, SC-009).

  Options: `:repo` (default `Config.repo/0`), `:outcome` (atom or list —
  FR-024), `:feature` (feature id — every run in which it appears, FR-024),
  `:limit`, `:before` (run_id, for paging). An unknown repository returns
  `{:ok, []}` — an empty history, not an error (US2 acceptance 4).
  """
  @spec run_history(keyword()) :: {:ok, [map()]} | {:error, term()}
  def run_history(opts \\ []) do
    repo = Keyword.get(opts, :repo, Config.repo())
    repo_id = RepoIdentity.partition(repo)
    Store.runs(repo_id, Keyword.take(opts, [:outcome, :feature, :limit, :before]))
  end

  @doc """
  Reconstruct and continue a crashed run from the durable store run record
  (018, FR-006/007). `:done` and gate-diverted (`:escalated`/`:halted`/
  `:failed`) features are kept as-is and never re-run (SC-002, FR-015);
  every other feature is reconciled against durable evidence and released in
  dependency-and-cap order — a checkpointed feature resumes at its
  checkpoint's recorded phase (reusing feature 007's `resume/2` machinery); a
  never-started feature runs fresh from `Pipeline.first()`.

  Restores the `Ledger`'s committed spend from the run's cost-entry roll-up
  (FR-012, T040) before any wave releases, and reapplies the run's recorded
  run-shaping context (`RunContext.merge/2` precedence: explicit opt >
  recorded > live Config) so the resumed run continues under its original
  shape (FR-007). Continues the same `run_id` — never opens a new run.

  Options: same as `run/1`, plus:
    * `:force` — proceed even if a different `Coordinator` is already alive
      with an unfinished run (default `false` — refuses without it, FR-017).

  Returns `{:error, :no_manifest}` / `{:error, :corrupt_manifest}` on a
  missing/damaged run record, or `{:error, {:active_run, pid}}` when a live
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
         {:ok, run_key, detail} <- read_current_run(),
         {:ok, scope} <- restore_run_scope(detail, opts) do
      pr_workflow? = Keyword.get(scope.merged_opts, :pr_workflow, Config.pr_workflow?())

      scope.merged_opts
      |> maybe_put_layout(scope.layout)
      |> Keyword.put(:features, scope.features)
      |> Keyword.put(:statuses, dispatch_statuses(scope.statuses, scope.resume_phases))
      |> Keyword.put(:run_key, run_key)
      |> inject_resume_run_strategy(
        pr_workflow?,
        scope.run_context,
        scope.layout,
        scope.resume_phases,
        run_key
      )
      |> run()
    end
  end

  @doc """
  Preview, or (with `:confirm`) write, a repaired run record for a
  repository whose recorded scope was narrowed by the defect this feature
  closes (016 US3, FR-016-020). Unions the (possibly narrowed) store run
  record's features with the backlog on disk plus per-feature durable
  evidence (`Recovery.Rebuild.propose/3`) and returns the proposal. Never
  runs a phase, never spends budget, never starts a `Coordinator`.

  Options:
    * `:confirm` — `true` persists the union rule through the store: every
      feature the union names but the store never recorded (`kind:
      :absent_from_record`) is added via `Store.Writer.add_features/2`
      (`:pending`), and any feature genuine evidence proved `:done` that the
      store hadn't yet recorded as terminal is persisted the same way
      `reconcile_run/2` does — and returns `{:ok, :written, proposal}`;
      default `false` previews only, with **no durable effect** (FR-019a).
    * `:backlog_root` — override the backlog source (default the run's
      layout's `breakdown_root`).
    * `:layout` — test seam; overrides the run's recorded layout.
    * `:git` / `:remote` — forwarded to `Recovery.Evidence.collect/3`.
    * `:writer` — module implementing `Store.Writer`'s write API (test seam;
      default `Store.Writer`).

  Refuses with no write when: there is no run record (`{:error,
  :no_manifest}`); the record is damaged (`{:error, :corrupt_manifest}`);
  the backlog cannot be loaded — missing directory, dangling prereq, or a
  cycle — (`{:error, {:backlog, reason}}`, catching `Backlog.load!/1`'s
  raises at this boundary rather than propagating them into an operator
  session); or the proposal names a feature whose prereq is absent from the
  union (`{:error, {:inconsistent, discrepancies}}`, FR-020).

  Never runs automatically inside `resume/2`/`resume_run/1` — operator-
  invoked only (FR-019). See
  `specs/016-resume-backlog-scope/contracts/record-recovery.md`.
  """
  @spec recover_record(keyword()) ::
          {:ok, Recovery.Rebuild.proposal()}
          | {:ok, :written, Recovery.Rebuild.proposal()}
          | {:error, :no_manifest}
          | {:error, :corrupt_manifest}
          | {:error, {:backlog, term()}}
          | {:error, {:inconsistent, [Recovery.Rebuild.discrepancy()]}}
  def recover_record(opts \\ []) do
    with {:ok, run_key, detail} <- read_current_run() do
      layout = Keyword.get(opts, :layout) || detail.run.layout

      with {:ok, backlog} <- load_recovery_backlog(layout, opts),
           {:ok, proposal} <-
             Recovery.Rebuild.propose(detail, backlog, recovery_propose_opts(opts)) do
        maybe_write_recovered_record(run_key, proposal, opts)
      end
    end
  end

  @doc """
  Store capacity snapshot (018, contracts/capacity-and-prune.md § Capacity):
  measures via `Store.Query.capacity/0`, decides via `Store.Capacity.check/1`,
  and estimates `reclaimable_bytes` via `Store.Prune.plan/3` over
  `Store.Query.runs/2` for the configured repo. Backs the run-start capacity
  preflight (FR-031b) and the console's capacity banner.
  """
  @spec store_capacity() :: {:ok, map()}
  def store_capacity do
    %{used_bytes: used_bytes, transcript_bytes: transcript_bytes} = Store.capacity()
    capacity_bytes = Config.store_capacity_bytes()
    headroom_bytes = Config.store_headroom_bytes()
    reclaimable_bytes = reclaimable_bytes(capacity_bytes, headroom_bytes)

    {status, shortfall_bytes} =
      case Capacity.check(%{
             used_bytes: used_bytes,
             capacity_bytes: capacity_bytes,
             headroom_bytes: headroom_bytes,
             reclaimable_bytes: reclaimable_bytes
           }) do
        :ok -> {:ok, nil}
        {:refuse, refusal} -> {:refusing, refusal.shortfall_bytes}
      end

    {:ok,
     %{
       used_bytes: used_bytes,
       transcript_bytes: transcript_bytes,
       capacity_bytes: capacity_bytes,
       headroom_bytes: headroom_bytes,
       status: status,
       shortfall_bytes: shortfall_bytes,
       reclaimable_bytes: reclaimable_bytes
     }}
  end

  defp reclaimable_bytes(_capacity_bytes, _headroom_bytes) do
    case build_prune_plan([]) do
      {:ok, _repo_id, plan} -> plan.bytes_reclaimable
      {:error, _} -> 0
    end
  end

  # Shared by `reclaimable_bytes/2`, `prune_preview/1`, and `prune/1`:
  # `Store.runs/2`'s summaries plus each non-damaged run's real byte figure
  # (`Store.run_bytes/1` — its transcripts' recorded bytes plus a fixed
  # per-row estimate for its control rows, contracts/capacity-and-prune.md §
  # Prune rule 5), fed to the pure `Prune.plan/3`.
  defp build_prune_plan(opts) do
    repo = Keyword.get(opts, :repo, Config.repo())
    repo_id = RepoIdentity.partition(repo)

    case Store.runs(repo_id) do
      {:ok, summaries} ->
        boundary = prune_boundary(opts, repo_id)

        protected =
          summaries
          |> Enum.filter(&resumable_summary?/1)
          |> Enum.map(& &1[:run_id])

        run_summaries =
          summaries
          |> Enum.reject(&Map.get(&1, :damaged, false))
          |> Enum.map(fn s ->
            %{
              run_id: s.run_id,
              state: s.state,
              ended_at: s.ended_at,
              bytes: Store.run_bytes({repo_id, s.run_id})
            }
          end)

        {:ok, repo_id, Prune.plan(run_summaries, boundary, protected)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prune_boundary(opts, repo_id) do
    case Keyword.get(opts, :before) do
      nil ->
        DateTime.utc_now()

      %DateTime{} = boundary ->
        boundary

      run_id when is_binary(run_id) ->
        run_id_boundary(repo_id, run_id)
    end
  end

  defp run_id_boundary(repo_id, run_id) do
    case Store.run({repo_id, run_id}) do
      {:ok, %{run: %{ended_at: %DateTime{} = ended_at}}} -> ended_at
      {:ok, %{run: %{started_at: %DateTime{} = started_at}}} -> started_at
      _ -> DateTime.utc_now()
    end
  end

  @doc """
  Preview what pruning `opts[:before]` would remove and how much it would
  reclaim, performing nothing (018, FR-031e). Options: `:repo`, `:before` (a
  `DateTime` or a run_id boundary — defaults to now, i.e. everything ended so
  far). An in-flight or resumable run is never removable regardless of
  boundary and is reported in `retained` with its reason, never silently
  skipped (contracts/capacity-and-prune.md § Prune).
  """
  @spec prune_preview(keyword()) :: {:ok, Prune.plan()} | {:error, term()}
  def prune_preview(opts \\ []) do
    with {:ok, _repo_id, plan} <- build_prune_plan(opts), do: {:ok, plan}
  end

  @doc """
  Prune runs at or before a boundary — the only mechanism in the system that
  removes recorded state (018, FR-031a). Requires `opts[:confirm] == true`;
  otherwise refuses with `{:error, :confirmation_required}` and performs
  nothing. Deletes each removable run in its own transaction
  (`Store.Writer.prune_run/1`), so a transcript can never be pruned out of
  step with the phase attempt it belongs to (FR-035). Options: same as
  `prune_preview/1`, plus `:confirm`.
  """
  @spec prune(keyword()) ::
          {:ok, %{removed: [String.t()], bytes_reclaimed: non_neg_integer()}} | {:error, term()}
  def prune(opts \\ []) do
    if Keyword.get(opts, :confirm, false) do
      with {:ok, repo_id, plan} <- build_prune_plan(opts) do
        {removed, bytes_reclaimed} = prune_removable(repo_id, plan.removable)

        :telemetry.execute(
          [:speckit, :store, :pruned],
          %{bytes_reclaimed: bytes_reclaimed},
          %{repo_id: repo_id, removed: removed}
        )

        {:ok, %{removed: removed, bytes_reclaimed: bytes_reclaimed}}
      end
    else
      {:error, :confirmation_required}
    end
  end

  defp prune_removable(repo_id, removable) do
    {removed, bytes_reclaimed} =
      Enum.reduce(removable, {[], 0}, fn %{run_id: run_id, bytes: bytes}, {ids, total} ->
        case Store.prune_run({repo_id, run_id}) do
          :ok -> {[run_id | ids], total + bytes}
          {:error, _reason} -> {ids, total}
        end
      end)

    {Enum.reverse(removed), bytes_reclaimed}
  end

  defp resumable_summary?(%{damaged: true}), do: true

  defp resumable_summary?(summary) do
    summary.state == :in_flight or
      Enum.any?(summary.feature_statuses, fn {_id, status} -> status in [:escalated, :halted] end)
  end

  @doc """
  Write exactly one self-describing JSON export of `run_id` to `path` (018,
  contracts/export-format.md). Read-only: modifies, locks, and prunes
  nothing, and is available mid-run and under a capacity refusal (FR-032c).
  """
  @spec export_run(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def export_run(run_id, path, opts \\ []) do
    repo = Keyword.get(opts, :repo, Config.repo())
    repo_id = RepoIdentity.partition(repo)

    with {:ok, detail} <- Store.run({repo_id, run_id}) do
      input = %{
        exported_at: DateTime.utc_now(),
        app_version: Application.spec(:speckit_orchestrator, :vsn) |> to_string(),
        schema_version: Migrations.current_version(),
        repo_id: repo_id,
        origin: origin_for(repo),
        run: detail.run,
        settings: detail.settings,
        amendments: detail.amendments,
        cost_entries: detail.cost_entries,
        features: Enum.map(detail.features, &feature_export/1)
      }

      case File.write(path, Export.encode(input)) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The export's "origin" field is the canonicalized remote (FR-032b's
  # self-contained record), not the store's derived `repo_id` segment.
  defp origin_for(repo) do
    case System.cmd("git", ["-C", repo, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      {out, 0} ->
        case out |> String.trim() |> RepoIdentity.canonicalize() do
          {:ok, canonical} -> canonical
          :error -> nil
        end

      {_out, _status} ->
        nil
    end
  end

  defp feature_export(f) do
    Map.put(f, :phase_attempts, Enum.map(f.phase_attempts, &phase_attempt_export/1))
  end

  defp phase_attempt_export(attempt) do
    transcript =
      case Store.transcript(attempt.attempt_id) do
        {:ok, transcript} -> transcript
        {:error, _} -> nil
      end

    %{attempt: attempt, transcript: transcript}
  end

  @doc """
  Everything about one run except transcript bodies (018,
  contracts/store-api.md § run_detail, FR-022, US3): settings, amendments,
  and per feature its phase attempts (execution order), escalations,
  remediation attempts, and checkpoint. Each phase attempt carries a
  `transcript_ref` (its `attempt_id`) rather than the body — retrieve one on
  demand via `transcript/1` (FR-036, SC-009).
  """
  @spec run_detail(String.t(), keyword()) ::
          {:ok, map()} | {:error, :absent} | {:error, {:damaged, term(), term()}}
  def run_detail(run_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Config.repo())
    repo_id = RepoIdentity.partition(repo)

    with {:ok, detail} <- Store.run({repo_id, run_id}) do
      {:ok, Map.put(detail, :features, Enum.map(detail.features, &feature_run_detail/1))}
    end
  end

  defp feature_run_detail(f) do
    Map.put(f, :phase_attempts, Enum.map(f.phase_attempts, &attach_transcript_ref/1))
  end

  defp attach_transcript_ref(attempt) do
    attempt |> Map.from_struct() |> Map.put(:transcript_ref, attempt.attempt_id)
  end

  @doc """
  `run_id` of `repo`'s current in-flight run, or `nil` (018,
  contracts/console-runs.md). Lets the console (`MissionControlLive`,
  `PipelineDagLive`) find the run to pass to `run_detail/1` for its cold-boot
  overlay — a fresh boot or a crash before any resume, when there is no live
  `Coordinator` to read from — without reading the store directly (FR-030c).
  """
  @spec current_run_id(String.t()) :: String.t() | nil
  def current_run_id(repo \\ Config.repo()) do
    case Store.current_run_key(RepoIdentity.partition(repo)) do
      nil -> nil
      {_repo_id, run_id} -> run_id
    end
  end

  @doc """
  On-demand retrieval of one phase attempt's transcript, verbatim (018,
  FR-029). Works after the feature's worktree has been removed — the
  transcript never lived there (SC-006).
  """
  @spec transcript(tuple()) ::
          {:ok, map()} | {:error, :absent} | {:error, {:damaged, term(), term()}}
  def transcript(attempt_ref), do: Store.transcript(attempt_ref)

  @doc """
  Record a resolution against an escalation (018, FR-026). Never deletes the
  entry — the history shows both that it was raised and that it was
  resolved. Options: `:note`, `:by`.
  """
  @spec resolve_escalation(tuple(), keyword()) :: :ok | {:error, term()}
  def resolve_escalation(escalation_id, opts \\ []) do
    resolution = %{
      resolved_at: DateTime.utc_now(),
      note: Keyword.get(opts, :note),
      by: Keyword.get(opts, :by)
    }

    Store.resolve_escalation(escalation_id, resolution)
  end

  # 018: no single record to overwrite wholesale — persists the union rule's
  # two effects individually: a feature the union names but the store never
  # recorded (`:absent_from_record`) is added via `Store.Writer.add_features/2`
  # (`:pending`, same as a fresh `open_run/2` would write it), and any
  # feature genuine evidence proved `:done` that the store didn't yet record
  # as terminal is persisted the same way `Recovery.reconcile_run/2` does.
  defp maybe_write_recovered_record(run_key, proposal, opts) do
    if Keyword.get(opts, :confirm, false) do
      writer = Keyword.get(opts, :writer, Writer)
      write_absent_features(run_key, proposal, writer)
      write_recovered_corrections(run_key, proposal.report.features, writer)
      {:ok, :written, proposal}
    else
      {:ok, proposal}
    end
  end

  defp write_absent_features(run_key, proposal, writer) do
    absent_ids =
      proposal.discrepancies
      |> Enum.filter(&(&1.kind == :absent_from_record))
      |> MapSet.new(& &1.id)

    features =
      proposal.features
      |> Enum.filter(&MapSet.member?(absent_ids, &1.id))
      |> store_features()

    if features != [], do: writer.add_features(run_key, features)
  end

  defp write_recovered_corrections(run_key, feature_rows, writer) do
    Enum.each(feature_rows, fn row ->
      if row.reconciled == :done and row.recorded != :done do
        writer.record_feature_terminal(run_key, row.id, :done, :reconciled_done_signal, [])
      end
    end)
  end

  defp recovery_propose_opts(opts) do
    Keyword.take(opts, [:git, :remote, :backlog_root])
  end

  # A `Backlog.load!/1` raise (missing dir, dangling prereq, cycle) is
  # caught here rather than propagated into an operator session (Principle
  # II's boundary is `recover_record/1`, not `Backlog`, which fails loud by
  # design). No usable layout/backlog_root — nothing to load from.
  defp load_recovery_backlog(layout, opts) do
    case Keyword.get(opts, :backlog_root) || backlog_root(layout) do
      nil ->
        {:error, {:backlog, :no_backlog_root}}

      root ->
        try do
          {:ok, Backlog.load!(root)}
        rescue
          e -> {:error, {:backlog, Exception.message(e)}}
        end
    end
  end

  defp backlog_root(%Layout{breakdown_root: root}) when is_binary(root), do: root
  defp backlog_root(_layout), do: nil

  # Recovery.reconcile_run/2's `statuses` map persists a `{:resume, phase}`
  # feature as `:running` (the report's human-facing value — the feature
  # genuinely is mid-run, not never-started). The Coordinator's own
  # `Release.next_wave/4`, however, only releases `:pending` features
  # (`:running` counts as already in-flight and is never (re-)dispatched) —
  # so the *seed* fed to the Coordinator flips every `resume_phases` feature
  # to `:pending` here, letting it release normally while `dispatch_resume/7`
  # (via `resume_phases`) still starts it at the reconciled phase, not
  # `Pipeline.first()`.
  defp dispatch_statuses(statuses, resume_phases) do
    Enum.reduce(resume_phases, statuses, fn {id, _phase}, acc -> Map.put(acc, id, :pending) end)
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

  # 018: the store's current in-flight run for the configured repo, replacing
  # `RunManifest.read/0` — a `:no_manifest`/`:corrupt_manifest` tag is kept
  # on the error for API compatibility with existing callers/tests.
  defp read_current_run(repo \\ Config.repo()) do
    case Store.current_run_key(RepoIdentity.partition(repo)) do
      nil ->
        {:error, :no_manifest}

      run_key ->
        case Store.run(run_key) do
          {:ok, detail} -> {:ok, run_key, detail}
          {:error, {:damaged, _key, _reason}} -> {:error, :corrupt_manifest}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # A caller-supplied :runner/:executor still wins (test seam), same
  # precedence as inject_resume_scope_strategy/13 above.
  defp inject_resume_run_strategy(opts, pr_workflow?, run_context, layout, resume_phases, run_key) do
    cond do
      Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor) ->
        opts

      pr_workflow? ->
        Keyword.put(
          opts,
          :executor,
          resume_run_executor(run_context, layout, resume_phases, run_key)
        )

      true ->
        Keyword.put(opts, :runner, resume_run_runner(run_context, layout, resume_phases, run_key))
    end
  end

  defp resume_run_runner(run_context, layout, resume_phases, run_key) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        dispatch_resume(feature, nil, notify, run_context, layout, resume_phases, run_key)
      end)

      :ok
    end
  end

  # Executor shape for the PR workflow — `base` (the stack's current top) is
  # used only for a never-started :pending feature; a checkpointed feature
  # ignores it and reuses/recreates its own existing worktree/branch.
  defp resume_run_executor(run_context, layout, resume_phases, run_key) do
    fn feature, base, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        dispatch_resume(feature, base, notify, run_context, layout, resume_phases, run_key)
      end)

      :ok
    end
  end

  # `resume_phases` is `Recovery.reconcile_run/2`'s corrected `{:resume,
  # phase}` map (FR-004/005) — a reconciled mid-run feature resumes at the
  # phase *after* its latest committed boundary, overriding whatever the
  # checkpoint's own recorded phase would otherwise resolve to (never
  # resumes within a phase, always at a full phase boundary).
  defp dispatch_resume(feature, base, notify, run_context, layout, resume_phases, run_key) do
    case Store.checkpoint(run_key, feature.id) do
      {:ok, checkpoint} ->
        run_from_checkpoint(
          feature,
          checkpoint,
          notify,
          run_context,
          layout,
          resume_phases,
          run_key
        )

      {:error, {:damaged, _key, _reason}} ->
        notify.(feature.id, :failed, {:checkpoint, :corrupt})

      {:error, _absent_or_other} ->
        run_fresh(feature, base, notify, run_context, layout, run_key)
    end
  end

  defp run_from_checkpoint(
         feature,
         checkpoint,
         notify,
         run_context,
         layout,
         resume_phases,
         run_key
       ) do
    from_opts =
      case Map.get(resume_phases, feature.id) do
        nil -> []
        phase -> [from: phase]
      end

    case resolve_start_phase(checkpoint, from_opts) do
      {:ok, start_phase} ->
        case resume_worktree(feature, layout) do
          {:ok, worktree} ->
            FeatureRunner.run(feature,
              worktree: worktree,
              ledger: Ledger,
              notify: notify,
              start_phase: start_phase,
              run_context: run_context,
              layout: layout,
              run_key: run_key
            )

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end

      {:error, reason} ->
        notify.(feature.id, :failed, reason)
    end
  end

  defp run_fresh(feature, base, notify, run_context, layout, run_key) do
    create_opts = if base, do: [base: base], else: []
    create_opts = create_opts ++ worktree_create_opts(layout)

    case Worktree.create(feature, create_opts) do
      {:ok, worktree} ->
        FeatureRunner.run(feature,
          worktree: worktree,
          ledger: Ledger,
          notify: notify,
          run_context: run_context,
          layout: layout,
          run_key: run_key
        )

      {:error, reason} ->
        notify.(feature.id, :failed, {:worktree, reason})
    end
  end

  defp log_context_fallback(_feature_id, []), do: :ok

  defp log_context_fallback(feature_id, fell_back) do
    Logger.info(
      "feature #{feature_id} resume: no recorded context for #{inspect(fell_back)} — " <>
        "falling back to live Config"
    )
  end

  # FR-002/003/004: an explicit/backlog feature wins over the store's
  # recorded identity whenever both exist; else the store's `feature_record`
  # slug/path rebuilds the feature; else unknown-feature. A best-effort
  # backlog load never raises past resume/2 — a missing/unloadable backlog
  # is non-fatal once store identity is available (FR-004).
  defp resolve_identity(feature_id, feature_record, opts) do
    features = resolve_features(opts)

    case Enum.find(features, &(&1.id == feature_id)) do
      nil -> checkpoint_identity(feature_id, feature_record)
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

  defp checkpoint_identity(feature_id, %{slug: slug, path: path})
       when is_binary(slug) and is_binary(path) do
    {:ok, %Feature{id: feature_id, slug: slug, path: path, status: :pending}}
  end

  defp checkpoint_identity(feature_id, _feature_record),
    do: {:error, {:unknown_feature, feature_id}}

  # `:from` takes precedence over the checkpoint's recorded `phase` — already
  # the correct resume-at phase either way (`FeatureRunner.checkpoint_for/3`
  # records the *next* phase for an in-progress boundary and the diverted
  # phase itself for a gate/halt/failure, so no `Pipeline.next/3` re-derivation
  # is needed here, unlike the pre-018 file checkpoint's `last_phase`).
  defp resolve_start_phase(%{phase: phase}, opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, from} -> validate_phase(from)
      :error -> validate_phase(phase)
    end
  end

  defp resolve_start_phase(nil, _opts), do: {:error, :no_checkpoint}

  defp validate_phase(phase) do
    if Pipeline.phase?(phase), do: {:ok, phase}, else: {:error, {:unknown_phase, phase}}
  end

  # Reuse the kept worktree if one exists (a prior resolve/1 froze it, or the
  # feature never tore it down); else recreate it from the existing branch.
  # Never falls back to a fresh branch (FR-005, SC-005) — a missing branch is
  # a distinct worktree error, not silently re-created from HEAD.
  defp resume_runner(
         start_phase,
         prompt,
         remediation_prompt,
         remediation_model,
         run_context,
         layout,
         start_task_phase,
         run_key
       ) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case resume_worktree(feature, layout) do
          {:ok, worktree} ->
            FeatureRunner.run(feature,
              worktree: worktree,
              ledger: Ledger,
              notify: notify,
              start_phase: start_phase,
              resume_prompt: prompt,
              remediation_prompt: remediation_prompt,
              remediation_model: remediation_model,
              run_context: run_context,
              layout: layout,
              start_task_phase: start_task_phase,
              reset_implement_sessions: true,
              run_key: run_key
            )

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  # PR-workflow resume counterpart to resume_runner/8 — same worktree
  # reuse/recreate logic, but shaped as an `:executor` (feature, base, notify)
  # so run_stacked/1's stacked_runner wraps it with stacking + preflight +
  # PR-on-:done (FR-009). `base` (the current stack top) is ignored: a resumed
  # feature reuses/recreates its own existing worktree/branch, not a fresh one
  # branched off the stack.
  defp resume_executor(
         start_phase,
         prompt,
         remediation_prompt,
         remediation_model,
         run_context,
         layout,
         start_task_phase,
         run_key
       ) do
    fn feature, _base, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case resume_worktree(feature, layout) do
          {:ok, worktree} ->
            FeatureRunner.run(feature,
              worktree: worktree,
              ledger: Ledger,
              notify: notify,
              start_phase: start_phase,
              resume_prompt: prompt,
              remediation_prompt: remediation_prompt,
              remediation_model: remediation_model,
              run_context: run_context,
              layout: layout,
              start_task_phase: start_task_phase,
              reset_implement_sessions: true,
              run_key: run_key
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
  defp resume_worktree(feature, layout) do
    worktree = Worktree.locate(feature, worktree_create_opts(layout))

    result =
      cond do
        File.dir?(worktree.path) ->
          {:ok, worktree}

        branch_exists?(worktree.repo, worktree.branch) ->
          Worktree.create(feature, worktree_create_opts(layout))

        true ->
          {:error, :branch_missing}
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

    layout = Keyword.get(extra, :layout)

    base = [
      features: Keyword.get_lazy(opts, :features, fn -> load_backlog(layout) end),
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

  # T013: load the selected breakdown package's own dir (per-package, not the
  # flat pre-012 dir) — the run's Layout already resolved which package via
  # resolve_scope/2. Falls back to the legacy flat Config.breakdown_dir/0 dir
  # when the resolved package dir doesn't exist (no packages were ever found
  # under specs/autonomous/breakdown/, so resolve_scope/2's placeholder scope
  # doesn't correspond to a real directory — an old-layout repo, or one that
  # hasn't adopted packages yet, FR-013) or layout has no breakdown_root
  # (`nil`/ad-hoc — unreachable in practice, an ad-hoc run always supplies
  # :features itself).
  defp load_backlog(%Layout{breakdown_root: root}) when is_binary(root) do
    if File.dir?(root), do: Backlog.load!(root), else: load_backlog()
  end

  defp load_backlog(_layout), do: load_backlog()

  # Real runner: each feature gets its own worktree, then runs the pipeline.
  # A worktree that can't be created (missing scaffold) fails the feature
  # rather than running it in an unguarded tree.
  defp default_runner(feature, notify, run_context, layout) do
    Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
      case Worktree.create(feature, worktree_create_opts(layout)) do
        {:ok, worktree} ->
          FeatureRunner.run(feature,
            worktree: worktree,
            ledger: Ledger,
            notify: notify,
            run_context: run_context,
            layout: layout,
            run_key: current_run_key()
          )

        {:error, reason} ->
          notify.(feature.id, :failed, {:worktree, reason})
      end
    end)

    :ok
  end

  # `:worktree_root` resolved from the run's `%Layout{}` (FR-003) instead of
  # `Config.worktree_root/0` — the segment-keyed machine-global root, so two
  # target repos never share a worktree subpath (SC-001).
  defp worktree_create_opts(nil), do: []
  defp worktree_create_opts(%Layout{worktree_root: root}), do: [worktree_root: root]

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
    # T023: a single-spec run is always ad-hoc scope — never a breakdown
    # package selection.
    opts = opts |> Keyword.put(:features, [feature]) |> Keyword.put(:scope, :ad_hoc)
    caller_test_mode? = Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor)
    pr_workflow? = Keyword.get(opts, :pr_workflow, Config.pr_workflow?())
    run_context = RunContext.capture(opts)

    cond do
      caller_test_mode? ->
        {:ok, opts}

      pr_workflow? ->
        case TargetPack.verify(Config.repo(), check_remote: Config.pr_remote()) do
          :ok ->
            case preflight_layout(opts) do
              {:ok, layout} ->
                opts =
                  opts
                  |> Keyword.put(:layout, layout)
                  |> Keyword.put(:executor, seed_executor(description, run_context, layout))

                {:ok, opts}

              {:error, _reason} = err ->
                err
            end

          {:error, problems} ->
            {:error, {:preflight, problems}}
        end

      true ->
        case preflight_layout(opts) do
          {:ok, layout} ->
            opts =
              opts
              |> Keyword.put(:layout, layout)
              |> Keyword.put(:runner, seed_runner(description, run_context, layout))

            {:ok, opts}

          {:error, _reason} = err ->
            err
        end
    end
  end

  # T024: existing ad-hoc ids (dir listing under the dedicated ad-hoc location,
  # never a breakdown package's dir — packages are scope-isolated and may
  # reuse ids across each other by design, US2) + existing `feature/NNN-*`
  # branch ids (git), so an auto-assigned ad-hoc id never collides with — and
  # never clobbers — a prior ad-hoc feature. `Layout.in_repo_rel/1` accepts a
  # bare scope with no built `%Layout{}` (no segment/IO needed for this pure
  # path join).
  defp gather_taken_ids(opts) do
    repo = Keyword.get(opts, :repo, Config.repo())
    ad_hoc_dir = Keyword.get(opts, :ad_hoc_dir, Path.join(repo, Layout.in_repo_rel(:ad_hoc)))

    breakdown_ids(ad_hoc_dir) ++ branch_ids(repo)
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

  defp seed_runner(description, run_context, layout) do
    fn feature, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case Worktree.create(feature, worktree_create_opts(layout)) do
          {:ok, worktree} ->
            run_seeded(feature, worktree, description, notify, run_context, layout)

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  defp seed_executor(description, run_context, layout) do
    fn feature, base, notify ->
      Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
        case Worktree.create(feature, [base: base] ++ worktree_create_opts(layout)) do
          {:ok, worktree} ->
            run_seeded(feature, worktree, description, notify, run_context, layout)

          {:error, reason} ->
            notify.(feature.id, :failed, {:worktree, reason})
        end
      end)

      :ok
    end
  end

  defp run_seeded(feature, worktree, description, notify, run_context, layout) do
    case write_seed(worktree, feature, description, layout) do
      :ok ->
        FeatureRunner.run(feature,
          worktree: worktree,
          ledger: Ledger,
          notify: notify,
          run_context: run_context,
          layout: layout,
          run_key: current_run_key()
        )

      {:error, reason} ->
        notify.(feature.id, :failed, {:seed, reason})
    end
  end

  # Writes to <worktree>/<Layout.in_repo_rel(layout)>/<basename(feature.path)>
  # — the ad-hoc scope's worktree-relative suffix, the exact path
  # `PhaseRequest.breakdown_ref/2` resolves for the `specify` phase — and
  # ONLY inside the worktree, never the base-repo-absolute `ad_hoc_root`
  # (resolves analyze finding I1; Principle III containment, unchanged from
  # 001).
  defp write_seed(worktree, feature, description, layout) do
    path = Path.join([worktree.path, Layout.in_repo_rel(layout), Path.basename(feature.path)])

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
  #     branch and opens the PR (default: `publish_feature/3`, layout-closed).
  # A `:runner` override bypasses stacking entirely (used to test cap-1 sequencing).

  defp run_stacked(opts, run_context, layout, run_key) do
    test_mode? = Keyword.has_key?(opts, :runner) or Keyword.has_key?(opts, :executor)

    # This branch is what pins the cap to 1 (below), so it is also where the
    # recorded context stops describing the *requested* cap and starts
    # describing the one the run actually uses. `RunContext.capture/1` stays a
    # dumb per-field resolver — the pin belongs with the decision, not with the
    # capture. Without this the manifest and every checkpoint recorded the live
    # Config value (typically 2) for a run that only ever released one feature
    # at a time, and the console read that number back as the run's cap.
    run_context = %{run_context | max_concurrency: 1}

    with :ok <- preflight_stacked(test_mode?) do
      {:ok, tracker} = StackTracker.start_link(Config.pr_base())

      publisher =
        Keyword.get(opts, :publisher, fn feature, base ->
          publish_feature(feature, base, layout)
        end)

      executor =
        Keyword.get(opts, :executor, fn feature, base, notify ->
          default_executor(feature, base, notify, run_context, layout)
        end)

      runner = Keyword.get(opts, :runner) || stacked_runner(tracker, publisher, executor)

      start_run(opts,
        max_concurrency: 1,
        context: run_context,
        layout: layout,
        run_key: run_key,
        runner: runner
      )
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

  defp default_executor(feature, base, notify, run_context, layout) do
    Task.Supervisor.start_child(SpeckitOrchestrator.RunnerSup, fn ->
      case Worktree.create(feature, [base: base] ++ worktree_create_opts(layout)) do
        {:ok, worktree} ->
          FeatureRunner.run(feature,
            worktree: worktree,
            ledger: Ledger,
            notify: notify,
            run_context: run_context,
            layout: layout,
            run_key: current_run_key()
          )

        {:error, reason} ->
          notify.(feature.id, :failed, {:worktree, reason})
      end
    end)

    :ok
  end

  # Real publisher: push the feature branch, then open a PR against its base.
  defp publish_feature(feature, base, layout) do
    wt = Worktree.locate(feature, worktree_create_opts(layout))

    with :ok <- Worktree.push(wt, Config.pr_remote()) do
      {title, body} = pr_text(feature, base)
      PullRequest.open(Config.repo(), %{head: wt.branch, base: base, title: title, body: body})
    end
  end

  # Prefer the Claude-authored PR text `Store.Writer.record_feature_terminal/5`
  # recorded on :done (018 — replaces `Describe.read_pr/2`); fall back to a
  # template if it is absent/empty or this run isn't store-backed.
  defp pr_text(feature, base) do
    case store_pr_description(feature.id) do
      %{pr_title: t, pr_body: b} when t not in [nil, ""] and b not in [nil, ""] ->
        {t, b}

      _ ->
        {"feat(#{feature.id}-#{feature.slug}): autonomous build",
         "Autonomous build of feature #{feature.id} (#{feature.slug}) by " <>
           "speckit_orchestrator.\n\nStacked on `#{base}`."}
    end
  end

  defp store_pr_description(feature_id) do
    with run_key when run_key != nil <- current_run_key(),
         {:ok, detail} <- Store.run(run_key),
         %{pr_description: %{} = pr} <-
           Enum.find(detail.features, &(&1.feature_id == feature_id)) do
      pr
    else
      _ -> nil
    end
  end

  # The store's `{repo_id, run_id}` for `repo`'s current in-flight run, or
  # `nil` (018) — the lookup a closure built *before* the run's `run_key` is
  # known (`run_spec/2`'s seed closures) or reused across a resume (which
  # continues rather than re-opens) resolves at call time instead of having
  # a freshly-minted run_id threaded through it.
  defp current_run_key(repo \\ Config.repo()) do
    Store.current_run_key(RepoIdentity.partition(repo))
  end
end
