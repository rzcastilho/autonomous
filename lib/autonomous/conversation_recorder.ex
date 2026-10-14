defmodule Autonomous.ConversationRecorder do
  @moduledoc """
  One temporary process per agent session (feature 040, R3): receives the raw
  CLI frames the `SdkProxy` tap `send/2`s, and for each entry — in a single
  callback — masks credentials, assigns `seq`, pushes the catch-up window,
  appends to the conversation file and broadcasts on
  `"conversation:<id>"`. Serving `:catch_up` from the same mailbox is what makes
  the viewer seam gapless (FR-007, SC-006).

  A thin shell over `ConversationEntry`, `CredentialMask`, `ConversationWindow`
  and `ConversationFile`. A file write error marks the recorder partial but the
  window and broadcasts continue; nothing here can fail the session.
  """

  use GenServer, restart: :temporary

  alias Autonomous.{
    ConversationEntry,
    ConversationFile,
    ConversationIdentity,
    ConversationOutcome,
    ConversationWindow,
    CredentialMask
  }

  alias Autonomous.Store.Records.ConversationRef

  @registry Autonomous.ConversationRegistry
  @pubsub Autonomous.PubSub

  @doc false
  def start_link(opts) do
    id = Keyword.fetch!(opts, :conversation_id)
    identity = Keyword.fetch!(opts, :identity)
    opened_at = Keyword.fetch!(opts, :opened_at)

    value = %{
      identity: %{identity | transcript_root: nil},
      opened_at: opened_at,
      conversation_id: id,
      path:
        ConversationFile.resolve(
          identity.transcript_root,
          ConversationFile.relative_path(identity, id)
        )
    }

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, id, value}})
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :conversation_id)
    identity = Keyword.fetch!(opts, :identity)
    opened_at = Keyword.fetch!(opts, :opened_at)

    case ConversationFile.open(identity, id, opened_at) do
      {:ok, handle, header_bytes} ->
        state = %{
          id: id,
          identity: identity,
          handle: handle,
          seq: 0,
          window: ConversationWindow.new(),
          pairs: CredentialMask.pairs(),
          bytes: header_bytes,
          entries: 0,
          error: nil,
          session_id: nil
        }

        state =
          state
          |> emit(ConversationEntry.new(:start, start_body(identity, opts)))
          |> emit(ConversationEntry.new(:prompt, %{"text" => Keyword.get(opts, :prompt, "")}))

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp start_body(identity, opts),
    do: Map.put(ConversationIdentity.to_map(identity), "model", Keyword.get(opts, :model))

  @impl true
  def handle_info({:frame, frame}, state) do
    state = note_session_id(state, frame)

    {:noreply,
     frame
     |> ConversationEntry.from_frame()
     |> Enum.reduce(state, &emit(&2, &1))}
  rescue
    # Capture must never take anything down; an unprocessable frame is a gap we
    # report, not a crash.
    e -> {:noreply, %{state | error: state.error || {:frame_failed, Exception.message(e)}}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:catch_up, _from, state) do
    {entries, last_seq, truncated?} = ConversationWindow.snapshot(state.window)
    {:reply, {:ok, entries, last_seq, truncated?}, state}
  end

  def handle_call({:entry, seq}, _from, state),
    do: {:reply, ConversationWindow.fetch(state.window, seq) |> unwrap(), state}

  def handle_call({:close, outcome, session_id, drain?}, _from, state) do
    state =
      emit(
        state,
        ConversationEntry.new(:end, %{
          "outcome" => ConversationOutcome.encode(outcome),
          "session_id" => session_id || state.session_id,
          "drain_requested" => drain? == true
        })
      )

    ConversationFile.close(state.handle)
    Registry.unregister(@registry, state.id)
    Phoenix.PubSub.broadcast(@pubsub, topic(state.id), {:conversation, state.id, :ended, outcome})

    ref = %ConversationRef{
      conversation_id: state.id,
      path: state.handle.rel,
      status: ConversationOutcome.capture_status(state.error),
      reason: state.error,
      session_id: session_id || state.session_id,
      entries: state.entries,
      bytes: state.bytes,
      outcome: outcome
    }

    {:stop, :normal, {:ok, ref}, state}
  end

  defp unwrap({:ok, entry}), do: {:ok, entry}
  defp unwrap(:not_in_window), do: :not_in_window

  defp note_session_id(%{session_id: nil} = state, %{raw: %{"session_id" => sid}})
       when is_binary(sid),
       do: %{state | session_id: sid}

  defp note_session_id(state, _frame), do: state

  # Mask → seq → window → append → broadcast, one entry at a time.
  defp emit(state, %ConversationEntry{} = entry) do
    entry = %{
      entry
      | seq: state.seq,
        at: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601(),
        body: CredentialMask.mask(entry.body, state.pairs)
    }

    state = %{
      state
      | seq: state.seq + 1,
        entries: state.entries + 1,
        window: ConversationWindow.push(state.window, entry)
    }

    state = append(state, entry)
    Phoenix.PubSub.broadcast(@pubsub, topic(state.id), {:conversation, state.id, :entry, entry})
    state
  end

  defp append(%{error: nil} = state, entry) do
    case ConversationFile.append(state.handle, entry) do
      {:ok, n} -> %{state | bytes: state.bytes + n}
      {:error, posix} -> %{state | error: {:write_failed, posix}}
    end
  end

  # After a write failure the file is left as it is; the window and broadcast go on.
  defp append(state, _entry), do: state

  @doc false
  def topic(id), do: "conversation:" <> id
end
