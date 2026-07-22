defmodule SpeckitOrchestrator.Web.TriggerLive do
  @moduledoc """
  US2 — Trigger Run (`/trigger`): starts a backlog run or a single-spec run
  from a form, with DAG validation and a stacked-PR toggle, landing the
  operator on Mission Control with a toast confirmation
  (`specs/008-control-plane/tasks.md` T035-T039).

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

  alias SpeckitOrchestrator.{Backlog, Config}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Trigger Run",
       current_path: "/trigger",
       mode: :backlog,
       pr_workflow?: Config.pr_workflow?(),
       description: "",
       preview: nil,
       field_error: nil,
       start_error: nil
     )
     |> refresh_backlog_preview()}
  end

  # ---- mode toggle ----------------------------------------------------------

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    mode_atom = if mode == "single_spec", do: :single_spec, else: :backlog
    socket = assign(socket, mode: mode_atom, start_error: nil, field_error: nil)
    socket = if mode_atom == :backlog, do: refresh_backlog_preview(socket), else: socket
    {:noreply, socket}
  end

  def handle_event("toggle_pr_workflow", _params, socket) do
    {:noreply, assign(socket, pr_workflow?: not socket.assigns.pr_workflow?)}
  end

  # ---- single-spec live preview ---------------------------------------------

  def handle_event("update_description", %{"description" => description}, socket) do
    preview = SpeckitOrchestrator.preview_single_spec(description)

    {:noreply, assign(socket, description: description, preview: preview, field_error: nil)}
  end

  # ---- start ------------------------------------------------------------

  def handle_event("start_backlog", _params, socket) do
    if socket.assigns.backlog_preview.dag_valid? do
      opts = start_opts(socket)

      case run_unlinked(fn -> SpeckitOrchestrator.run(opts) end) do
        {:ok, _pid} ->
          {:noreply,
           socket
           |> put_flash(:info, "Backlog run started")
           |> push_navigate(to: "/")}

        {:error, reason} ->
          {:noreply, assign(socket, start_error: format_start_error(reason))}
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
      opts = start_opts(socket)

      case run_unlinked(fn -> SpeckitOrchestrator.run_spec(description, opts) end) do
        {:ok, _pid} ->
          {:noreply,
           socket
           |> put_flash(:info, "Feature started")
           |> push_navigate(to: "/")}

        {:error, :empty_description} ->
          {:noreply, assign(socket, field_error: "Description is required")}

        {:error, reason} ->
          {:noreply, assign(socket, start_error: format_start_error(reason))}
      end
    end
  end

  defp blank?(description), do: String.trim(description || "") == ""

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

  # Mirrors the toggle into app env so the shared status bar (`Layouts.run_view/0`,
  # which reads `Config.pr_workflow?/0` live) reflects the just-started run's
  # mode — the toggle is otherwise a per-run opt, not a persisted default.
  defp start_opts(socket) do
    Application.put_env(:speckit_orchestrator, :pr_workflow, socket.assigns.pr_workflow?)
    base = [pr_workflow: socket.assigns.pr_workflow?]

    case Application.get_env(:speckit_orchestrator, :console_test_runner) do
      nil -> base
      runner -> Keyword.put(base, :runner, runner)
    end
  end

  defp format_start_error({:preflight, problems}), do: "Preflight failed: #{inspect(problems)}"
  defp format_start_error(reason), do: "Failed to start: #{inspect(reason)}"

  # ---- backlog preview --------------------------------------------------

  defp refresh_backlog_preview(socket) do
    assign(socket, backlog_preview: backlog_preview())
  end

  defp backlog_preview do
    source = Path.join(Config.repo(), Config.breakdown_dir())

    try do
      features = Backlog.load!(source)
      %{source: source, count: length(features), dag_valid?: true, reason: nil}
    rescue
      e ->
        %{source: source, count: 0, dag_valid?: false, reason: Exception.message(e)}
    end
  end

  defp effective_concurrency(true, _max_concurrency), do: 1
  defp effective_concurrency(false, max_concurrency), do: max_concurrency

  # ---- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :effective_concurrency,
        effective_concurrency(assigns.pr_workflow?, Config.max_concurrency())
      )

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

      <p :if={@start_error} class="field-error" data-error="start">{@start_error}</p>

      <div :if={@mode == :backlog} class="trigger-backlog form-panel" data-mode-panel="backlog">
        <dl class="backlog-preview">
          <dt>Source</dt>
          <dd>{@backlog_preview.source}</dd>
          <dt>Feature count</dt>
          <dd>{@backlog_preview.count}</dd>
          <dt>DAG validated?</dt>
          <dd data-dag-valid={to_string(@backlog_preview.dag_valid?)}>
            {if @backlog_preview.dag_valid?, do: "yes", else: "no"}
          </dd>
          <dt>Max concurrency</dt>
          <dd>{@effective_concurrency}</dd>
          <dt>Budget</dt>
          <dd>${format_money(Config.budget_usd())}</dd>
        </dl>

        <p :if={not @backlog_preview.dag_valid?} class="field-error" data-error="dag">
          {@backlog_preview.reason}
        </p>
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

          <p :if={@field_error} class="field-error" data-error="description">{@field_error}</p>

          <div :if={@preview} class="single-spec-preview" data-preview="id-slug">
            <span>ID: {elem(@preview, 0)}</span>
            <span>Slug: {elem(@preview, 1)}</span>
          </div>
        </form>
      </div>

      <div class="pr-toggle-row">
        <label class="pr-toggle">
          <input
            type="checkbox"
            phx-click="toggle_pr_workflow"
            checked={@pr_workflow?}
            class="switch-input"
          />
          <span class="switch-track"><span class="switch-knob"></span></span>
          <span>Stacked sequential PR workflow</span>
        </label>
        <span class="pr-hint" data-pr-workflow={to_string(@pr_workflow?)}>
          effective concurrency: {@effective_concurrency}
        </span>
      </div>

      <button
        :if={@mode == :backlog}
        type="button"
        phx-click="start_backlog"
        class="btn-primary"
        data-action="start-backlog"
        disabled={not @backlog_preview.dag_valid?}
      >
        &#9656; &nbsp;Start run
      </button>

      <button
        :if={@mode == :single_spec}
        type="submit"
        form="single-spec-form"
        class="btn-primary"
        data-action="start-single-spec"
      >
        &#9656; &nbsp;Start run
      </button>
    </div>
    """
  end
end
