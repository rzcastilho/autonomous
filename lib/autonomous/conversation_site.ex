defmodule Autonomous.ConversationSite do
  @moduledoc """
  Shared glue for the session-driving sites (feature 040): build the
  `ConversationIdentity` from the agent's state, open a recorder before the
  harness request, and close it after the stream fold on every outcome.

  Capture never changes a session: with no store-backed run (`run_key` or
  `layout` absent) nothing is opened and the request is untouched.
  """

  alias Autonomous.{Conversation, ConversationIdentity, PhaseResult}
  alias Autonomous.Store.Records.ConversationRef

  @type capture :: {:ok, map()} | {:not_captured, ConversationRef.t() | nil}

  @doc """
  Identity for one session of `phase`, or `nil` when the run is not
  store-backed / has no layout. Options: `:kind`, `:ordinal` (default 1),
  `:chunk`, `:attempt`.
  """
  @spec identity(map(), atom(), keyword()) :: ConversationIdentity.t() | nil
  def identity(
        %{run_key: {repo_id, run_id}, layout: %{transcript_root: root}, feature: feature},
        phase,
        opts
      )
      when is_binary(root) do
    %ConversationIdentity{
      repo_id: repo_id,
      run_id: run_id,
      feature_id: feature.id,
      phase: phase,
      ordinal: Keyword.get(opts, :ordinal, 1),
      kind: Keyword.get(opts, :kind, :phase),
      chunk: Keyword.get(opts, :chunk),
      attempt: Keyword.get(opts, :attempt),
      transcript_root: root
    }
  end

  def identity(_state, _phase, _opts), do: nil

  @doc "Open a recorder for `identity`; the request comes back unchanged on any failure."
  @spec open(ConversationIdentity.t() | nil, struct()) :: {capture(), struct()}
  def open(identity, request) do
    case Conversation.open(identity, request) do
      {:ok, handle, request} -> {{:ok, handle}, request}
      {:not_captured, ref, request} -> {{:not_captured, ref}, request}
    end
  end

  @doc """
  Run `fun` (the stream fold) and close the capture with its `PhaseResult`.
  Returns `{result, refs}`. An exception still closes the capture before it
  propagates.
  """
  @spec reduce(capture(), (-> PhaseResult.t())) :: {PhaseResult.t(), [ConversationRef.t()]}
  def reduce(capture, fun) do
    result =
      try do
        fun.()
      catch
        kind, reason ->
          _ = close(capture, nil)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    {result, close(capture, result)}
  end

  @doc "Close `capture`; `[]` when nothing was opened."
  @spec close(capture(), PhaseResult.t() | nil) :: [ConversationRef.t()]
  def close({:ok, handle}, result), do: List.wrap(Conversation.close(handle, result))
  def close({:not_captured, ref}, _result), do: List.wrap(ref)

  @doc "Close after a request that never produced a stream."
  @spec close_error(capture(), term()) :: [ConversationRef.t()]
  def close_error(capture, reason),
    do: close(capture, %PhaseResult{status: :error, error: reason})
end
