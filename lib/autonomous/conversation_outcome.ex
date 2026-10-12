defmodule Autonomous.ConversationOutcome do
  @moduledoc """
  Pure outcome vocabulary for a recorded conversation (feature 040, R5/R6).

  `from_result/1` classifies a folded `PhaseResult`; `encode/1` / `decode/1`
  move the term through the saved file as a string in the system's own
  vocabulary; `capture_status/1` maps a capture reason to the ref status.
  """

  alias Autonomous.PhaseResult

  @type t ::
          :completed
          | {:error, term()}
          | :exhausted
          | :deadline_exceeded
          | {:session_died, :start_failed | :ended_early}
          | {:backgrounded_command, list()}
          | :incomplete_session

  @spec from_result(PhaseResult.t() | nil) :: t()
  def from_result(nil), do: {:error, :no_result}

  def from_result(%PhaseResult{} = r) do
    cond do
      PhaseResult.deadline_exceeded?(r) ->
        :deadline_exceeded

      match?(%{kind: _}, PhaseResult.session_died(r)) ->
        {:session_died, PhaseResult.session_died(r).kind}

      PhaseResult.exhausted?(r) ->
        :exhausted

      r.status == :error ->
        {:error, r.error}

      r.status == :incomplete ->
        :incomplete_session

      PhaseResult.stranded_background(r) != [] ->
        {:backgrounded_command, PhaseResult.stranded_background(r)}

      PhaseResult.outstanding_work?(r) ->
        :incomplete_session

      true ->
        :completed
    end
  end

  @spec encode(t()) :: String.t()
  def encode(:completed), do: "completed"
  def encode(:exhausted), do: "exhausted"
  def encode(:deadline_exceeded), do: "deadline_exceeded"
  def encode(:incomplete_session), do: "incomplete_session"
  def encode({:backgrounded_command, _}), do: "backgrounded_command"
  def encode({:session_died, kind}), do: "session_died:#{kind}"
  def encode({:error, reason}) when is_binary(reason), do: "error:" <> reason
  def encode({:error, reason}), do: "error:" <> inspect(reason)

  @spec decode(String.t()) :: t()
  def decode("completed"), do: :completed
  def decode("exhausted"), do: :exhausted
  def decode("deadline_exceeded"), do: :deadline_exceeded
  def decode("incomplete_session"), do: :incomplete_session
  def decode("backgrounded_command"), do: {:backgrounded_command, []}
  def decode("session_died:start_failed"), do: {:session_died, :start_failed}
  def decode("session_died:ended_early"), do: {:session_died, :ended_early}
  def decode("error:" <> reason), do: {:error, reason}
  def decode(other) when is_binary(other), do: {:error, other}

  @doc """
  Ref status from a capture reason: `nil` ⇒ `:captured`; an open failure (no
  file ever existed) ⇒ `:not_captured`; any other reason ⇒ `:partial`.
  """
  @spec capture_status(term()) :: :captured | :partial | :not_captured
  def capture_status(nil), do: :captured
  def capture_status({:open_failed, _}), do: :not_captured
  def capture_status(_reason), do: :partial
end
