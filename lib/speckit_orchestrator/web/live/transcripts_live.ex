defmodule SpeckitOrchestrator.Web.TranscriptsLive do
  @moduledoc """
  US5 — Transcripts (`/transcripts`): a feature+phase picker that reads the
  durable transcript written by `SpeckitOrchestrator.Transcripts` at
  `<transcript_root>/<feature_id>/NN-<phase>.md`, rendering its body + source
  path, or an explicit "not yet written" state for a phase the feature
  hasn't reached (`specs/008-control-plane/tasks.md` T061-T062).

  Filesystem-only — no facade/Coordinator/Ledger reads, no write path (the
  write-only `Transcripts` module is untouched). Fully independent of every
  other view; the feature drawer (`FeatureDrawerComponent`) links here with
  `?feature=<id>&phase=<phase>` to preselect (FR-012).
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.{Config, Pipeline}

  @impl true
  def mount(params, _session, socket) do
    feature_ids = list_feature_ids()
    selected_feature = params["feature"] || List.first(feature_ids)
    selected_phase = safe_phase(params["phase"]) || List.first(Pipeline.phases())

    {:ok,
     socket
     |> assign(
       page_title: "Transcripts",
       current_path: "/transcripts",
       feature_ids: feature_ids,
       selected_feature: selected_feature,
       selected_phase: selected_phase
     )
     |> assign(doc: transcript_doc(selected_feature, selected_phase))}
  end

  @impl true
  def handle_event("select", %{"feature" => feature, "phase" => phase}, socket) do
    feature = blank_to_nil(feature)
    phase = safe_phase(phase)

    {:noreply,
     socket
     |> assign(selected_feature: feature, selected_phase: phase)
     |> assign(doc: transcript_doc(feature, phase))}
  end

  # ---- filesystem helper (T061) --------------------------------------------

  defp list_feature_ids do
    root = Config.transcript_root()

    case File.ls(root) do
      {:ok, entries} -> entries |> Enum.filter(&File.dir?(Path.join(root, &1))) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp transcript_doc(nil, _phase), do: nil
  defp transcript_doc(_feature_id, nil), do: nil

  defp transcript_doc(feature_id, phase) do
    case find_transcript_path(feature_id, phase) do
      nil ->
        %{feature_id: feature_id, phase: phase, path: nil, body: nil, exists?: false}

      path ->
        case File.read(path) do
          {:ok, body} -> %{feature_id: feature_id, phase: phase, path: path, body: body, exists?: true}
          {:error, _} -> %{feature_id: feature_id, phase: phase, path: path, body: nil, exists?: false}
        end
    end
  end

  defp find_transcript_path(feature_id, phase) do
    Config.transcript_root()
    |> Path.join(feature_id)
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
      <div :if={@feature_ids == []} class="empty-state" data-state="no-transcripts">
        <p>No transcripts available yet.</p>
      </div>

      <form :if={@feature_ids != []} id="transcript-picker" phx-change="select" data-form="picker">
        <label>
          Feature
          <select name="feature">
            <option :for={id <- @feature_ids} value={id} selected={id == @selected_feature}>
              {id}
            </option>
          </select>
        </label>
        <label>
          Phase
          <select name="phase">
            <option :for={p <- Pipeline.phases()} value={p} selected={p == @selected_phase}>
              {p}
            </option>
          </select>
        </label>
      </form>

      <div :if={@doc && @doc.exists?} class="transcript-doc" data-state="found">
        <p class="transcript-path" data-transcript-path>{@doc.path}</p>
        <pre class="transcript-body">{@doc.body}</pre>
      </div>

      <div :if={@doc && not @doc.exists?} class="empty-state" data-state="not-yet-written">
        <p>Phase "{@doc.phase}" has not been reached yet for {@doc.feature_id} — no transcript written.</p>
      </div>
    </div>
    """
  end
end
