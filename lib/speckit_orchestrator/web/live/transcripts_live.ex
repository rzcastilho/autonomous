defmodule SpeckitOrchestrator.Web.TranscriptsLive do
  @moduledoc """
  US5 — Transcripts (`/transcripts`): a run/feature/attempt picker that reads
  the durable transcript from the store via `SpeckitOrchestrator.run_detail/1`
  (the picker) and `transcript/1` (the body), rendered verbatim — or an
  explicit "not found" state for an attempt whose transcript is absent (018,
  contracts/console-runs.md).

  Scoped to one run — the current in-flight run (`current_run_id/1`), or the
  repository's most recent run when nothing is in flight — same framing
  `MissionControlLive`/`PipelineDagLive` already use for their cold-boot
  overlay. `?run_id=`/`?feature=`/`?phase=`/`?attempt=` query params (the
  feature drawer's and Escalations' links) preselect a feature and, via
  `?phase=` (latest matching attempt) or `?attempt=` (an explicit index into
  that feature's `phase_attempts`), an attempt.
  """

  use SpeckitOrchestrator.Web, :live_view

  alias SpeckitOrchestrator.Pipeline

  @impl true
  def mount(params, _session, socket) do
    run_id = params["run_id"] || SpeckitOrchestrator.current_run_id() || latest_run_id()
    features = run_features(run_id)

    selected_feature_id = params["feature"] || feature_id(List.first(features))
    selected_feature = find_feature(features, selected_feature_id)
    selected_index = resolve_attempt_index(selected_feature, params)

    {:ok,
     socket
     |> assign(
       page_title: "Transcripts",
       current_path: "/transcripts",
       run_id: run_id,
       features: features,
       selected_feature_id: selected_feature_id,
       selected_index: selected_index
     )
     |> assign(doc: transcript_doc(selected_feature, selected_index))}
  end

  @impl true
  def handle_event("select_feature", %{"id" => id}, socket) do
    feature = find_feature(socket.assigns.features, id)
    index = default_index(feature)

    {:noreply,
     socket
     |> assign(selected_feature_id: id, selected_index: index)
     |> assign(doc: transcript_doc(feature, index))}
  end

  def handle_event("select_attempt", %{"index" => index_str}, socket) do
    feature = find_feature(socket.assigns.features, socket.assigns.selected_feature_id)

    index =
      case Integer.parse(index_str) do
        {n, _rest} -> n
        :error -> nil
      end

    {:noreply,
     socket
     |> assign(selected_index: index)
     |> assign(doc: transcript_doc(feature, index))}
  end

  # ---- store lookups ----------------------------------------------------

  defp run_features(nil), do: []

  defp run_features(run_id) do
    case SpeckitOrchestrator.run_detail(run_id) do
      {:ok, %{features: features}} -> features
      _ -> []
    end
  end

  defp latest_run_id do
    case SpeckitOrchestrator.run_history(limit: 1) do
      {:ok, [%{run_id: id} | _]} -> id
      _ -> nil
    end
  end

  defp find_feature(_features, nil), do: nil
  defp find_feature(features, id), do: Enum.find(features, &(&1.feature_id == id))

  defp feature_id(nil), do: nil
  defp feature_id(%{feature_id: id}), do: id

  defp transcript_doc(nil, _index), do: nil
  defp transcript_doc(_feature, nil), do: nil

  defp transcript_doc(feature, index) do
    case Enum.at(feature.phase_attempts, index) do
      nil ->
        nil

      attempt ->
        case SpeckitOrchestrator.transcript(attempt.transcript_ref) do
          {:ok, %{body: body}} -> %{attempt: attempt, body: body, exists?: true}
          _ -> %{attempt: attempt, body: nil, exists?: false}
        end
    end
  end

  # ---- attempt resolution (deep links: feature drawer, Escalations) -------

  defp resolve_attempt_index(nil, _params), do: nil

  defp resolve_attempt_index(feature, params) do
    case blank_to_nil(params["attempt"]) do
      nil -> phase_or_default_index(feature, blank_to_nil(params["phase"]))
      index_str -> explicit_index(feature, index_str)
    end
  end

  defp explicit_index(feature, index_str) do
    case Integer.parse(index_str) do
      {n, _rest} when n >= 0 and n < length(feature.phase_attempts) -> n
      _ -> phase_or_default_index(feature, nil)
    end
  end

  defp phase_or_default_index(feature, nil), do: default_index(feature)

  defp phase_or_default_index(feature, phase_str) do
    case safe_phase(phase_str) do
      {:ok, phase} ->
        feature.phase_attempts
        |> Enum.with_index()
        |> Enum.filter(fn {a, _i} -> a.phase == phase end)
        |> List.last()
        |> case do
          {_a, i} -> i
          nil -> default_index(feature)
        end

      :error ->
        default_index(feature)
    end
  end

  defp default_index(nil), do: nil
  defp default_index(%{phase_attempts: []}), do: nil
  defp default_index(%{phase_attempts: attempts}), do: length(attempts) - 1

  defp safe_phase(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)
    if Pipeline.phase?(atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s), do: if(String.trim(s) == "", do: nil, else: s)

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-transcripts" data-view="transcripts">
      <div :if={@features == []} class="empty-state" data-state="no-transcripts">
        <p>No transcripts available yet.</p>
      </div>

      <%= if @features != [] do %>
        <div class="transcripts-sidebar" data-form="picker">
          <div class="transcripts-sidebar-label">run {@run_id} &middot; feature</div>
          <button
            :for={f <- @features}
            type="button"
            phx-click="select_feature"
            phx-value-id={f.feature_id}
            data-feature-select={f.feature_id}
            class={[
              "transcript-feature-row",
              f.feature_id == @selected_feature_id && "transcript-feature-row-active"
            ]}
          >
            <span class="transcript-feature-dot"></span>
            <span class="transcript-feature-id">{f.feature_id} &middot; {f.slug}</span>
          </button>
        </div>

        <div class="transcripts-main">
          <div class="transcript-tabs">
            <button
              :for={
                {attempt, index} <-
                  Enum.with_index(feature_attempts(@features, @selected_feature_id))
              }
              type="button"
              phx-click="select_attempt"
              phx-value-index={index}
              data-attempt-select={index}
              class={["transcript-tab", index == @selected_index && "transcript-tab-active"]}
            >
              {attempt.phase}#{attempt.ordinal} &middot; {attempt.outcome}
            </button>
          </div>

          <div class="transcripts-body">
            <div :if={@doc && @doc.exists?} class="transcript-doc" data-state="found">
              <p class="transcript-path" data-transcript-path>
                {@selected_feature_id} &middot; {@doc.attempt.phase}#{@doc.attempt.ordinal}
              </p>
              <pre class="transcript-body">{@doc.body}</pre>
            </div>

            <div :if={@doc && not @doc.exists?} class="empty-state" data-state="not-yet-written">
              <p>No transcript recorded for this attempt.</p>
            </div>

            <div :if={is_nil(@doc)} class="empty-state" data-state="not-yet-written">
              <p>No attempts recorded yet for {@selected_feature_id}.</p>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp feature_attempts(features, feature_id) do
    case find_feature(features, feature_id) do
      nil -> []
      f -> f.phase_attempts
    end
  end
end
