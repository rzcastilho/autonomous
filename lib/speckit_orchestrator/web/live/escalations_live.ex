defmodule SpeckitOrchestrator.Web.EscalationsLive do
  @moduledoc """
  US3 — Escalations (`/escalations`): lists every diverted (`:escalated`,
  `:halted`, `:failed`) feature with its checkpoint pointer, clarify
  questions, and recorded run context, and drives recovery — a guided
  `resume/2` (with operator guidance + start-phase override) or a full
  restart via `resolve/2` + `run/1` (`specs/008-control-plane/tasks.md`
  T046-T053).

  Reads the same `ConsoleReadModel.merge/3` view as Mission Control (one
  status→color palette, one phase order — FR-034) and filters it to diverted
  features; `SpeckitOrchestrator.run_detail/1`'s per-feature `checkpoint`
  (018) supplies the pointer and, for `:escalated` features, the feature's
  worktree is globbed for its `spec.md`'s `## NEEDS HUMAN` block (FR-021). No
  checkpoint steers the view to full-restart only — `resume/2` is never
  offered without one (FR-023).

  Test seam: `Application.get_env(:speckit_orchestrator, :console_test_runner)`,
  mirroring `TriggerLive`, is injected as the `:runner` opt on both recovery
  actions so LiveView tests never touch a real worktree/CLI.
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{
    Config,
    ConsoleProjection,
    ConsoleReadModel,
    Coordinator,
    Feature,
    Ledger,
    Pipeline,
    TaskPhaseRef,
    TaskPlan,
    Worktree
  }

  alias SpeckitOrchestrator.TaskPlan.TaskPhase

  @diverted_statuses [:escalated, :halted, :failed]

  # Line-anchored, mirroring `RunFeaturePhase`'s clarify-gate marker — prose
  # that merely *mentions* the heading must not be mistaken for it.
  @needs_human_marker ~r/^\#\#[ \t]+NEEDS HUMAN[ \t]*$/m

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpeckitOrchestrator.PubSub, ConsoleProjection.topic())
    end

    {:ok,
     socket
     |> assign(
       page_title: "Escalations",
       current_path: "/escalations",
       selected_feature_id: nil,
       remediation_models: Config.valid_models()
     )
     |> refresh()}
  end

  # Diverted features are rare state-changing events (not a hot render loop
  # like Mission Control's feed), so every broadcast just recomputes the list
  # from the authoritative sources rather than patching in place.
  @impl true
  def handle_info({:console, _kind, _payload}, socket), do: {:noreply, refresh(socket)}

  defp refresh(socket) do
    view =
      ConsoleReadModel.merge(coordinator_status(), ledger_snapshot(), ConsoleProjection.read())

    run_id = SpeckitOrchestrator.current_run_id()

    assign(socket,
      run_id: run_id,
      escalations: build_escalations(view, current_run_detail(run_id))
    )
  end

  defp current_run_detail(nil), do: nil

  defp current_run_detail(run_id) do
    case SpeckitOrchestrator.run_detail(run_id) do
      {:ok, detail} -> detail
      _ -> nil
    end
  end

  defp coordinator_status do
    if Process.whereis(Coordinator), do: Coordinator.status(Coordinator)
  end

  defp ledger_snapshot do
    if Process.whereis(Ledger), do: Ledger.snapshot(Ledger)
  end

  # ---- EscalationView assembly (data-model.md) -----------------------------

  defp build_escalations(view, run_detail) do
    run_context = run_detail && run_detail.settings

    view.per_feature
    |> Enum.filter(fn {_id, f} -> f.status in @diverted_statuses end)
    |> Enum.sort_by(fn {id, _f} -> id end)
    |> Enum.map(fn {id, feature} ->
      escalation_view(id, feature, feature_detail(run_detail, id), run_context)
    end)
  end

  defp feature_detail(nil, _id), do: nil

  defp feature_detail(%{features: features}, id),
    do: Enum.find(features, &(&1.feature_id == id))

  defp escalation_view(id, feature, feature_detail, run_context) do
    checkpoint = feature_detail && feature_detail.checkpoint
    identity = identity(id, feature, feature_detail)
    default_phase = default_phase(checkpoint)

    %{
      id: id,
      feature: feature,
      checkpoint: checkpoint,
      run_context: run_context,
      divert_reason: divert_reason(checkpoint),
      clarify: clarify_block(identity, feature.status),
      identity: identity,
      default_phase: default_phase,
      task_phase_picker: task_phase_picker(identity, checkpoint, default_phase)
    }
  end

  # ---- task-phase picker (US2, checkpoint-implement-chunk.md §4) ----------

  # Meaningful only for an implement resume over a structured task list —
  # every other diverted feature (or an unstructured/no-`tasks.md` target)
  # gets no picker at all, so `resume/2` behaves exactly as it did before this
  # feature (FR-019 spirit, SC-005).
  defp task_phase_picker(_identity, _checkpoint, phase) when phase != :implement, do: nil

  defp task_phase_picker(identity, checkpoint, :implement) do
    plan = identity |> Worktree.locate() |> Map.fetch!(:path) |> TaskPlan.load()

    if plan.structured? do
      ref = ref_from_checkpoint(checkpoint)
      {:ok, tp, match_kind} = TaskPlan.locate(plan, ref)

      %{
        task_phases: plan.task_phases,
        total: TaskPlan.task_phase_count(plan),
        default_ordinal: tp.ordinal,
        weak_match?: match_kind != :number
      }
    end
  end

  defp ref_from_checkpoint(%{implement_chunk: %{} = chunk}) do
    %TaskPhaseRef{
      ordinal: Map.get(chunk, :ordinal),
      number: Map.get(chunk, :number),
      title: Map.get(chunk, :title)
    }
  end

  defp ref_from_checkpoint(_checkpoint), do: nil

  # The store's `feature_run` record wins when present (018) — it carries the
  # exact slug/path the feature ran under; otherwise Coordinator's own
  # `Feature` struct still knows the slug (it is tracking this feature this
  # run) — `path` degrades to `""`, harmless: nothing downstream reads it
  # except a future checkpoint write.
  defp identity(id, _feature, %{slug: slug} = feature_detail) when is_binary(slug) do
    %Feature{
      id: id,
      number: identity_number(id, feature_detail),
      slug: slug,
      path: feature_detail.path || "",
      group: Map.get(feature_detail, :group, :backlog),
      created_at: Map.get(feature_detail, :created_at)
    }
  end

  defp identity(id, feature, _feature_detail) do
    %Feature{id: id, number: identity_number(id, %{}), slug: feature.slug, path: ""}
  end

  defp identity_number(id, source) do
    Map.get(source, :number) || String.to_integer(id)
  end

  defp divert_reason(%{reason: reason}), do: reason
  defp divert_reason(_checkpoint), do: nil

  defp default_phase(%{phase: phase}) when not is_nil(phase), do: phase
  defp default_phase(_checkpoint), do: List.first(Pipeline.phases())

  defp safe_phase(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)
    if Pipeline.phase?(atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp safe_phase(_phase), do: :error

  # Clarify questions only apply to the clarify-gate divert (`:escalated`);
  # `:halted`/`:failed` features have no `## NEEDS HUMAN` block to surface.
  defp clarify_block(_identity, status) when status != :escalated, do: nil

  defp clarify_block(identity, :escalated) do
    identity
    |> Worktree.locate()
    |> Map.fetch!(:path)
    |> Path.join("specs/**/spec.md")
    |> Path.wildcard()
    |> Enum.find_value(&extract_needs_human/1)
  end

  defp extract_needs_human(file) do
    with {:ok, content} <- File.read(file),
         [_before, after_marker] <- Regex.split(@needs_human_marker, content, parts: 2) do
      after_marker |> String.split(~r/^\#\#[ \t]/m, parts: 2) |> List.first() |> String.trim()
    else
      _ -> nil
    end
  end

  # ---- recovery actions (FR-022, FR-023) -----------------------------------

  @impl true
  def handle_event(
        "resume",
        %{"feature_id" => id, "prompt" => prompt, "from" => from} = params,
        socket
      ) do
    case Enum.find(socket.assigns.escalations, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      escalation ->
        opts =
          test_opts()
          |> Keyword.put(:features, [escalation.identity])
          |> Keyword.put(:prompt, blank_to_nil(prompt))
          |> Keyword.put(:from, safe_phase!(from, escalation.default_phase))
          |> Keyword.put(:remediation_prompt, blank_to_nil(Map.get(params, "remediation_prompt")))
          |> Keyword.put(:remediation_model, blank_to_nil(Map.get(params, "remediation_model")))
          |> maybe_put_task_phase(Map.get(params, "from_task_phase"))

        case run_unlinked(fn -> SpeckitOrchestrator.resume(id, opts) end) do
          {:ok, _pid} ->
            {:noreply, socket |> put_flash(:info, "Feature #{id} resumed") |> refresh()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Resume failed: #{format_resume_error(reason)}")}
        end
    end
  end

  def handle_event("full_restart", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.escalations, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      escalation ->
        opts = Keyword.put(test_opts(), :features, [escalation.identity])

        with :ok <- SpeckitOrchestrator.resolve(id, opts),
             {:ok, _pid} <- run_unlinked(fn -> SpeckitOrchestrator.run(opts) end) do
          {:noreply,
           socket
           |> put_flash(:info, "Feature #{id} restarted from phase 1; worktree freed")
           |> refresh()}
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Restart failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("select_feature", %{"id" => id}, socket) do
    {:noreply, assign(socket, selected_feature_id: id)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, selected_feature_id: nil)}
  end

  defp test_opts do
    case Application.get_env(:speckit_orchestrator, :console_test_runner) do
      nil -> []
      runner -> [runner: runner]
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: s)

  # The submitted ordinal reaches `resume/2` as `:from_task_phase` — an
  # integer, dropped (not overridden) unless the resolved start phase is
  # `:implement` (`SpeckitOrchestrator.resume/2`'s own guard).
  defp maybe_put_task_phase(opts, nil), do: opts
  defp maybe_put_task_phase(opts, ""), do: opts

  defp maybe_put_task_phase(opts, ordinal_str) do
    case Integer.parse(ordinal_str) do
      {n, _rest} -> Keyword.put(opts, :from_task_phase, n)
      :error -> opts
    end
  end

  defp safe_phase!(phase_str, default) do
    case safe_phase(phase_str) do
      {:ok, p} -> p
      :error -> default
    end
  end

  defp format_resume_error(:no_checkpoint), do: "no checkpoint"
  defp format_resume_error(:corrupt_checkpoint), do: "corrupt checkpoint"
  defp format_resume_error({:unknown_phase, p}), do: "unknown phase #{inspect(p)}"
  defp format_resume_error({:unknown_feature, id}), do: "unknown feature #{id}"
  defp format_resume_error({:unknown_model, alias}), do: "unknown model #{inspect(alias)}"

  defp format_resume_error({:active_run, _pid}),
    do: "a run is already live for this repository — stop it, or retry with force"

  defp format_resume_error(other), do: inspect(other)

  # See TriggerLive's `run_unlinked/1` for why: `run/1` (via `resume/2`)
  # `GenServer.start_link`s the Coordinator linked to its caller, and this
  # view's process outlives the call — an unlinked task decouples the
  # Coordinator's lifetime from this transient LiveView.
  defp run_unlinked(fun) do
    SpeckitOrchestrator.RunnerSup
    |> Task.Supervisor.async_nolink(fun)
    |> Task.await()
  end

  # ---- render -------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-escalations" data-view="escalations">
      <div class="escalations-intro">
        <div class="escalations-title">Escalations &amp; halts · human-in-the-loop</div>
        <div class="escalations-sub">
          Each diverted feature wrote a checkpoint. Resume restarts at the checkpointed
          phase (keeps completed work); Full restart is a full restart from specify.
        </div>
      </div>

      <div :if={@escalations == []} class="empty-state escalation-empty" data-state="all-clear">
        <div class="empty-state-icon">&check;</div>
        <p class="empty-state-title">No open escalations</p>
        <p>The clarify and analyze gates are clear. All in-flight features are draining normally.</p>
      </div>

      <div
        :for={e <- @escalations}
        id={"escalation-#{e.id}"}
        class="escalation-card"
        data-escalation={e.id}
        style={"border-color: #{status_color(e.feature.status)}40;"}
      >
        <div class="escalation-card-head" style={"background: #{status_color(e.feature.status)}0d;"}>
          <span class="escalation-dot" style={"background-color: #{status_color(e.feature.status)};"}></span>
          <span class="escalation-title">
            {e.id} <span :if={e.feature.slug}>· {e.feature.slug}</span>
          </span>
          <.status_pill status={e.feature.status} />
          <span :if={e.divert_reason} class="escalation-reason" data-divert-reason>
            reason: {inspect(e.divert_reason)}
          </span>
        </div>

        <div class="escalation-card-body">
          <div :if={e.checkpoint} class="checkpoint-box" data-checkpoint="ok">
            <div class="checkpoint-box-label">
              <span class="checkpoint-dot"></span> CHECKPOINT
            </div>
            <dl class="checkpoint-fields">
              <dt>last_phase</dt>
              <dd>{e.checkpoint.phase}</dd>
              <dt>status</dt>
              <dd>{e.checkpoint.status}</dd>
              <dt>session_id</dt>
              <dd>{e.checkpoint.session_id || "—"}</dd>
              <dt>reason</dt>
              <dd>{inspect(e.checkpoint.reason)}</dd>
            </dl>

            <div class="run-context-label" data-resume-scope-note>
              Resuming continues the whole run — every other feature the run
              recorded keeps its state and dependents release automatically
              as prerequisites complete (016).
            </div>

            <div :if={e.run_context} class="run-context-label">
              RUN_CONTEXT · resume re-executes under recorded run shape
            </div>
            <div :if={e.run_context} class="run-context" data-run-context>
              <span :for={{k, v} <- e.run_context} class="run-context-chip">
                {k}=<span>{inspect(v)}</span>
              </span>
            </div>

            <div
              :if={auto_remediation_summary(e.checkpoint)}
              class="run-context-label"
              data-auto-remediation
            >
              {auto_remediation_summary(e.checkpoint)}
            </div>
          </div>

          <p :if={is_nil(e.checkpoint)} class="checkpoint-box checkpoint-error" data-checkpoint="absent">
            No usable checkpoint — full restart only.
          </p>

          <div :if={e.clarify} class="clarify-block" data-clarify>
            <pre>{e.clarify}</pre>
          </div>

          <form
            :if={e.checkpoint}
            id={"resume-form-#{e.id}"}
            phx-submit="resume"
            data-form="resume"
            class="resume-form"
          >
            <input type="hidden" name="feature_id" value={e.id} />
            <label class="field-label">
              Guidance
              <textarea name="prompt" phx-debounce="200" class="resume-textarea"></textarea>
            </label>
            <label class="field-label">
              Start phase
              <select name="from" class="resume-select">
                <option :for={p <- Pipeline.phases()} value={p} selected={p == e.default_phase}>
                  {p}
                </option>
              </select>
            </label>
            <label :if={e.task_phase_picker} class="field-label" data-field="task-phase-picker">
              Starting task-phase
              <select name="from_task_phase" class="resume-select" data-field="task-phase">
                <option
                  :for={tp <- e.task_phase_picker.task_phases}
                  value={tp.ordinal}
                  selected={tp.ordinal == e.task_phase_picker.default_ordinal}
                >
                  {task_phase_label(tp, e.task_phase_picker.total)}
                </option>
              </select>
              <span :if={e.task_phase_picker.weak_match?} class="field-hint" data-weak-match>
                matched by a weaker-than-number rule — the task list was renumbered
              </span>
            </label>
            <label class="field-label">
              Remediation (runs once, before the start phase — leave blank to skip)
              <textarea
                name="remediation_prompt"
                phx-debounce="200"
                class="resume-textarea"
                data-field="remediation-prompt"
              ></textarea>
            </label>
            <label class="field-label">
              Remediation model
              <select name="remediation_model" class="resume-select" data-field="remediation-model">
                <option value="">Default ({e.default_phase}'s own model)</option>
                <option :for={m <- @remediation_models} value={m}>{m}</option>
              </select>
            </label>
            <div class="escalation-actions">
              <button type="submit" class="btn-primary" data-action={"resume-#{e.id}"}>
                &#9654; Resume
              </button>
              <button
                type="button"
                phx-click="full_restart"
                phx-value-id={e.id}
                class="btn-secondary"
                data-action={"full-restart-#{e.id}"}
              >
                &#8635; Full restart
              </button>
              <a href={transcript_href(@run_id, e)} class="btn-secondary" data-action={"transcript-#{e.id}"}>
                &#8801; Read {phase_label(e)}.md
              </a>
            </div>
          </form>

          <div :if={is_nil(e.checkpoint)} class="escalation-actions">
            <button
              type="button"
              phx-click="full_restart"
              phx-value-id={e.id}
              class="btn-secondary"
              data-action={"full-restart-#{e.id}"}
            >
              &#8635; Full restart
            </button>
            <a href={transcript_href(@run_id, e)} class="btn-secondary" data-action={"transcript-#{e.id}"}>
              &#8801; Read {phase_label(e)}.md
            </a>
          </div>
        </div>
      </div>

      <.feature_drawer
        :if={@selected_feature_id}
        feature_id={@selected_feature_id}
        feature={
          Enum.find_value(@escalations, &(&1.id == @selected_feature_id && &1.feature))
        }
        on_close="close_drawer"
      />
    </div>
    """
  end

  # What the loop already tried, read from the checkpoint's optional
  # `analyze_remediation` key (017, SC-005) — so a reviewer sees the attempt
  # budget without opening raw agent logs. The per-attempt transcripts
  # themselves are reachable through the existing transcripts link below.
  # Absent for every pre-017 checkpoint and for any feature whose loop made no
  # attempt.
  defp auto_remediation_summary(%{analyze_remediation: %{} = r}) do
    with used when is_integer(used) <- Map.get(r, :attempts_used),
         limit when is_integer(limit) <- Map.get(r, :limit) do
      "auto-remediation: #{used}/#{limit} attempts #{verb(used, limit)}" <>
        " (threshold #{Map.get(r, :threshold) || "?"})"
    else
      _ -> nil
    end
  end

  defp auto_remediation_summary(_checkpoint), do: nil

  defp verb(used, limit) when used >= limit, do: "exhausted"
  defp verb(_used, _limit), do: "spent"

  defp task_phase_label(%TaskPhase{} = tp, total) do
    mark = if TaskPhase.complete?(tp), do: " ✓", else: ""
    "#{tp.ordinal}/#{total} · #{tp.number}: #{tp.title}#{mark}"
  end

  defp status_color(status), do: palette() |> Map.get(status, {"", "#64748b"}) |> elem(1)

  defp phase_label(e), do: to_string(e.default_phase)

  # Run-scoped attempt reference (018, contracts/console-runs.md Navigation) —
  # `TranscriptsLive` resolves the latest attempt for this feature/phase
  # within the run rather than reading a file path directly.
  defp transcript_href(nil, e), do: "/transcripts?feature=#{e.id}&phase=#{e.default_phase}"

  defp transcript_href(run_id, e),
    do: "/transcripts?run_id=#{run_id}&feature=#{e.id}&phase=#{e.default_phase}"
end
