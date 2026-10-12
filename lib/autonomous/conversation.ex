defmodule Autonomous.Conversation do
  @moduledoc """
  Facade of the per-session conversation capture (feature 040,
  `contracts/conversation-capture.md`).

  Session side: `open/2` before the harness `run_request`, `close/2` after the
  fold returns — on **every** outcome. Viewer side: `subscribe/1`, `catch_up/1`,
  `entry/2`, `in_flight/1`. All functions are exit-safe; none raises or exits
  into a caller because a recorder is slow, dead or missing, and capture never
  changes a session's outcome (FR-005, FR-017): when capture cannot start the
  request comes back **unchanged** and the session runs exactly as before.
  """

  require Logger

  alias Autonomous.{
    ConversationIdentity,
    ConversationOutcome,
    ConversationRecorder,
    PhaseRequest,
    PhaseResult
  }

  alias Autonomous.Store.Records.ConversationRef
  alias Jido.Harness.RunRequest

  @registry Autonomous.ConversationRegistry
  @sup Autonomous.ConversationSup
  @pubsub Autonomous.PubSub
  @console_topic "console:run"
  @close_timeout 30_000
  @view_timeout 1_000

  @type handle :: %{
          conversation_id: String.t(),
          pid: pid(),
          identity: ConversationIdentity.t()
        }

  @doc """
  Start a recorder for `identity` and add the capture marker to `request`.
  `{:not_captured, ref, request}` (request unchanged) on any failure.
  """
  @spec open(ConversationIdentity.t() | nil, RunRequest.t()) ::
          {:ok, handle(), RunRequest.t()}
          | {:not_captured, ConversationRef.t() | nil, RunRequest.t()}
  def open(nil, request), do: {:not_captured, nil, request}

  def open(identity, %RunRequest{} = request) do
    with {:ok, identity} <- ConversationIdentity.validate(identity),
         id = new_id(identity),
         opts = [
           conversation_id: id,
           identity: identity,
           opened_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
           prompt: request.prompt,
           model: request.model
         ],
         {:ok, pid} <- start_recorder(opts) do
      broadcast_console(:conversation_opened, %{
        conversation_id: id,
        feature_id: identity.feature_id,
        phase: identity.phase
      })

      {:ok, %{conversation_id: id, pid: pid, identity: identity},
       PhaseRequest.put_conversation(request, pid)}
    else
      {:error, reason} -> not_captured(open_reason(reason), request)
    end
  catch
    kind, reason -> not_captured({:open_failed, {kind, reason}}, request)
  end

  defp start_recorder(opts) do
    case DynamicSupervisor.start_child(@sup, {ConversationRecorder, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      :ignore -> {:error, {:open_failed, :ignored}}
    end
  end

  defp open_reason({:bad_identity, _} = r), do: {:open_failed, r}
  defp open_reason({:open_failed, _} = r), do: r
  defp open_reason(other), do: {:open_failed, other}

  defp not_captured(reason, request) do
    ref = %ConversationRef{
      conversation_id: nil,
      path: nil,
      status: ConversationOutcome.capture_status(reason),
      reason: reason
    }

    warn(ref)
    {:not_captured, ref, request}
  end

  @doc """
  End the recorder (writes the single `:end` entry) and return the ref. Never
  raises: a timeout, a missing or a crashed recorder yields a `:partial` ref.
  """
  @spec close(
          handle() | {:not_captured, ConversationRef.t() | nil},
          PhaseResult.t() | nil,
          keyword()
        ) ::
          ConversationRef.t() | nil
  def close(handle, result, opts \\ [])

  def close({:not_captured, ref}, _result, _opts), do: ref

  def close(%{conversation_id: id, pid: pid, identity: identity}, result, opts) do
    outcome = ConversationOutcome.from_result(result)
    session_id = result && result.session_id
    drain? = Keyword.get(opts, :drain_requested, drain_requested?())

    ref =
      try do
        case GenServer.call(pid, {:close, outcome, session_id, drain?}, @close_timeout) do
          {:ok, %ConversationRef{} = ref} -> ref
        end
      catch
        :exit, {:timeout, _} -> partial(id, identity, :close_timeout, outcome, session_id)
        :exit, _ -> partial(id, identity, :recorder_down, outcome, session_id)
      end

    broadcast_console(:conversation_closed, %{conversation_id: id, status: ref.status})
    warn(ref)
    ref
  end

  defp partial(id, identity, reason, outcome, session_id) do
    %ConversationRef{
      conversation_id: id,
      path: Autonomous.ConversationFile.relative_path(identity, id),
      status: :partial,
      reason: reason,
      session_id: session_id,
      outcome: outcome
    }
  end

  defp drain_requested? do
    Autonomous.Workers.drain_requested?()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp warn(%ConversationRef{status: :captured}), do: :ok

  defp warn(%ConversationRef{} = ref) do
    Logger.warning(
      "conversation #{ref.conversation_id || "(none)"} not fully captured " <>
        "(#{ref.status}): #{inspect(ref.reason)}"
    )
  end

  # ── viewer side ────────────────────────────────────────────────────────────

  @spec subscribe(String.t()) :: :ok
  def subscribe(id) do
    _ = Phoenix.PubSub.subscribe(@pubsub, ConversationRecorder.topic(id))
    :ok
  end

  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(id) do
    _ = Phoenix.PubSub.unsubscribe(@pubsub, ConversationRecorder.topic(id))
    :ok
  end

  @spec catch_up(String.t()) :: {:ok, [map()], non_neg_integer() | nil, boolean()} | :not_live
  def catch_up(id) do
    case call(id, :catch_up) do
      {:ok, _, _, _} = ok -> ok
      _ -> :not_live
    end
  end

  @spec entry(String.t(), non_neg_integer()) :: {:ok, map()} | :not_found
  def entry(id, seq) do
    case call(id, {:entry, seq}) do
      {:ok, entry} -> {:ok, entry}
      _ -> :not_found
    end
  end

  defp call(id, msg) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> GenServer.call(pid, msg, @view_timeout)
      [] -> :not_live
    end
  catch
    :exit, _ -> :not_live
  end

  @doc "In-flight conversations of `repo_id` (any when `nil`), newest first."
  @spec in_flight(String.t() | nil) :: [map()]
  def in_flight(repo_id \\ nil) do
    @registry
    |> Registry.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, v} -> repo_id == nil or v.identity.repo_id == repo_id end)
    |> Enum.map(fn {id, v} ->
      %{conversation_id: id, identity: v.identity, opened_at: v.opened_at}
    end)
    |> Enum.sort_by(& &1.conversation_id, :desc)
    |> Enum.sort_by(& &1.opened_at, :desc)
  end

  @doc "In-flight sessions as `%{feature_id => conversation_id}` (newest wins)."
  @spec live_by_feature(String.t() | nil) :: %{String.t() => String.t()}
  def live_by_feature(repo_id \\ nil) do
    repo_id
    |> in_flight()
    |> Enum.reverse()
    |> Map.new(fn %{conversation_id: id, identity: identity} -> {identity.feature_id, id} end)
  end

  @doc """
  Apply a `{:console, :conversation_opened | :conversation_closed, payload}`
  event to a `live_by_feature/1` map, so a console view re-points its live link
  without polling.
  """
  @spec apply_console_event(map(), :conversation_opened | :conversation_closed, map()) :: map()
  def apply_console_event(live, :conversation_opened, %{feature_id: fid, conversation_id: id}),
    do: Map.put(live, fid, id)

  def apply_console_event(live, :conversation_closed, %{conversation_id: id}),
    do: live |> Enum.reject(fn {_fid, cid} -> cid == id end) |> Map.new()

  def apply_console_event(live, _event, _payload), do: live

  # ── internals ──────────────────────────────────────────────────────────────

  # "<phase>-<ordinal>-<base36 stamp>"; the monotonic suffix keeps concurrent
  # and retried sessions from colliding without touching the store.
  defp new_id(%ConversationIdentity{phase: phase, ordinal: ordinal}) do
    stamp = System.os_time(:microsecond) |> Integer.to_string(36) |> String.downcase()
    uniq = System.unique_integer([:positive, :monotonic])
    "#{phase}-#{ordinal}-#{stamp}-#{uniq}"
  end

  defp broadcast_console(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @console_topic, {:console, event, payload})
  catch
    _, _ -> :ok
  end
end
