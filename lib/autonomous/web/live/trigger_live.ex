defmodule Autonomous.Web.TriggerLive do
  @moduledoc """
  US2 — Trigger Run (`/trigger`): starts a backlog run or a single-spec run
  from a form, landing the operator on Mission Control with a toast
  confirmation (`specs/008-control-plane/tasks.md` T035-T039). 019: every run
  is a stacked sequential run — there is no toggle, the form only describes
  the shape.

  Reads `Backlog.load!/1` directly for the backlog preview (`contracts/routes.md`)
  and `Autonomous.preview_single_spec/2` for the single-spec live
  preview — both read-only, no pipeline logic reimplemented (Constitution I).
  Start dispatches to `Autonomous.run/1` / `run_spec/2` unchanged.

  Test seam: `Application.get_env(:autonomous, :console_test_runner)`,
  when set, is injected as the `:runner` opt on Start so LiveView tests never
  touch a real worktree/CLI (mirrors the facade's own `:runner`/`:executor`
  seams — see quickstart.md).
  """

  use Autonomous.Web, :live_view

  # Bounded wait on the run controller (feature 038); past it the action reports
  # "unreachable" instead of crashing the view.
  @run_wait_ms 5_000

  alias Autonomous.{
    Backlog,
    Config,
    ConsoleProjection,
    ContainerGuard,
    Coordinator,
    InteractiveClarify,
    Remediation,
    RuntimeNotice,
    Severity
  }

  alias Autonomous.Web.StartConfirm

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Autonomous.PubSub, ConsoleProjection.topic())
    end

    packages = list_packages()

    {:ok,
     socket
     |> assign(
       page_title: "Trigger Run",
       current_path: "/trigger",
       mode: :backlog,
       auto_remediation?: Config.auto_remediation?(),
       remediation_threshold: to_string(Config.auto_remediation_threshold()),
       remediation_limit: to_string(Config.auto_remediation_attempt_limit()),
       remediation_exhaustion_policy: to_string(Config.auto_remediation_exhaustion_policy()),
       remediation_error: nil,
       interactive_clarify?: Config.interactive_clarify?(),
       clarify_timeout_min: to_string(div(Config.clarify_answer_timeout_s(), 60)),
       clarify_rounds: to_string(Config.clarify_max_rounds()),
       clarify_error: nil,
       container_notice: RuntimeNotice.container_warning(ContainerGuard.containerized?()),
       active_run_id: active_run_id(),
       confirm: %{backlog: :idle, single_spec: :idle},
       description: "",
       preview: nil,
       field_error: nil,
       start_error: nil,
       packages: packages,
       selected_package: List.first(packages),
       expected_breakdown_dir: Path.join([Config.repo(), Config.specs_root(), "breakdown"])
     )
     |> refresh_backlog_preview()}
  end

  # ---- in-flight run awareness (033, research R10) ---------------------------

  @impl true
  def handle_info({:console, _kind, _payload}, socket), do: {:noreply, sync_active_run(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  # The run a fresh start would drain and supersede, or `nil`. A finished
  # Coordinator is not live; a registered worker keeps a run active even with
  # no Coordinator (026).
  defp active_run_id do
    if live_coordinator?() or Autonomous.workers() != [], do: Autonomous.current_run_id()
  end

  defp live_coordinator? do
    case Autonomous.CoordinatorProbe.status(Coordinator, 250) do
      {:ok, status} -> not status.finished?
      _none_or_error -> false
    end
  end

  defp sync_active_run(socket) do
    run_id = active_run_id()

    confirm =
      Map.new(socket.assigns.confirm, fn {action, state} ->
        {action, state |> StartConfirm.next({:active_run, run_id}, run_id) |> elem(0)}
      end)

    assign(socket, active_run_id: run_id, confirm: confirm)
  end

  # One click on a start action. The active run is re-read here, server-side,
  # so a stale client can never skip the arm step. `:dispatch` means start now.
  defp confirm_click(socket, action) do
    run_id = active_run_id()
    {state, effect} = StartConfirm.next(socket.assigns.confirm[action], :click, run_id)

    {effect,
     assign(socket,
       active_run_id: run_id,
       confirm: Map.put(socket.assigns.confirm, action, state)
     )}
  end

  defp reset_confirm(socket), do: assign(socket, confirm: %{backlog: :idle, single_spec: :idle})

  # ---- breakdown package selection (FR-012, 012) -----------------------------

  defp list_packages do
    dir = Path.join([Config.repo(), Config.specs_root(), "breakdown"])

    case File.ls(dir) do
      {:ok, names} -> names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  # ---- mode toggle ----------------------------------------------------------

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    mode_atom = if mode == "single_spec", do: :single_spec, else: :backlog

    socket =
      socket
      |> assign(mode: mode_atom, start_error: nil, field_error: nil)
      |> reset_confirm()

    socket = if mode_atom == :backlog, do: refresh_backlog_preview(socket), else: socket
    {:noreply, socket}
  end

  # ---- auto-remediation controls (017, contracts/telemetry-console.md §4) ----

  def handle_event("toggle_auto_remediation", _params, socket) do
    {:noreply,
     assign(socket,
       auto_remediation?: not socket.assigns.auto_remediation?,
       remediation_error: nil
     )}
  end

  def handle_event("update_remediation", params, socket) do
    {:noreply,
     assign(socket,
       remediation_threshold: Map.get(params, "threshold", socket.assigns.remediation_threshold),
       remediation_limit: Map.get(params, "attempt_limit", socket.assigns.remediation_limit),
       remediation_exhaustion_policy:
         Map.get(params, "exhaustion_policy", socket.assigns.remediation_exhaustion_policy),
       remediation_error: nil
     )}
  end

  # ---- interactive clarify controls (029, contracts/operator-surfaces.md Trigger form) ----

  def handle_event("toggle_interactive_clarify", _params, socket) do
    {:noreply,
     assign(socket,
       interactive_clarify?: not socket.assigns.interactive_clarify?,
       clarify_error: nil
     )}
  end

  def handle_event("update_clarify", params, socket) do
    {:noreply,
     assign(socket,
       clarify_timeout_min:
         Map.get(params, "answer_timeout_min", socket.assigns.clarify_timeout_min),
       clarify_rounds: Map.get(params, "max_rounds", socket.assigns.clarify_rounds),
       clarify_error: nil
     )}
  end

  def handle_event("cancel_start", %{"action" => action}, socket) do
    case action do
      "backlog" -> {:noreply, cancel_confirm(socket, :backlog)}
      "single_spec" -> {:noreply, cancel_confirm(socket, :single_spec)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("select_package", %{"slug" => slug}, socket) do
    {:noreply, socket |> assign(selected_package: slug) |> refresh_backlog_preview()}
  end

  # ---- single-spec live preview ---------------------------------------------

  def handle_event("update_description", %{"description" => description}, socket) do
    preview = Autonomous.preview_single_spec(description)

    {:noreply, assign(socket, description: description, preview: preview, field_error: nil)}
  end

  # ---- start ------------------------------------------------------------

  def handle_event("start_backlog", _params, socket) do
    if socket.assigns.backlog_preview.dag_valid? do
      case confirm_click(socket, :backlog) do
        {:dispatch, socket} -> start_backlog(socket)
        {:none, socket} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_single_spec", %{"description" => description}, socket) do
    socket = assign(socket, description: description)

    if blank?(description) do
      {:noreply, assign(socket, field_error: "Description is required")}
    else
      case confirm_click(socket, :single_spec) do
        {:dispatch, socket} -> start_single_spec(socket, description)
        {:none, socket} -> {:noreply, socket}
      end
    end
  end

  defp cancel_confirm(socket, action) do
    {state, _effect} =
      StartConfirm.next(socket.assigns.confirm[action], :cancel, socket.assigns.active_run_id)

    assign(socket, confirm: Map.put(socket.assigns.confirm, action, state))
  end

  defp start_backlog(socket) do
    case start_opts(socket) do
      {:ok, opts} ->
        case run_unlinked(fn -> Autonomous.run(opts) end) do
          {:ok, _pid} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Backlog run started: Autonomous.run/1 #{inspect(opts)}"
             )
             |> push_navigate(to: "/")}

          {:error, reason} ->
            {:noreply, assign(socket, start_error: format_start_error(reason))}
        end

      {:error, {:remediation, error}} ->
        {:noreply, assign(socket, remediation_error: error)}

      {:error, {:interactive_clarify, error}} ->
        {:noreply, assign(socket, clarify_error: error)}
    end
  end

  defp start_single_spec(socket, description) do
    case start_opts(socket) do
      {:ok, opts} ->
        case run_unlinked(fn -> Autonomous.run_spec(description, opts) end) do
          {:ok, _pid} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Feature started: Autonomous.run_spec/2 #{feature_ref(socket)}"
             )
             |> push_navigate(to: "/")}

          {:error, :empty_description} ->
            {:noreply, assign(socket, field_error: "Description is required")}

          {:error, reason} ->
            {:noreply, assign(socket, start_error: format_start_error(reason))}
        end

      {:error, {:remediation, error}} ->
        {:noreply, assign(socket, remediation_error: error)}

      {:error, {:interactive_clarify, error}} ->
        {:noreply, assign(socket, clarify_error: error)}
    end
  end

  defp blank?(description), do: String.trim(description || "") == ""

  # Echoes the actual assigned id/slug (FR-011) rather than a generic
  # "started" message, matching whatever `update_description`'s live preview
  # already computed.
  defp feature_ref(socket) do
    case socket.assigns[:preview] do
      {id, slug} -> "#{id}-#{slug}"
      _ -> ""
    end
  end

  # `run/1`/`run_spec/2` start the per-run Coordinator via `GenServer.start_link`,
  # which links it to whichever process calls it. Calling them directly from
  # this LiveView would link the Coordinator to TriggerLive's process — and
  # `push_navigate` right after tears that process down, killing the linked
  # Coordinator with it. Running the call in an unlinked task (still under the
  # app's Task.Supervisor) decouples the Coordinator's lifetime from this
  # transient view.
  defp run_unlinked(fun) do
    task = Task.Supervisor.async_nolink(Autonomous.RunnerSup, fun)

    case Task.yield(task, Application.get_env(:autonomous, :console_run_wait_ms, @run_wait_ms)) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:controller_unreachable, reason}}

      nil ->
        # Left running; `ignore/1` drops its late reply so it can't reach this view.
        Task.ignore(task)
        {:error, :controller_unreachable}
    end
  end

  # 019: the run shape is no longer an opt — every run is stacked sequential,
  # so there is nothing to pass here for it. The auto-remediation controls
  # (017) remain per-run opts: validated here through
  # `Remediation.Settings.validate/1` — the same single validator `run/1`'s
  # own preflight uses — so a bad limit/threshold is refused *before* any run
  # is dispatched (FR-010e), and the accepted values travel as opts only,
  # leaving the node's configured defaults untouched for the next mount
  # (FR-010f).
  defp start_opts(socket) do
    with {:ok, settings} <- tag_error(validate_remediation(socket), :remediation),
         {:ok, clarify} <- tag_error(validate_interactive_clarify(socket), :interactive_clarify) do
      base = [
        auto_remediation: settings.enabled?,
        auto_remediation_threshold: settings.threshold,
        auto_remediation_attempt_limit: settings.attempt_limit,
        auto_remediation_exhaustion_policy: settings.exhaustion_policy,
        interactive_clarify: clarify.enabled?,
        clarify_answer_timeout_s: clarify.answer_timeout_s,
        clarify_max_rounds: clarify.max_rounds
      ]

      base = maybe_put_slug(base, socket.assigns[:selected_package])

      case Application.get_env(:autonomous, :console_test_runner) do
        nil -> {:ok, base}
        runner -> {:ok, Keyword.put(base, :runner, runner)}
      end
    end
  end

  defp tag_error({:ok, _} = ok, _tag), do: ok
  defp tag_error({:error, error}, tag), do: {:error, {tag, error}}

  defp validate_remediation(socket) do
    input = %{
      enabled?: socket.assigns.auto_remediation?,
      threshold: socket.assigns.remediation_threshold,
      attempt_limit: parse_limit(socket.assigns.remediation_limit),
      model: Config.auto_remediation_model(),
      exhaustion_policy: socket.assigns.remediation_exhaustion_policy
    }

    case Remediation.Settings.validate(input) do
      {:ok, settings} ->
        {:ok, settings}

      {:error, {:invalid_threshold, value}} ->
        {:error, {"auto-remediation-threshold", "Unrecognized severity threshold: #{value}"}}

      {:error, {:invalid_attempt_limit, value}} ->
        {:error,
         {"auto-remediation-limit", "Attempt limit must be a whole number 1–5, got: #{value}"}}

      {:error, {:unknown_model, value}} ->
        {:error, {"auto-remediation-model", "Unknown model: #{inspect(value)}"}}

      {:error, {:invalid_exhaustion_policy, value}} ->
        {:error,
         {"auto-remediation-exhaustion-policy", "Unrecognized exhaustion policy: #{value}"}}
    end
  end

  # 029: `answer_timeout_min` is entered in minutes (1..1440) and converted to
  # `InteractiveClarify.Settings`' seconds (60..86_400) before validation —
  # the same range, just a friendlier unit for an operator typing it in.
  defp validate_interactive_clarify(socket) do
    input = %{
      enabled?: socket.assigns.interactive_clarify?,
      answer_timeout_s: parse_clarify_timeout_min(socket.assigns.clarify_timeout_min),
      max_rounds: parse_limit(socket.assigns.clarify_rounds)
    }

    case InteractiveClarify.Settings.validate(input) do
      {:ok, settings} ->
        {:ok, settings}

      {:error, {:invalid_answer_timeout, value}} ->
        {:error,
         {"clarify-timeout", "Answer timeout must be minutes 1–1440, got: #{inspect(value)}"}}

      {:error, {:invalid_max_rounds, value}} ->
        {:error, {"clarify-rounds", "Round limit must be a whole number 1–5, got: #{value}"}}
    end
  end

  defp parse_clarify_timeout_min(value) when is_binary(value) do
    case Integer.parse(value) do
      {min, ""} -> min * 60
      _ -> value
    end
  end

  defp parse_clarify_timeout_min(value), do: value

  # A number input still delivers a string, and a non-numeric one must reach
  # the validator as-is so it rejects rather than being silently defaulted.
  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {limit, ""} -> limit
      _ -> value
    end
  end

  defp parse_limit(value), do: value

  defp maybe_put_slug(opts, nil), do: opts
  defp maybe_put_slug(opts, slug), do: Keyword.put(opts, :slug, slug)

  defp format_start_error({:preflight, problems}),
    do: "Preflight failed: " <> Enum.map_join(problems, "; ", &Autonomous.Report.format_reason/1)

  # 026: a fresh run's own drain-before-supersede timed out — distinct
  # wording from a preflight failure (FR-011); nothing
  # was started, so retrying (once the worker is confirmed stuck) is safe.
  defp format_start_error({:drain_timeout, stuck}) do
    "Still working, nothing started: #{drain_stuck_features(stuck)} — " <>
      "retry once you're sure it's stuck"
  end

  defp format_start_error(reason), do: "Failed to start: #{inspect(reason)}"

  defp drain_stuck_features(stuck), do: Enum.map_join(stuck, ", ", & &1.feature_id)

  # ---- backlog preview --------------------------------------------------

  defp refresh_backlog_preview(socket) do
    assign(socket, backlog_preview: backlog_preview(socket.assigns[:selected_package]))
  end

  # A selected package (FR-012, 012) previews its own per-package dir. No
  # packages found falls back to the flat Config.breakdown_dir/0 preview (an
  # old-layout/pre-012 repo, still supported); the render also shows a
  # `data-hint="no-packages"` empty-state naming the standard
  # `specs/autonomous/breakdown` location so a misconfigured repo isn't left
  # staring at the legacy `docs/breakdown` path.
  defp backlog_preview(nil),
    do: backlog_preview_at(Path.join(Config.repo(), Config.breakdown_dir()))

  defp backlog_preview(slug) do
    backlog_preview_at(Path.join([Config.repo(), Config.specs_root(), "breakdown", slug]))
  end

  defp backlog_preview_at(source) do
    try do
      features = Backlog.load!(source)
      %{source: source, count: length(features), dag_valid?: true, reason: nil}
    rescue
      e ->
        %{source: source, count: 0, dag_valid?: false, reason: Exception.message(e)}
    end
  end

  # The source path relative to the served repository, so its root is never
  # hidden behind a leading ellipsis (033, FR-032); the dd's `title` carries the
  # full path. A path outside the repository is shown whole.
  defp relative_source(path) when is_binary(path), do: Path.relative_to(path, Config.repo())
  defp relative_source(path), do: path

  # ---- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-trigger" data-view="trigger">
      <div class="mode-toggle">
        <button
          type="button"
          phx-click="set_mode"
          phx-value-mode="backlog"
          data-mode-button="backlog"
          class={if @mode == :backlog, do: "mode-active"}
        >
          Backlog run
        </button>
        <button
          type="button"
          phx-click="set_mode"
          phx-value-mode="single_spec"
          data-mode-button="single-spec"
          class={if @mode == :single_spec, do: "mode-active"}
        >
          Single-spec (free text)
        </button>
      </div>

      <.form_refusal :if={@start_error} label="Start refused" data-error="start">
        {@start_error}
      </.form_refusal>

      <div :if={@mode == :backlog} class="trigger-backlog form-panel" data-mode-panel="backlog">
        <p :if={@packages == []} class="backlog-empty" data-hint="no-packages">
          No breakdown packages found. The standardized layout expects them under
          <code>{@expected_breakdown_dir}/&lt;slug&gt;/</code>
          (files named <code>NNN-*.md</code>).
        </p>

        <dl class="backlog-preview">
          <dt :if={@packages != []}>Breakdown package</dt>
          <dd :if={@packages != []}>
            <form id="package-picker-form" phx-change="select_package" data-form="package-picker">
              <select name="slug" class="console-input" data-package-select>
                <option
                  :for={slug <- @packages}
                  value={slug}
                  selected={slug == @selected_package}
                >
                  {slug}
                </option>
              </select>
            </form>
          </dd>
          <dt>Source</dt>
          <dd class="preview-path" title={@backlog_preview.source}>
            {relative_source(@backlog_preview.source)}
          </dd>
          <dt>Feature count</dt>
          <dd>{@backlog_preview.count}</dd>
          <dt>DAG validated</dt>
          <dd data-dag-valid={to_string(@backlog_preview.dag_valid?)}>
            {if @backlog_preview.dag_valid?, do: "yes", else: "no"}
          </dd>
          <dt>Run shape</dt>
          <dd>stacked sequential — one feature at a time</dd>
        </dl>

        <.form_refusal :if={not @backlog_preview.dag_valid?} label="Backlog invalid" data-error="dag">
          {@backlog_preview.reason}
        </.form_refusal>
      </div>

      <div
        :if={@mode == :single_spec}
        class="trigger-single-spec form-panel"
        data-mode-panel="single-spec"
      >
        <form
          id="single-spec-form"
          phx-change="update_description"
          phx-submit="start_single_spec"
        >
          <label class="field-label">
            Feature description (free text)
            <textarea
              name="description"
              phx-debounce="200"
              placeholder="Add a health-check endpoint that returns service status and version."
            >{@description}</textarea>
          </label>

          <.form_refusal :if={@field_error} label="Description required" data-error="description">
            {@field_error}
          </.form_refusal>

          <div :if={@preview} class="single-spec-preview" data-preview="id-slug">
            <span>ID: {elem(@preview, 0)}</span>
            <span>Slug: {elem(@preview, 1)}</span>
          </div>
        </form>
      </div>

      <div class="pr-toggle-row" data-run-shape="stacked-sequential">
        <span>Stacked sequential PR workflow — every run branches one feature at a
          time from the previous completed feature's branch and opens a PR
          against it.</span>
      </div>

      <fieldset class="option-group" data-option-group="auto_remediation">
        <legend class="sr-only">auto_remediation</legend>
        <div class="config-toggle-title">Analyze auto-remediation</div>

        <div class="option-row">
          <label class="pr-toggle">
            <input
              type="checkbox"
              phx-click="toggle_auto_remediation"
              checked={@auto_remediation?}
              class="switch-input"
            />
            <span class="switch-track"><span class="switch-knob"></span></span>
            <span class="option-name">auto_remediation</span>
          </label>
          <span class="pr-hint" data-auto-remediation={to_string(@auto_remediation?)}>
            {if @auto_remediation?, do: "on", else: "off"}
          </span>
        </div>

        <form
          id="auto-remediation-form"
          phx-change="update_remediation"
          class={["option-fields", not @auto_remediation? && "controls-disabled"]}
        >
          <label class="option-row field-label-inline">
            <span class="option-name">auto_remediation_threshold</span>
            <select
              name="threshold"
              class="console-input"
              data-remediation-threshold
              disabled={not @auto_remediation?}
            >
              <option
                :for={severity <- Severity.values()}
                value={severity}
                selected={to_string(severity) == @remediation_threshold}
              >
                {severity}
              </option>
            </select>
          </label>

          <label class="option-row field-label-inline">
            <span class="option-name">auto_remediation_attempt_limit</span>
            <input
              type="number"
              name="attempt_limit"
              class="console-input"
              min="1"
              max="5"
              value={@remediation_limit}
              data-remediation-limit
              disabled={not @auto_remediation?}
            />
          </label>

          <label class="option-row field-label-inline">
            <span class="option-name">auto_remediation_exhaustion_policy</span>
            <select
              name="exhaustion_policy"
              class="console-input"
              data-exhaustion-policy
              disabled={not @auto_remediation?}
            >
              <option
                value="escalate"
                selected={@remediation_exhaustion_policy == "escalate"}
              >
                escalate
              </option>
              <option
                value="proceed"
                selected={@remediation_exhaustion_policy == "proceed"}
              >
                proceed
              </option>
            </select>
          </label>
        </form>
      </fieldset>

      <.form_refusal
        :if={@remediation_error}
        label={"Refused: " <> elem(@remediation_error, 0)}
        data-error={elem(@remediation_error, 0)}
      >
        {elem(@remediation_error, 1)}
      </.form_refusal>

      <fieldset class="option-group" data-option-group="interactive_clarify">
        <legend class="sr-only">interactive_clarify</legend>
        <div class="config-toggle-title">Interactive clarify</div>

        <div class="option-row">
          <label class="pr-toggle">
            <input
              type="checkbox"
              phx-click="toggle_interactive_clarify"
              checked={@interactive_clarify?}
              class="switch-input"
            />
            <span class="switch-track"><span class="switch-knob"></span></span>
            <span class="option-name">interactive_clarify</span>
          </label>
          <span class="pr-hint" data-interactive-clarify={to_string(@interactive_clarify?)}>
            {if @interactive_clarify?, do: "on", else: "off"}
          </span>
        </div>

        <form
          :if={@interactive_clarify?}
          id="interactive-clarify-form"
          phx-change="update_clarify"
          class="option-fields"
        >
          <label class="option-row field-label-inline">
            <span class="option-name">answer_timeout_min</span>
            <input
              type="number"
              name="answer_timeout_min"
              class="console-input"
              min="1"
              max="1440"
              value={@clarify_timeout_min}
              data-clarify-timeout
            />
          </label>

          <label class="option-row field-label-inline">
            <span class="option-name">max_rounds</span>
            <input
              type="number"
              name="max_rounds"
              class="console-input"
              min="1"
              max="5"
              value={@clarify_rounds}
              data-clarify-rounds
            />
          </label>
        </form>
      </fieldset>

      <.form_refusal
        :if={@clarify_error}
        label={"Refused: " <> elem(@clarify_error, 0)}
        data-error={elem(@clarify_error, 0)}
      >
        {elem(@clarify_error, 1)}
      </.form_refusal>

      <p :if={@container_notice} class="pr-hint" data-container-notice>
        {@container_notice}
      </p>

      <.start_controls
        :if={@mode == :backlog}
        action="backlog"
        state={@confirm.backlog}
        data_action="start-backlog"
        type="button"
        click="start_backlog"
        disabled={not @backlog_preview.dag_valid?}
      />

      <.start_controls
        :if={@mode == :single_spec}
        action="single_spec"
        state={@confirm.single_spec}
        data_action="start-single-spec"
        type="submit"
        form="single-spec-form"
      />
    </div>
    """
  end

  # The start button and its inline two-step confirmation (033, FR-010). Armed
  # state names the run that will be drained and superseded; Cancel disarms.
  attr(:action, :string, required: true)
  attr(:state, :any, required: true)
  attr(:data_action, :string, required: true)
  attr(:type, :string, required: true)
  attr(:click, :string, default: nil)
  attr(:form, :string, default: nil)
  attr(:disabled, :boolean, default: false)

  defp start_controls(assigns) do
    assigns = assign(assigns, armed: armed_run(assigns.state))

    ~H"""
    <div class="start-controls" data-start-controls={@action}>
      <button
        type={@type}
        form={@form}
        phx-click={@click}
        class="btn-primary"
        data-action={@data_action}
        data-confirm-armed={@armed != nil}
        disabled={@disabled}
      >
        {if @armed, do: "Supersede #{@armed} and start", else: "Start run"}
      </button>
      <span :if={@armed} class="start-hint" data-start-hint>drains and supersedes {@armed}</span>
      <button
        :if={@armed}
        type="button"
        phx-click="cancel_start"
        phx-value-action={@action}
        class="btn-secondary"
        data-action={"cancel-start-#{@action}"}
      >
        Cancel
      </button>
    </div>
    """
  end

  defp armed_run({:armed, run_id}), do: run_id
  defp armed_run(_state), do: nil
end
