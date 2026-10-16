defmodule Autonomous.Web.ConfigLive do
  @moduledoc """
  US6 — Configuration (`/config`): per-phase model routing and PR
  base/remote, applying forward-only to the live run
  (`specs/008-control-plane/tasks.md` T068-T070). 019: every run is a
  stacked sequential run — there is no concurrency or PR-workflow toggle
  left to configure. 031: also shows, read-only, the repository this instance
  serves and its node name (real identifiers, not editable settings).

  Renders `Config.*`; submits through
  `LiveConfig.apply/1`. On success it broadcasts a `:reconciled` message on
  `ConsoleProjection.topic()` (the same shape the projection's own reconcile
  tick sends) so the status bar and every other mounted LiveView pick up
  the change immediately rather than waiting up to 2s (FR-030), and toasts the
  change (FR-005).

  033 US5: the form tracks `edited` against `applied` (`ConfigDiff`), shows an
  unsaved count with sticky Apply/Reset, and echoes the actual
  `LiveConfig.apply/1` call on success. 039: no budget — cost is
  informational, so there is nothing to configure.
  """

  use Autonomous.Web, :live_view

  alias Autonomous.Web.{AgentRootView, ConfigDiff, PackView, VolumesView}

  alias Autonomous.{
    AgentRoot,
    AppliedVolumes,
    Config,
    ConsoleProjection,
    LiveConfig,
    Pipeline,
    TargetPack,
    VolumeUsage
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Configuration", current_path: "/config", errors: %{})
     |> refresh()
     |> load_volumes()}
  end

  # 041: the applied volume set is fixed at start, so it is read once per mount;
  # a reload re-measures. Sizes are measured off the render path.
  defp load_volumes(socket) do
    applied = AppliedVolumes.current()

    socket = assign(socket, volumes_applied: applied, volume_usage: %{})

    with true <- connected?(socket), {:ok, volumes, _declaration} <- applied do
      Enum.reduce(volumes, socket, fn volume, acc ->
        start_async(acc, {:volume_usage, volume.name}, fn -> VolumeUsage.measure(volume.path) end)
      end)
    else
      _ -> socket
    end
  end

  @impl true
  def handle_async(:pack_source, {:ok, result}, socket) do
    {:noreply, assign(socket, pack: PackView.state(result))}
  end

  def handle_async(:pack_source, {:exit, _reason}, socket) do
    {:noreply, assign(socket, pack: {:refused, "the pack check crashed — reload to retry"})}
  end

  def handle_async({:volume_usage, name}, {:ok, usage}, socket) do
    {:noreply, update(socket, :volume_usage, &Map.put(&1, name, usage))}
  end

  def handle_async({:volume_usage, name}, {:exit, _reason}, socket) do
    usage = {:unknown, "du failed: measurement crashed"}
    {:noreply, update(socket, :volume_usage, &Map.put(&1, name, usage))}
  end

  # Re-reads the applied configuration; the form starts (and, after a
  # successful apply or Reset, returns) clean — `edited == applied`.
  defp refresh(socket) do
    applied = applied_fields()

    socket
    |> assign(
      applied: applied,
      served_repo: Path.expand(Config.repo()),
      instance_node: Atom.to_string(node()),
      agent_root: AgentRootView.state(AgentRoot.advertised?())
    )
    |> put_edited(applied)
    |> load_pack()
  end

  # 044: the pack source reads the target's committed tree through git, so it is
  # computed off the LiveView process; `:loading` renders `checking…` until then.
  defp load_pack(socket) do
    socket = assign(socket, pack: :loading)

    if connected?(socket) do
      repo = Config.repo()
      start_async(socket, :pack_source, fn -> TargetPack.source(repo) end)
    else
      socket
    end
  end

  defp applied_fields do
    models =
      Map.new(Pipeline.phases(), fn phase -> {"model_#{phase}", Config.model_for(phase)} end)

    Map.merge(models, %{
      "pr_base" => Config.pr_base(),
      "pr_remote" => Config.pr_remote()
    })
  end

  defp put_edited(socket, edited) do
    changes = ConfigDiff.diff(socket.assigns.applied, edited)
    assign(socket, edited: edited, changes: changes, dirty: ConfigDiff.dirty?(changes))
  end

  # ---- edit / reset / apply ---------------------------------------------

  @impl true
  def handle_event("edit", params, socket) do
    {:noreply, put_edited(socket, edited_from(params, socket.assigns.edited))}
  end

  def handle_event("reset", _params, socket) do
    {:noreply, socket |> assign(errors: %{}) |> put_edited(socket.assigns.applied)}
  end

  def handle_event("apply", params, socket) do
    edited = edited_from(params, socket.assigns.edited)
    socket = put_edited(socket, edited)
    changes = socket.assigns.changes

    case LiveConfig.apply(build_change(edited)) do
      {:ok, _change} ->
        broadcast_reconcile()
        lines = ["Configuration applied" | ConfigDiff.apply_echo(changes, active_run_id())]

        {:noreply,
         socket
         |> assign(errors: %{})
         |> put_flash(:info, Enum.join(lines, "\n"))
         |> refresh()}

      {:error, errors} ->
        {:noreply, assign(socket, errors: errors)}
    end
  end

  defp pack_source_name(:loading), do: "loading"
  defp pack_source_name(state), do: PackView.source_name(state)

  defp edited_from(params, prior) do
    Map.new(prior, fn {field, old} -> {field, params[field] || old} end)
  end

  defp build_change(edited) do
    %{
      models: Map.new(Pipeline.phases(), fn phase -> {phase, edited["model_#{phase}"]} end),
      pr_base: edited["pr_base"] || "",
      pr_remote: edited["pr_remote"] || ""
    }
  end

  # Mirrors ConsoleProjection's own :reconcile tick so an applied config
  # change is reflected everywhere within the same render cycle instead of
  # waiting up to the 2s tick (FR-030, SC-005).
  defp broadcast_reconcile do
    Phoenix.PubSub.broadcast(
      Autonomous.PubSub,
      ConsoleProjection.topic(),
      {:console, :reconciled,
       %{
         coordinator: coordinator_status(),
         delayed?: false
       }}
    )
  end

  defp coordinator_status, do: ConsoleProjection.coordinator_or_last_known()

  # Same notion of "a run is in flight" as Trigger Run's confirmation.
  defp active_run_id do
    live? = match?(%{finished?: false}, coordinator_status())
    if live? or Autonomous.workers() != [], do: Autonomous.current_run_id()
  end

  # ---- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-config" data-view="config">
      <form
        id="config-form"
        phx-submit="apply"
        phx-change="edit"
        data-form="config"
        data-dirty={@dirty && "true"}
      >
        <fieldset class="config-models form-panel">
          <legend class="sr-only">Per-phase model routing</legend>
          <div class="config-toggle-title config-section-title">Per-phase model routing</div>
          <div :for={{phase, idx} <- Enum.with_index(Pipeline.phases(), 1)} class="model-row">
            <span class="model-row-index">{pad_ordinal(idx)}</span>
            <span class="model-row-phase">{phase}</span>
            <div class="model-row-options">
              <label
                :for={model <- ["opus", "sonnet"]}
                class={[
                  "model-option",
                  @edited["model_#{phase}"] == model && "model-option-active"
                ]}
              >
                <input
                  type="radio"
                  name={"model_#{phase}"}
                  value={model}
                  checked={@edited["model_#{phase}"] == model}
                  class="model-option-input"
                /> {model}
              </label>
            </div>
          </div>
          <.form_refusal :if={@errors[:models]} label="Models refused" data-error="models">
            {@errors[:models]}
          </.form_refusal>
        </fieldset>

        <fieldset class="config-pr form-panel">
          <legend class="sr-only">PR workflow</legend>
          <div class="config-toggle-row">
            <div>
              <div class="config-toggle-title">Stacked PR workflow</div>
              <div class="config-toggle-sub">
                Every run — one feature at a time, one PR per feature, stacked bottom-up.
              </div>
            </div>
          </div>
          <div class="config-pr-fields">
            <label>
              PR_BASE
              <input type="text" name="pr_base" value={@edited["pr_base"]} class="console-input" />
              <.form_refusal :if={@errors[:pr_base]} label="PR_BASE refused" data-error="pr_base">
                {@errors[:pr_base]}
              </.form_refusal>
            </label>
            <label>
              PR_REMOTE
              <input
                type="text"
                name="pr_remote"
                value={@edited["pr_remote"]}
                class="console-input"
              />
              <.form_refusal
                :if={@errors[:pr_remote]}
                label="PR_REMOTE refused"
                data-error="pr_remote"
              >
                {@errors[:pr_remote]}
              </.form_refusal>
            </label>
          </div>
        </fieldset>

        <fieldset class="config-pr form-panel" data-instance>
          <legend class="sr-only">Instance</legend>
          <.record_block label="instance">
            <dl class="record-block-fields">
              <dt>served repository</dt>
              <dd class="config-instance-id" data-instance-repo>{@served_repo}</dd>
              <dt>instance node</dt>
              <dd class="config-instance-id" data-instance-node>{@instance_node}</dd>
              <dt :if={@agent_root != :hidden}>agent root</dt>
              <dd :if={@agent_root != :hidden} class="config-instance-id" data-agent-root>
                {AgentRootView.summary()}
              </dd>
              <dt>target pack</dt>
              <dd
                class="config-instance-id"
                data-pack-source={pack_source_name(@pack)}
              >
                <.form_refusal :if={match?({:refused, _}, @pack)} label="target pack">
                  {PackView.summary(@pack)}
                </.form_refusal>
                <span :if={@pack == :loading}>checking…</span>
                <span :if={@pack != :loading and not match?({:refused, _}, @pack)}>
                  {PackView.summary(@pack)}
                </span>
              </dd>
            </dl>
          </.record_block>
        </fieldset>

        <.volumes_group state={VolumesView.state(@volumes_applied, @volume_usage)} />

        <div class="config-actionbar" data-actionbar>
          <span :if={@dirty} class="config-unsaved" data-unsaved>{map_size(@changes)} unsaved</span>
          <button
            type="button"
            class="btn-secondary"
            phx-click="reset"
            disabled={not @dirty}
            data-action="reset-config"
          >
            Reset
          </button>
          <button type="submit" class="btn-primary" data-action="apply-config">Apply</button>
        </div>
      </form>
    </div>
    """
  end

  # ---- 041: declared volumes group ----------------------------------------

  attr(:state, :any, required: true)

  defp volumes_group(%{state: :hidden} = assigns), do: ~H""

  defp volumes_group(%{state: {:refused, _reason}} = assigns) do
    ~H"""
    <fieldset class="config-volumes form-panel" data-volumes>
      <legend class="sr-only">Declared volumes</legend>
      <.form_refusal label="AUTONOMOUS_VOLUMES unreadable" data-error="volumes">
        {elem(@state, 1)}
      </.form_refusal>
    </fieldset>
    """
  end

  defp volumes_group(%{state: {:rows, declaration, rows}} = assigns) do
    assigns = assign(assigns, declaration: declaration, rows: rows)

    ~H"""
    <fieldset class="config-volumes form-panel" data-volumes>
      <legend>declared volumes</legend>
      <p class="config-toggle-sub">
        as applied at start — edits to <span class="config-instance-id">volumes.toml</span>
        since then are not shown
      </p>
      <p :if={@declaration} class="config-instance-id" data-volumes-declaration>{@declaration}</p>
      <table class="backlog-table">
        <thead>
          <tr>
            <th>name</th>
            <th>mount path</th>
            <th>variables</th>
            <th>path dirs</th>
            <th>space used</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} data-volume={row.name}>
            <td class="config-instance-id">{row.name}</td>
            <td class="config-instance-id">{row.path}</td>
            <td class="config-instance-id">
              <div :for={label <- VolumesView.env_labels(row.env)}>{label}</div>
            </td>
            <td class="config-instance-id">
              <div :for={dir <- row.path_dirs}>{dir}</div>
            </td>
            <td data-volume-usage={VolumesView.usage_state(row.usage)}>
              {VolumesView.usage_text(row.usage)}
            </td>
          </tr>
        </tbody>
      </table>
    </fieldset>
    """
  end
end
