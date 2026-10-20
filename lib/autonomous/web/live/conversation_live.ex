defmodule Autonomous.Web.ConversationLive do
  @moduledoc """
  The live agent conversation (feature 040): `/live` follows the newest
  in-flight session; `/live/:conversation_id` is pinned to one session. Mission Control embeds the
  same view below the running feature through `ConversationPanelLive`, a child
  LiveView that delegates here with `session: %{"embedded" => true}`.

  **Follow next sessions** is an operator toggle (`?follow=1` on `/live`; on by
  default in the embedded panel): while it is on, the end of the shown session
  moves the view to the next in-flight session of the run — at once if one is
  already open, else as soon as one opens. Off, the end marker stays on screen
  and only a `next session:` link is offered (never an automatic move).

  Viewer order is **subscribe → catch_up → apply broadcasts with
  `seq > last_seq`** (`Autonomous.Conversation`), which is what makes joining
  mid-session gapless and duplicate-free, and what a reconnect re-runs. The view
  reads only the recorder and the PubSub feed — it never calls the Coordinator —
  and a viewer that is slow, gone or crashed cannot affect the session (the
  recorder never waits for it).
  """

  use Autonomous.Web, :live_view

  alias Autonomous.{Conversation, ConversationFile}
  alias Autonomous.Web.{ConversationComponents, ConversationRows, SessionStatus}

  @console_topic "console:run"
  @tick_ms 1_000

  @impl true
  def mount(params, session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Autonomous.PubSub, @console_topic)

    embedded? = embedded?(session)

    socket =
      socket
      |> page_chrome(embedded?)
      |> assign(
        embedded?: embedded?,
        follow?: embedded?,
        all_frames?: false,
        pinned?: is_map(params) and is_binary(params["conversation_id"]),
        conversation_id: nil,
        header: nil,
        status: SessionStatus.new(),
        now: DateTime.utc_now(),
        tick?: false,
        ctx: ConversationRows.new(),
        last_seq: nil,
        live?: false,
        ended?: false,
        truncated?: false,
        next_session: nil,
        empty: nil,
        not_reachable?: false
      )
      |> stream_configure(:rows, dom_id: & &1.key)
      |> stream(:rows, [])

    # A child LiveView gets no handle_params: the embedded panel attaches here,
    # and renders without the app layout (it sits inside Mission Control's).
    if embedded? do
      {:ok, attach(socket, target_id(%{})), layout: false}
    else
      {:ok, socket}
    end
  end

  # Title and nav highlight belong to the page: the embedded panel must not
  # retitle Mission Control (a child's `page_title` replaces the document's).
  defp page_chrome(socket, true), do: socket

  defp page_chrome(socket, false),
    do: assign(socket, page_title: "Live session", current_path: "/live")

  defp embedded?(%{"embedded" => true}), do: true
  defp embedded?(_session), do: false

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      assign(socket,
        pinned?: is_binary(params["conversation_id"]),
        follow?: params["follow"] in ["1", "true"],
        all_frames?: params["frames"] == "all"
      )

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
    leave(socket.assigns.conversation_id)
    Conversation.subscribe(id)

    case Conversation.catch_up(id) do
      {:ok, entries, last_seq, truncated?} ->
        {rows, ctx} = rows_for(socket, entries)

        {header, opened_at} = header_for(id)

        socket
        |> assign(
          conversation_id: id,
          header: header,
          status: seed_status(id, entries, last_seq, truncated?, opened_at),
          now: DateTime.utc_now(),
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
        |> schedule_tick()

      :not_live when not is_nil(socket.assigns.conversation_id) ->
        # Switching to a session whose recorder is gone or slow: say so, and link
        # the shown session's saved record when the run recorded one.
        assign(socket, live?: false, not_reachable?: true)

      :not_live ->
        not_live(socket, id)
    end
  end

  # The embedded panel (045) shows the header and status footer only, so it
  # builds no rows; the status fold still sees every entry.
  defp rows_for(%{assigns: %{embedded?: true, ctx: ctx}}, _entries), do: {[], ctx}

  defp rows_for(socket, entries) do
    ConversationRows.rows(
      entries,
      ConversationRows.new(all_frames: socket.assigns.all_frames?)
    )
  end

  # Stop listening to the session the view is moving away from.
  defp leave(nil), do: :ok
  defp leave(id), do: Conversation.unsubscribe(id)

  # The embedded panel never navigates the page it sits in.
  defp not_live(%{assigns: %{embedded?: true}} = socket, _id),
    do: assign(socket, empty: :nothing_in_flight, live?: false)

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
      nil -> {nil, nil}
      %{identity: identity, opened_at: opened_at} -> {identity, opened_at}
    end
  end

  # Status seed (feature 042): the whole session so far, read once from the
  # session's file up to the catch-up `last_seq` — exact counters past the
  # 500-entry window. If the file cannot be read, fold the window instead; when
  # the window was truncated those counters are lower bounds and say so.
  defp seed_status(id, entries, last_seq, truncated?, opened_at) do
    status =
      with true <- is_integer(last_seq),
           {:ok, path} <- Conversation.file_path(id),
           {:ok, status} <-
             ConversationFile.fold(path, SessionStatus.new(), &SessionStatus.apply(&2, &1),
               through_seq: last_seq
             ) do
        status
      else
        _ ->
          window = SessionStatus.apply_all(SessionStatus.new(), entries)
          if truncated?, do: SessionStatus.mark_lower_bound(window), else: window
      end

    SessionStatus.put_started_at(status, opened_at)
  end

  # The elapsed clock: one server tick a second, only while the session is live
  # and not ended, and never more than one pending.
  defp schedule_tick(%{assigns: %{tick?: true}} = socket), do: socket

  defp schedule_tick(%{assigns: %{live?: true, ended?: false}} = socket) do
    if connected?(socket) do
      Process.send_after(self(), :tick, @tick_ms)
      assign(socket, tick?: true)
    else
      socket
    end
  end

  defp schedule_tick(socket), do: socket

  defp fresh?(_seq, nil), do: true
  defp fresh?(seq, last_seq), do: seq > last_seq

  # ---- events ---------------------------------------------------------------

  @impl true
  def handle_event("toggle_follow", _params, socket) do
    follow? = not socket.assigns.follow?
    socket = assign(socket, follow?: follow?)

    if follow? and socket.assigns.ended? and is_binary(socket.assigns.next_session) do
      {:noreply, follow_to(socket, socket.assigns.next_session)}
    else
      {:noreply, refresh_url(socket)}
    end
  end

  def handle_event("toggle_frames", _params, socket) do
    socket = assign(socket, all_frames?: not socket.assigns.all_frames?)

    socket =
      with id when is_binary(id) <- socket.assigns.conversation_id,
           {:ok, entries, _last, _truncated?} <- Conversation.catch_up(id) do
        {rows, ctx} =
          ConversationRows.rows(
            entries,
            ConversationRows.new(all_frames: socket.assigns.all_frames?)
          )

        socket |> assign(ctx: ctx) |> stream(:rows, rows, reset: true)
      else
        _ -> socket
      end

    {:noreply, refresh_url(socket)}
  end

  def handle_event("expand", %{"seq" => seq}, socket) do
    with {n, ""} <- Integer.parse(seq),
         id when is_binary(id) <- socket.assigns.conversation_id,
         {:ok, entry} <- Conversation.entry(id, n),
         %{} = block <- ConversationRows.expand(entry, socket.assigns.ctx) do
      {:noreply, stream_insert(socket, :rows, block)}
    else
      _ -> {:noreply, socket}
    end
  end

  # ---- live updates -----------------------------------------------------------

  @impl true
  def handle_info({:conversation, id, :entry, entry}, %{assigns: %{conversation_id: id}} = socket) do
    if fresh?(entry.seq, socket.assigns.last_seq) do
      {socket, ctx} = insert_rows(socket, entry)

      {:noreply,
       assign(socket,
         ctx: ctx,
         last_seq: entry.seq,
         status: SessionStatus.apply(socket.assigns.status, entry)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:conversation, id, :ended, _outcome},
        %{assigns: %{conversation_id: id}} = socket
      ) do
    socket = assign(socket, live?: false, ended?: true, next_session: next_session(socket, id))

    case socket.assigns do
      %{follow?: true, next_session: next} when is_binary(next) ->
        {:noreply, follow_to(socket, next)}

      _ ->
        {:noreply, socket}
    end
  end

  # A session opened. With "follow conversations" on, a view whose session has
  # ended (or that shows nothing) moves to it. Off: follow mode with nothing
  # being read switches to it; one still being read keeps its end marker on
  # screen and offers the link; a pinned view stays put.
  def handle_info({:console, :conversation_opened, %{conversation_id: new_id}}, socket) do
    a = socket.assigns

    cond do
      a.follow? and (a.ended? or is_nil(a.conversation_id) or a.empty != nil) ->
        {:noreply, follow_to(socket, new_id)}

      a.pinned? ->
        {:noreply, socket}

      is_nil(a.conversation_id) or a.empty != nil ->
        {:noreply, attach(socket, new_id)}

      a.ended? ->
        {:noreply, assign(socket, next_session: new_id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(:tick, socket) do
    a = socket.assigns

    if a.live? and not a.ended? do
      Process.send_after(self(), :tick, @tick_ms)
      {:noreply, assign(socket, now: DateTime.utc_now())}
    else
      {:noreply, assign(socket, tick?: false)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp insert_rows(%{assigns: %{embedded?: true, ctx: ctx}} = socket, _entry), do: {socket, ctx}

  defp insert_rows(socket, entry) do
    {rows, ctx} = ConversationRows.rows([entry], socket.assigns.ctx)

    {Enum.reduce(rows ++ ctx.stale, socket, fn row, acc -> stream_insert(acc, :rows, row) end),
     ctx}
  end

  # Move to another session: in place when embedded (a child LiveView cannot
  # patch the page URL), else by patching the URL so a reload keeps the place.
  defp follow_to(%{assigns: %{embedded?: true}} = socket, id), do: attach(socket, id)

  defp follow_to(socket, id),
    do: push_patch(socket, to: live_path(id, socket.assigns.follow?, socket.assigns.all_frames?))

  defp refresh_url(%{assigns: %{embedded?: true}} = socket), do: socket

  defp refresh_url(%{assigns: %{pinned?: true, conversation_id: id}} = socket) when is_binary(id),
    do:
      push_patch(socket,
        to: live_path(id, socket.assigns.follow?, socket.assigns.all_frames?),
        replace: true
      )

  defp refresh_url(socket),
    do:
      push_patch(socket,
        to: live_path(nil, socket.assigns.follow?, socket.assigns.all_frames?),
        replace: true
      )

  defp header_title(header, id, status) do
    lead =
      if header do
        [header.run_id, header.feature_id, header.phase, header.ordinal]
        |> Kernel.++(if header.chunk, do: ["chunk"], else: [])
        |> Kernel.++(if header.attempt, do: ["attempt #{header.attempt}"], else: [])
      else
        []
      end

    tail =
      [id, status.session_id, status.model_alias, status.model_resolved] |> Enum.reject(&is_nil/1)

    Enum.join(lead ++ tail, " · ")
  end

  defp live_path(id, follow?, all_frames?) do
    base = if id, do: "/live/" <> id, else: "/live"

    case Enum.filter([follow? && "follow=1", all_frames? && "frames=all"], & &1) do
      [] -> base
      params -> base <> "?" <> Enum.join(params, "&")
    end
  end

  defp next_session(%{assigns: %{pinned?: true, follow?: false}}, _id), do: nil

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
    <div class="view-conversation" data-view="conversation" data-embedded={to_string(@embedded?)}>
      <div class="conv-toolbar" data-conv-toolbar>
        <div class="conv-toolbar-row">
          <span
            :if={is_nil(@empty) and @conversation_id}
            class="live-session-link live-session-badge"
            data-live-badge
            data-live={to_string(@live?)}
          >
            <span class="transcript-live" data-live={to_string(@live?)}></span>
            {if @live?, do: "live session", else: "session ended"}
          </span>
          <label :if={not @embedded?} class="pr-toggle conv-follow">
            <input
              type="checkbox"
              class="switch-input"
              checked={@follow?}
              phx-click="toggle_follow"
              data-follow={to_string(@follow?)}
              aria-label="follow conversations"
            />
            <span class="switch-track"><span class="switch-knob"></span></span>
            <span class="option-name">follow conversations</span>
          </label>
          <ConversationComponents.frames_toggle :if={not @embedded?} all_frames?={@all_frames?} />
          <a
            :if={@embedded? and @conversation_id}
            href={"/live/" <> @conversation_id}
            class="btn-secondary btn-compact conv-open-full"
          >
            open full view
          </a>
        </div>
        <p
          :if={is_nil(@empty) and @conversation_id}
          class="conv-header transcript-path"
          title={header_title(@header, @conversation_id, @status)}
          data-conversation-header
        >
          <span :if={@header}>
            {@header.run_id} &middot; {@header.feature_id} &middot; {@header.phase} &middot; {@header.ordinal}<span :if={@header.chunk}> &middot; chunk</span><span :if={@header.attempt}> &middot; attempt {@header.attempt}</span>
            &middot;
          </span>
          {@conversation_id}<span :if={@status.session_id}> &middot; {@status.session_id}</span>
          <ConversationComponents.model_header status={@status} />
        </p>
      </div>

      <div :if={@empty == :nothing_in_flight} class="empty-state" data-state="nothing-in-flight">
        <p>No agent session in flight</p>
      </div>

      <div :if={match?({:not_found, _}, @empty)} class="empty-state" data-state="not-found">
        <p>Conversation {elem(@empty, 1)} is not live and has no saved record</p>
      </div>

      <div :if={is_nil(@empty) and @conversation_id} class="conv-view">
        <p :if={@truncated? and not @embedded?} class="conv-notice" data-notice="truncated">
          Showing the most recent 500 entries; earlier entries are in the full conversation once the session ends.
        </p>

        <p :if={@not_reachable?} class="conv-notice" data-notice="not-reachable">
          This session is not reachable live any more. Its saved conversation is under
          <a href={saved_path(@conversation_id) || "/transcripts"} class="btn-link">Transcripts</a>.
        </p>

        <div
          :if={not @embedded?}
          id="conversation-rows"
          phx-update="stream"
          phx-hook="FollowTail"
          data-follow={to_string(@follow?)}
          class="conv-rows"
        >
          <ConversationComponents.conversation_row
            :for={{dom_id, row} <- @streams.rows}
            id={dom_id}
            row={row}
          />
        </div>

        <p :if={not @embedded? and @next_session} class="conv-next" data-next-session>
          next session:
          <a href={"/live/" <> @next_session} class="btn-link">{@next_session}</a>
        </p>

        <ConversationComponents.status_line status={@status} live?={@live?} now={@now} />
      </div>
    </div>
    """
  end
end
