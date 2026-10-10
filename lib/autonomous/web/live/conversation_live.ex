defmodule Autonomous.Web.ConversationLive do
  @moduledoc """
  The live agent conversation (feature 040): `/live` follows the newest
  in-flight session; `/live/:conversation_id` is pinned to one session.

  Viewer order is **subscribe → catch_up → apply broadcasts with
  `seq > last_seq`** (`Autonomous.Conversation`), which is what makes joining
  mid-session gapless and duplicate-free, and what a reconnect re-runs. The view
  reads only the recorder and the PubSub feed — it never calls the Coordinator —
  and a viewer that is slow, gone or crashed cannot affect the session (the
  recorder never waits for it).
  """

  use Autonomous.Web, :live_view

  alias Autonomous.{Conversation, ConversationEntry}
  alias Autonomous.Web.{ConversationComponents, ConversationRows}

  @console_topic "console:run"

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Autonomous.PubSub, @console_topic)

    {:ok,
     socket
     |> assign(
       page_title: "Live session",
       current_path: "/live",
       pinned?: is_binary(params["conversation_id"]),
       conversation_id: nil,
       header: nil,
       session_id: nil,
       ctx: ConversationRows.new(),
       last_seq: 0,
       live?: false,
       ended?: false,
       truncated?: false,
       next_session: nil,
       empty: nil,
       not_reachable?: false
     )
     |> stream_configure(:rows, dom_id: & &1.key)
     |> stream(:rows, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, attach(socket, target_id(params))}
  end

  # Follow mode picks the newest in-flight session; pinned mode uses the id.
  defp target_id(%{"conversation_id" => id}), do: id

  defp target_id(_params) do
    case Conversation.in_flight(nil) do
      [%{conversation_id: id} | _] -> id
      [] -> nil
    end
  end

  # The static render only frames the page; the connected mount attaches.
  defp attach(%{transport_pid: nil} = socket, _id), do: socket

  defp attach(socket, nil), do: assign(socket, empty: :nothing_in_flight, live?: false)

  # Re-attaching to the conversation already shown is a no-op (a patch to the
  # same URL must not wipe what the operator is reading).
  defp attach(%{assigns: %{conversation_id: id}} = socket, id), do: socket

  defp attach(socket, id) do
    Conversation.subscribe(id)

    case Conversation.catch_up(id) do
      {:ok, entries, last_seq, truncated?} ->
        {rows, ctx} = ConversationRows.rows(entries)

        socket
        |> assign(
          conversation_id: id,
          header: header_for(id),
          session_id: session_id_of(entries),
          ctx: ctx,
          last_seq: last_seq,
          live?: true,
          ended?: false,
          truncated?: truncated?,
          next_session: nil,
          empty: nil,
          not_reachable?: false
        )
        |> stream(:rows, rows, reset: true)

      :not_live when not is_nil(socket.assigns.conversation_id) ->
        # Switching to a session whose recorder is gone or slow: say so, and link
        # the shown session's saved record when the run recorded one.
        assign(socket, live?: false, not_reachable?: true)

      :not_live ->
        not_live(socket, id)
    end
  end

  defp not_live(socket, id) do
    case saved_path(id) do
      nil -> assign(socket, conversation_id: id, empty: {:not_found, id}, live?: false)
      path -> push_navigate(socket, to: path)
    end
  end

  # The Transcripts entry of a finished session, from the recorded refs only.
  defp saved_path(id) do
    with run_id when is_binary(run_id) <- Autonomous.current_run_id(),
         {:ok, %{features: features}} <- Autonomous.run_detail(run_id) do
      Enum.find_value(features, &saved_in_feature(&1, run_id, id))
    else
      _ -> nil
    end
  end

  defp saved_in_feature(feature, run_id, id) do
    feature.phase_attempts
    |> Enum.with_index()
    |> Enum.find_value(fn {attempt, index} ->
      refs = Map.get(attempt, :conversations) || []

      case Enum.find_index(refs, &(&1.conversation_id == id)) do
        nil ->
          nil

        session ->
          "/transcripts?" <>
            URI.encode_query(%{
              "run_id" => run_id,
              "feature" => feature.feature_id,
              "attempt" => index,
              "session" => session
            })
      end
    end)
  end

  defp header_for(id) do
    case Enum.find(Conversation.in_flight(nil), &(&1.conversation_id == id)) do
      nil -> nil
      %{identity: identity} -> identity
    end
  end

  defp session_id_of(entries) do
    Enum.find_value(entries, fn
      %ConversationEntry{kind: :system, body: %{"data" => %{"session_id" => sid}}} -> sid
      _ -> nil
    end)
  end

  # ---- events ---------------------------------------------------------------

  @impl true
  def handle_event("expand", %{"seq" => seq}, socket) do
    with {n, ""} <- Integer.parse(seq),
         id when is_binary(id) <- socket.assigns.conversation_id,
         {:ok, entry} <- Conversation.entry(id, n) do
      row = ConversationRows.row(entry, socket.assigns.ctx, expand: true)
      {:noreply, stream_insert(socket, :rows, row)}
    else
      _ -> {:noreply, socket}
    end
  end

  # ---- live updates -----------------------------------------------------------

  @impl true
  def handle_info({:conversation, id, :entry, entry}, %{assigns: %{conversation_id: id}} = socket) do
    if entry.seq > socket.assigns.last_seq do
      {rows, ctx} = ConversationRows.rows([entry], socket.assigns.ctx)

      socket =
        Enum.reduce(rows ++ ctx.stale, socket, fn row, acc -> stream_insert(acc, :rows, row) end)

      {:noreply,
       assign(socket,
         ctx: ctx,
         last_seq: entry.seq,
         session_id: socket.assigns.session_id || session_id_of([entry])
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:conversation, id, :ended, _outcome},
        %{assigns: %{conversation_id: id}} = socket
      ) do
    {:noreply, assign(socket, live?: false, ended?: true, next_session: next_session(socket, id))}
  end

  # A session opened: follow mode with nothing being read switches to it; one
  # still being read keeps its end marker on screen and offers the link.
  def handle_info({:console, :conversation_opened, %{conversation_id: new_id}}, socket) do
    a = socket.assigns

    cond do
      a.pinned? -> {:noreply, socket}
      is_nil(a.conversation_id) or a.empty != nil -> {:noreply, attach(socket, new_id)}
      a.ended? -> {:noreply, assign(socket, next_session: new_id)}
      true -> {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp next_session(%{assigns: %{pinned?: true}}, _id), do: nil

  defp next_session(_socket, id) do
    case Conversation.in_flight(nil) do
      [%{conversation_id: other} | _] when other != id -> other
      _ -> nil
    end
  end

  # ---- render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div class="view-conversation" data-view="conversation">
      <div :if={@empty == :nothing_in_flight} class="empty-state" data-state="nothing-in-flight">
        <p>No agent session in flight</p>
      </div>

      <div :if={match?({:not_found, _}, @empty)} class="empty-state" data-state="not-found">
        <p>Conversation {elem(@empty, 1)} is not live and has no saved record</p>
      </div>

      <div :if={is_nil(@empty) and @conversation_id} class="conv-view">
        <p class="conv-header transcript-path" data-conversation-header>
          <span :if={@header}>
            {@header.run_id} &middot; {@header.feature_id} &middot; {@header.phase} &middot; {@header.ordinal}<span :if={@header.chunk}> &middot; chunk</span><span :if={@header.attempt}> &middot; attempt {@header.attempt}</span>
          </span>
          &middot; {@conversation_id}<span :if={@session_id}> &middot; {@session_id}</span>
          <span
            class="transcript-live"
            data-live={to_string(@live?)}
            title={if @live?, do: "live", else: "ended"}
          ></span>
        </p>

        <p :if={@truncated?} class="conv-notice" data-notice="truncated">
          Showing the most recent 500 entries; earlier entries are in the full conversation once the session ends.
        </p>

        <p :if={@not_reachable?} class="conv-notice" data-notice="not-reachable">
          This session is not reachable live any more. Its saved conversation is under
          <a href={saved_path(@conversation_id) || "/transcripts"} class="btn-link">Transcripts</a>.
        </p>

        <div id="conversation-rows" phx-update="stream" class="conv-rows">
          <ConversationComponents.conversation_row
            :for={{dom_id, row} <- @streams.rows}
            id={dom_id}
            row={row}
          />
        </div>

        <p :if={@next_session} class="conv-next" data-next-session>
          next session:
          <a href={"/live/" <> @next_session} class="btn-link">{@next_session}</a>
        </p>
      </div>
    </div>
    """
  end
end
