defmodule SpeckitOrchestrator.Web.TriggerLive do
  @moduledoc """
  US2 — Trigger Run (`/trigger`): starts a backlog run or a single-spec run
  from a form, landing the operator on Mission Control with a toast
  confirmation (`specs/008-control-plane/tasks.md` T035-T039). 019: every run
  is a stacked sequential run — there is no toggle, the form only describes
  the shape.

  Reads `Backlog.load!/1` directly for the backlog preview (`contracts/routes.md`)
  and `SpeckitOrchestrator.preview_single_spec/2` for the single-spec live
  preview — both read-only, no pipeline logic reimplemented (Constitution I).
  Start dispatches to `SpeckitOrchestrator.run/1` / `run_spec/2` unchanged.

  Test seam: `Application.get_env(:speckit_orchestrator, :console_test_runner)`,
  when set, is injected as the `:runner` opt on Start so LiveView tests never
  touch a real worktree/CLI (mirrors the facade's own `:runner`/`:executor`
  seams — see quickstart.md).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{Backlog, Config, Remediation, Severity}

  @impl true
  def mount(_params, _session, socket) do
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
       remediation_error: nil,
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
    socket = assign(socket, mode: mode_atom, start_error: nil, field_error: nil)
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
       remediation_error: nil
     )}
  end

  def handle_event("select_package", %{"slug" => slug}, socket) do
    {:noreply, socket |> assign(selected_package: slug) |> refresh_backlog_preview()}
  end

  # ---- single-spec live preview ---------------------------------------------

  def handle_event("update_description", %{"description" => description}, socket) do
    preview = SpeckitOrchestrator.preview_single_spec(description)

    {:noreply, assign(socket, description: description, preview: preview, field_error: nil)}
  end

  # ---- start ------------------------------------------------------------

  def handle_event("start_backlog", _params, socket) do
    if socket.assigns.backlog_preview.dag_valid? do
      case start_opts(socket) do
        {:ok, opts} ->
          case run_unlinked(fn -> SpeckitOrchestrator.run(opts) end) do
            {:ok, _pid} ->
              {:noreply,
               socket
               |> put_flash(
                 :info,
                 "Backlog run started: SpeckitOrchestrator.run/1 #{inspect(opts)}"
               )
               |> push_navigate(to: "/")}

            {:error, reason} ->
              {:noreply, assign(socket, start_error: format_start_error(reason))}
          end

        {:error, remediation_error} ->
          {:noreply, assign(socket, remediation_error: remediation_error)}
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
      case start_opts(socket) do
        {:ok, opts} ->
          case run_unlinked(fn -> SpeckitOrchestrator.run_spec(description, opts) end) do
            {:ok, _pid} ->
              {:noreply,
               socket
               |> put_flash(
                 :info,
                 "Feature started: SpeckitOrchestrator.run_spec/2 #{feature_ref(socket)}"
               )
               |> push_navigate(to: "/")}

            {:error, :empty_description} ->
              {:noreply, assign(socket, field_error: "Description is required")}

            {:error, reason} ->
              {:noreply, assign(socket, start_error: format_start_error(reason))}
          end

        {:error, remediation_error} ->
          {:noreply, assign(socket, remediation_error: remediation_error)}
      end
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
    SpeckitOrchestrator.RunnerSup
    |> Task.Supervisor.async_nolink(fun)
    |> Task.await()
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
    with {:ok, settings} <- validate_remediation(socket) do
      base = [
        auto_remediation: settings.enabled?,
        auto_remediation_threshold: settings.threshold,
        auto_remediation_attempt_limit: settings.attempt_limit
      ]

      base = maybe_put_slug(base, socket.assigns[:selected_package])

      case Application.get_env(:speckit_orchestrator, :console_test_runner) do
        nil -> {:ok, base}
        runner -> {:ok, Keyword.put(base, :runner, runner)}
      end
    end
  end

  defp validate_remediation(socket) do
    input = %{
      enabled?: socket.assigns.auto_remediation?,
      threshold: socket.assigns.remediation_threshold,
      attempt_limit: parse_limit(socket.assigns.remediation_limit),
      model: Config.auto_remediation_model()
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
    end
  end

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

  defp format_start_error({:preflight, problems}), do: "Preflight failed: #{inspect(problems)}"
  defp format_start_error(reason), do: "Failed to start: #{inspect(reason)}"

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

  # Show the meaningful tail of the source path, anchored at the `autonomous`
  # namespace segment (…/autonomous/breakdown/<slug>) on one line; the full path
  # is exposed via the dd's `title` tooltip on hover. Paths with no `autonomous`
  # segment (legacy docs/breakdown fallback) fall back to a last-N-chars window.
  @path_display_max 40
  defp truncate_path(path) when is_binary(path) do
    case String.split(path, "/autonomous/", parts: 2) do
      [_prefix, rest] ->
        "…/autonomous/" <> rest

      [_] when byte_size(path) > @path_display_max ->
        "…" <> String.slice(path, -@path_display_max, @path_display_max)

      [_] ->
        path
    end
  end

  defp truncate_path(path), do: path

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
              <select name="slug" data-package-select>
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
            {truncate_path(@backlog_preview.source)}
          </dd>
          <dt>Feature count</dt>
          <dd>{@backlog_preview.count}</dd>
          <dt>DAG validated?</dt>
          <dd data-dag-valid={to_string(@backlog_preview.dag_valid?)}>
            {if @backlog_preview.dag_valid?, do: "yes", else: "no"}
          </dd>
          <dt>Run shape</dt>
          <dd>stacked sequential — one feature at a time</dd>
          <dt>Budget</dt>
          <dd>${format_money(Config.budget_usd())}</dd>
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

      <div class="pr-toggle-row auto-remediation-row">
        <label class="pr-toggle">
          <input
            type="checkbox"
            phx-click="toggle_auto_remediation"
            checked={@auto_remediation?}
            class="switch-input"
          />
          <span class="switch-track"><span class="switch-knob"></span></span>
          <span>Analyze auto-remediation</span>
        </label>
        <span class="pr-hint" data-auto-remediation={to_string(@auto_remediation?)}>
          {if @auto_remediation?, do: "on", else: "off"}
        </span>

        <form
          id="auto-remediation-form"
          phx-change="update_remediation"
          class={not @auto_remediation? && "controls-disabled"}
        >
          <label class="field-label-inline">
            Severity threshold
            <select name="threshold" data-remediation-threshold disabled={not @auto_remediation?}>
              <option
                :for={severity <- Severity.values()}
                value={severity}
                selected={to_string(severity) == @remediation_threshold}
              >
                {severity}
              </option>
            </select>
          </label>

          <label class="field-label-inline">
            Attempt limit
            <input
              type="number"
              name="attempt_limit"
              min="1"
              max="5"
              value={@remediation_limit}
              data-remediation-limit
              disabled={not @auto_remediation?}
            />
          </label>
        </form>
      </div>

      <.form_refusal
        :if={@remediation_error}
        label={"Refused: " <> elem(@remediation_error, 0)}
        data-error={elem(@remediation_error, 0)}
      >
        {elem(@remediation_error, 1)}
      </.form_refusal>

      <button
        :if={@mode == :backlog}
        type="button"
        phx-click="start_backlog"
        class="btn-primary"
        data-action="start-backlog"
        disabled={not @backlog_preview.dag_valid?}
      >
        Start run
      </button>

      <button
        :if={@mode == :single_spec}
        type="submit"
        form="single-spec-form"
        class="btn-primary"
        data-action="start-single-spec"
      >
        Start run
      </button>
    </div>
    """
  end
end
