defmodule Autonomous.Web.TranscriptsLive do
  @moduledoc """
  US5 — Transcripts (`/transcripts`): a run/feature/attempt picker that reads
  the durable transcript from the store via `Autonomous.run_detail/1`
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

  Feature 040: an attempt whose session was recorded shows its full saved
  conversation (`ConversationRows`, the same rows the live view renders), read
  from `ConversationFile.page/3` 500 entries at a time. `?session=` picks one
  of a retried phase's sessions (default: the last). Every fallback is stated:
  a partial file, a session that was not captured, an attempt recorded before
  040, and a file that is missing or unreadable all say so above the final text
  the store still has. Listings and tabs read refs only — the file is opened
  for the selected attempt alone (FR-021).
  """

  use Autonomous.Web, :live_view

  alias Autonomous.{ConversationFile, Pipeline, Report}

  alias Autonomous.Web.{
    ConversationComponents,
    ConversationRows,
    SessionStatus,
    TranscriptMarkup
  }

  @page 500

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Transcripts",
       current_path: "/transcripts",
       transcript_root: nil,
       selected_session: nil,
       all_frames?: false,
       conv: nil
     )
     |> stream_configure(:conv_rows, dom_id: & &1.key)
     |> stream(:conv_rows, [])}
  end

  # The run selector `push_patch`es `?run_id=`, so the URL stays the receipt and
  # selection lives here, not in `mount/3` (033, research R6).
  @impl true
  def handle_params(params, _uri, socket) do
    run_id = params["run_id"] || Autonomous.current_run_id() || latest_run_id()
    {features, root} = run_features(run_id)

    selected_feature_id = params["feature"] || feature_id(List.first(features))
    selected_feature = find_feature(features, selected_feature_id)
    selected_index = resolve_attempt_index(selected_feature, params)

    {:noreply,
     socket
     |> assign(
       run_id: run_id,
       run_options: run_options(run_id),
       features: features,
       selected_feature_id: selected_feature_id,
       selected_index: selected_index,
       transcript_root: root,
       selected_session: parse_index(params["session"]),
       all_frames?: params["frames"] == "all"
     )
     |> assign_doc(selected_feature, selected_index)}
  end

  @impl true
  def handle_event("select_run", %{"run_id" => run_id}, socket) do
    {:noreply, push_patch(socket, to: "/transcripts?" <> URI.encode_query(%{"run_id" => run_id}))}
  end

  def handle_event("select_feature", %{"id" => id}, socket) do
    feature = find_feature(socket.assigns.features, id)
    index = default_index(feature)

    {:noreply,
     socket
     |> assign(selected_feature_id: id, selected_index: index, selected_session: nil)
     |> assign_doc(feature, index)}
  end

  def handle_event("select_attempt", %{"index" => index_str}, socket) do
    feature = find_feature(socket.assigns.features, socket.assigns.selected_feature_id)

    index = parse_index(index_str)

    {:noreply,
     socket
     |> assign(selected_index: index, selected_session: nil)
     |> assign_doc(feature, index)}
  end

  def handle_event("select_session", %{"index" => index_str}, socket) do
    feature = find_feature(socket.assigns.features, socket.assigns.selected_feature_id)

    {:noreply,
     socket
     |> assign(selected_session: parse_index(index_str))
     |> assign_doc(feature, socket.assigns.selected_index)}
  end

  # Next page of the saved conversation; the context threads through so a tool
  # result on page two still pairs with its call on page one.
  def handle_event("toggle_frames", _params, socket) do
    socket = assign(socket, all_frames?: not socket.assigns.all_frames?)

    {:noreply,
     socket
     |> rebuild_rows()
     |> push_patch(to: transcripts_path(socket.assigns), replace: true)}
  end

  def handle_event("load_next", _params, %{assigns: %{conv: %{state: :rows} = conv}} = socket) do
    case conv.next_seq do
      :eof ->
        {:noreply, socket}

      from ->
        {:noreply, append_page(socket, conv, ConversationFile.page(conv.path, from, @page))}
    end
  end

  def handle_event("load_next", _params, socket), do: {:noreply, socket}

  def handle_event(
        "expand",
        %{"seq" => seq},
        %{assigns: %{conv: %{state: :rows} = conv}} = socket
      ) do
    with {n, ""} <- Integer.parse(seq),
         {:ok, entry} <- ConversationFile.entry(conv.path, n),
         %{} = block <- ConversationRows.expand(entry, conv.ctx) do
      {:noreply, stream_insert(socket, :conv_rows, block)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("expand", _params, socket), do: {:noreply, socket}

  # Re-block everything loaded so far under the current frames setting.
  defp rebuild_rows(%{assigns: %{conv: %{state: :rows} = conv}} = socket) do
    limit = if is_integer(conv.next_seq), do: conv.next_seq, else: 10_000_000

    case ConversationFile.page(conv.path, 0, max(limit, 1)) do
      {status, entries, _} when status == :ok ->
        reblock(socket, conv, entries)

      {:error, {:malformed, _}, entries} ->
        reblock(socket, conv, entries)

      _ ->
        socket
    end
  end

  defp rebuild_rows(socket), do: socket

  defp reblock(socket, conv, entries) do
    {rows, ctx} =
      ConversationRows.rows(entries, ConversationRows.new(all_frames: socket.assigns.all_frames?))

    socket |> assign(conv: %{conv | ctx: ctx}) |> stream(:conv_rows, rows, reset: true)
  end

  defp transcripts_path(a) do
    params =
      [
        {"run_id", a.run_id},
        {"feature", a.selected_feature_id},
        {"attempt", a.selected_index},
        {"session", a.conv && a.conv.state == :rows && a.conv.session},
        {"frames", a.all_frames? && "all"}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, false] end)

    "/transcripts?" <> URI.encode_query(params)
  end

  defp parse_index(nil), do: nil

  defp parse_index(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _rest} when n >= 0 -> n
      _ -> nil
    end
  end

  # ---- store lookups ----------------------------------------------------

  defp run_features(nil), do: {[], nil}

  defp run_features(run_id) do
    case Autonomous.run_detail(run_id) do
      {:ok, %{features: features} = detail} -> {features, transcript_root(detail)}
      _ -> {[], nil}
    end
  end

  # Where this run's conversation files live (the layout the run was opened with).
  defp transcript_root(%{run: %{layout: %{transcript_root: root}}}) when is_binary(root), do: root
  defp transcript_root(_detail), do: nil

  # The 20 most recent runs; the current selection is kept in the list even when
  # it is older, so the select always shows what the page is on.
  defp run_options(selected) do
    ids =
      case Autonomous.run_history(limit: 20) do
        {:ok, runs} -> for %{run_id: id} = run <- runs, not Map.get(run, :damaged, false), do: id
        _ -> []
      end

    if selected && selected not in ids, do: ids ++ [selected], else: ids
  end

  defp latest_run_id do
    case Autonomous.run_history(limit: 1) do
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
        case Autonomous.transcript(attempt.transcript_ref) do
          {:ok, %{body: body}} -> %{attempt: attempt, body: body, exists?: true}
          _ -> %{attempt: attempt, body: nil, exists?: false}
        end
    end
  end

  # ---- saved conversation (040) -------------------------------------------

  defp assign_doc(socket, feature, index) do
    doc = transcript_doc(feature, index)

    socket
    |> assign(doc: doc)
    |> load_conversation(doc && doc.attempt)
  end

  defp load_conversation(socket, nil), do: put_conv(socket, nil)

  defp load_conversation(socket, attempt) do
    case Map.get(attempt, :conversations) do
      nil ->
        put_conv(
          socket,
          note(
            [],
            0,
            "No full conversation was recorded for this attempt (recorded before feature 040)."
          )
        )

      [] ->
        put_conv(socket, nil)

      refs ->
        session = min(socket.assigns.selected_session || length(refs) - 1, length(refs) - 1)
        load_ref(socket, refs, session, Enum.at(refs, session))
    end
  end

  defp load_ref(socket, refs, session, %{status: :not_captured} = ref),
    do:
      put_conv(
        socket,
        note(refs, session, "No full conversation captured: " <> reason_text(ref.reason))
      )

  defp load_ref(socket, refs, session, ref) do
    path = saved_path(socket.assigns.transcript_root, ref)

    case path && ConversationFile.page(path, 0, @page) do
      {:ok, entries, next} ->
        show_rows(socket, refs, session, ref, path, entries, next, nil)

      {:error, {:malformed, line}, entries} ->
        show_rows(socket, refs, session, ref, path, entries, :eof, {:malformed, line})

      {:error, :missing} ->
        put_conv(socket, note(refs, session, "Saved conversation missing at #{ref.path}"))

      {:error, {:unreadable, posix}} ->
        put_conv(
          socket,
          note(refs, session, "Saved conversation unreadable: #{posix_text(posix)}")
        )

      {:error, {:unsupported_version, v}} ->
        put_conv(
          socket,
          note(refs, session, "Saved conversation uses unsupported format version #{v}")
        )

      {:error, {:malformed, line}} ->
        put_conv(socket, note(refs, session, "Saved conversation is damaged at line #{line}"))

      nil ->
        put_conv(socket, note(refs, session, "Saved conversation missing — no path recorded"))
    end
  end

  defp show_rows(socket, refs, session, ref, path, entries, next, damaged) do
    {rows, ctx} =
      ConversationRows.rows(entries, ConversationRows.new(all_frames: socket.assigns.all_frames?))

    conv = %{
      state: :rows,
      refs: refs,
      session: session,
      ref: ref,
      path: path,
      next_seq: next,
      ctx: ctx,
      status: SessionStatus.apply_all(SessionStatus.new(), entries),
      damaged: damaged
    }

    socket |> assign(conv: conv) |> stream(:conv_rows, rows, reset: true)
  end

  defp append_page(socket, conv, {:ok, entries, next}),
    do: insert_page(socket, conv, entries, next, nil)

  defp append_page(socket, conv, {:error, {:malformed, line}, entries}),
    do: insert_page(socket, conv, entries, :eof, {:malformed, line})

  defp append_page(socket, conv, {:error, _reason}),
    do: assign(socket, conv: %{conv | next_seq: :eof, damaged: :unreadable})

  defp insert_page(socket, conv, entries, next, damaged) do
    {rows, ctx} = ConversationRows.rows(entries, conv.ctx)

    socket =
      Enum.reduce(rows ++ ctx.stale, socket, fn row, acc ->
        stream_insert(acc, :conv_rows, row)
      end)

    status = SessionStatus.apply_all(conv.status, entries)
    assign(socket, conv: %{conv | next_seq: next, ctx: ctx, status: status, damaged: damaged})
  end

  defp put_conv(socket, nil),
    do: socket |> assign(conv: nil) |> stream(:conv_rows, [], reset: true)

  defp put_conv(socket, conv),
    do: socket |> assign(conv: conv) |> stream(:conv_rows, [], reset: true)

  defp note(refs, session, text), do: %{state: :note, refs: refs, session: session, note: text}

  defp saved_path(nil, _ref), do: nil
  defp saved_path(_root, %{path: nil}), do: nil
  defp saved_path(root, %{path: rel}), do: ConversationFile.resolve(root, rel)

  defp reason_text(nil), do: "no reason recorded"
  defp reason_text(reason), do: Report.format_reason(reason)

  defp posix_text(posix) when is_atom(posix), do: posix |> :file.format_error() |> to_string()
  defp posix_text(other), do: to_string(other)

  defp rows?(%{state: :rows}), do: true
  defp rows?(_conv), do: false

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
      <form :if={@run_options != []} id="transcript-run-form" phx-change="select_run" class="transcripts-run-select" data-form="run-select">
        <label class="field-label-inline" for="transcript-run">
          Run
          <select id="transcript-run" name="run_id" class="console-input" data-field="run_id">
            <option :for={id <- @run_options} value={id} selected={id == @run_id}>{id}</option>
          </select>
        </label>
      </form>

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
              {attempt.phase}#{pad_ordinal(attempt.ordinal)} &middot; {attempt.outcome}
            </button>
          </div>

          <div class="transcripts-body">
            <div :if={@doc && (@doc.exists? or rows?(@conv))} class="transcript-doc" data-state="found">
              <p class="transcript-path" data-transcript-path>
                {@selected_feature_id} &middot; {@doc.attempt.phase}#{pad_ordinal(@doc.attempt.ordinal)}
                <span
                  class="transcript-live"
                  data-live={to_string(is_nil(@doc.attempt.ended_at))}
                  title={if is_nil(@doc.attempt.ended_at), do: "live — no finish record yet", else: "finished"}
                ></span>
              </p>

              <div :if={@conv && length(@conv.refs) > 1} class="transcript-tabs" data-sessions>
                <button
                  :for={i <- 0..(length(@conv.refs) - 1)}
                  type="button"
                  phx-click="select_session"
                  phx-value-index={i}
                  data-session-select={i}
                  class={["transcript-tab", i == @conv.session && "transcript-tab-active"]}
                >
                  session {i + 1}
                </button>
              </div>

              <%= if rows?(@conv) do %>
                <div class="conv-toolbar-row" data-conv-toolbar>
                  <ConversationComponents.frames_toggle all_frames?={@all_frames?} />
                  <span class="conv-header transcript-path" data-conversation-header>
                    <ConversationComponents.model_header status={@conv.status} />
                  </span>
                </div>
                <div id="saved-conversation-rows" phx-update="stream" class="conv-rows" data-saved-conversation>
                  <ConversationComponents.conversation_row
                    :for={{dom_id, row} <- @streams.conv_rows}
                    id={dom_id}
                    row={row}
                  />
                </div>

                <ConversationComponents.status_line status={@conv.status} />

                <p :if={match?({:malformed, _}, @conv.damaged)} class="conv-notice" data-notice="damaged">
                  Saved conversation is damaged at line {elem(@conv.damaged, 1)}; showing the entries before it.
                </p>
                <p :if={@conv.damaged == :unreadable} class="conv-notice" data-notice="unreadable">
                  Saved conversation became unreadable; showing the entries loaded so far.
                </p>
                <p
                  :if={@conv.ref.status == :partial and @conv.next_seq == :eof}
                  class="conv-notice"
                  data-notice="partial"
                >
                  ended without an end marker — {reason_text(@conv.ref.reason)}
                </p>
                <button
                  :if={@conv.next_seq != :eof}
                  type="button"
                  phx-click="load_next"
                  class="btn-secondary"
                  data-load-next
                >
                  load next 500
                </button>
              <% else %>
                <p :if={@conv} class="conv-notice" data-notice="conversation">{@conv.note}</p>
                <div class="transcript-body">{TranscriptMarkup.render(@doc.body)}</div>
              <% end %>
            </div>

            <div :if={@doc && not @doc.exists? && not rows?(@conv)} class="empty-state" data-state="not-yet-written">
              <p :if={@conv} class="conv-notice" data-notice="conversation">{@conv.note}</p>
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
