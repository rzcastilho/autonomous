defmodule SpeckitOrchestrator.Web.TranscriptsLive do
  @moduledoc """
  US5 — Transcripts (`/transcripts`): a feature+phase picker that reads the
  durable transcript written by `SpeckitOrchestrator.Transcripts` at
  `<autonomous_root>/transcripts/<segment>/<scope>/<feature_id>/NN-<phase>.md`
  (`<scope>` a breakdown slug or the literal `ad-hoc`, 012), rendering its
  body + source path, or an explicit "not yet written" state for a phase the
  feature hasn't reached (`specs/008-control-plane/tasks.md` T061-T062).

  Filesystem-only — no facade/Coordinator/Ledger reads, no write path (the
  write-only `Transcripts` module is untouched). Fully independent of every
  other view; the feature drawer (`FeatureDrawerComponent`) links here with
  `?feature=<scope>/<id>&phase=<phase>` to preselect (FR-012).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{Config, Pipeline, RepoIdentity}

  @impl true
  def mount(params, _session, socket) do
    root = transcripts_root(Config.repo())
    entries = list_entries(root)
    selected_key = params["feature"] || List.first(entries)
    selected_phase = safe_phase(params["phase"]) || List.first(Pipeline.phases())

    {:ok,
     socket
     |> assign(
       page_title: "Transcripts",
       current_path: "/transcripts",
       root: root,
       entries: entries,
       selected_key: selected_key,
       selected_phase: selected_phase
     )
     |> assign(doc: transcript_doc(root, selected_key, selected_phase))}
  end

  @impl true
  def handle_event("select", %{"feature" => key, "phase" => phase}, socket) do
    key = blank_to_nil(key)
    phase = safe_phase(phase)

    {:noreply,
     socket
     |> assign(selected_key: key, selected_phase: phase)
     |> assign(doc: transcript_doc(socket.assigns.root, key, phase))}
  end

  # ---- filesystem helpers (T061, updated 012 for the segment/scope grammar) --

  # Best-effort — a repo with no origin (or not yet a git repo) simply has no
  # transcripts to browse (no segment to key the machine-global root by).
  defp transcripts_root(repo) do
    case RepoIdentity.resolve(repo) do
      {:ok, segment} -> Path.join([Config.autonomous_root(), "transcripts", segment])
      {:error, _reason} -> nil
    end
  end

  defp list_entries(nil), do: []

  defp list_entries(root) do
    case File.ls(root) do
      {:ok, scopes} ->
        scopes
        |> Enum.filter(&File.dir?(Path.join(root, &1)))
        |> Enum.flat_map(&feature_keys(root, &1))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp feature_keys(root, scope) do
    scope_dir = Path.join(root, scope)

    case File.ls(scope_dir) do
      {:ok, ids} -> ids |> Enum.filter(&File.dir?(Path.join(scope_dir, &1))) |> Enum.map(&"#{scope}/#{&1}")
      {:error, _reason} -> []
    end
  end

  defp transcript_doc(_root, nil, _phase), do: nil
  defp transcript_doc(_root, _key, nil), do: nil

  defp transcript_doc(root, key, phase) do
    case find_transcript_path(root, key, phase) do
      nil ->
        %{feature_id: key, phase: phase, path: nil, body: nil, exists?: false}

      path ->
        case File.read(path) do
          {:ok, body} -> %{feature_id: key, phase: phase, path: path, body: body, exists?: true}
          {:error, _} -> %{feature_id: key, phase: phase, path: path, body: nil, exists?: false}
        end
    end
  end

  defp find_transcript_path(root, key, phase) do
    root
    |> Path.join(key)
    |> Path.join("*-#{phase}.md")
    |> Path.wildcard()
    |> List.first()
  end

  defp safe_phase(nil), do: nil

  defp safe_phase(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)
    if Pipeline.phase?(atom), do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp blank_to_nil(s), do: if(String.trim(s || "") == "", do: nil, else: s)

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-transcripts" data-view="transcripts">
      <div :if={@entries == []} class="empty-state" data-state="no-transcripts">
        <p>No transcripts available yet.</p>
      </div>

      <%= if @entries != [] do %>
        <div class="transcripts-sidebar" data-form="picker">
          <div class="transcripts-sidebar-label">&lt;segment&gt;/&lt;scope&gt;/&lt;feature_id&gt;</div>
          <button
            :for={key <- @entries}
            type="button"
            phx-click="select"
            phx-value-feature={key}
            phx-value-phase={@selected_phase}
            data-feature-select={key}
            class={[
              "transcript-feature-row",
              key == @selected_key && "transcript-feature-row-active"
            ]}
          >
            <span class="transcript-feature-dot"></span>
            <span class="transcript-feature-id">{key}</span>
          </button>
        </div>

        <div class="transcripts-main">
          <div class="transcript-tabs">
            <button
              :for={p <- Pipeline.phases()}
              type="button"
              phx-click="select"
              phx-value-feature={@selected_key}
              phx-value-phase={p}
              data-phase-select={p}
              class={["transcript-tab", p == @selected_phase && "transcript-tab-active"]}
            >
              {p}
            </button>
          </div>

          <div class="transcripts-body">
            <div :if={@doc && @doc.exists?} class="transcript-doc" data-state="found">
              <p class="transcript-path" data-transcript-path>{@doc.path}</p>
              <pre class="transcript-body">{@doc.body}</pre>
            </div>

            <div :if={@doc && not @doc.exists?} class="empty-state" data-state="not-yet-written">
              <p>
                Phase "{@doc.phase}" has not been reached yet for {@doc.feature_id} — no transcript written.
              </p>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
