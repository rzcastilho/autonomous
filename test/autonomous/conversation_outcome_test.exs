defmodule Autonomous.ConversationOutcomeTest do
  use ExUnit.Case, async: true

  alias Autonomous.{ConversationOutcome, PhaseResult}

  describe "from_result/1" do
    test "completed" do
      assert ConversationOutcome.from_result(%PhaseResult{status: :ok, final_text: "x"}) ==
               :completed
    end

    test "error, exhausted, deadline, session died, incomplete" do
      assert ConversationOutcome.from_result(%PhaseResult{status: :error, error: "boom"}) ==
               {:error, "boom"}

      assert ConversationOutcome.from_result(%PhaseResult{
               status: :error,
               subtype: "error_max_turns"
             }) ==
               :exhausted

      assert ConversationOutcome.from_result(PhaseResult.deadline_exceeded(%PhaseResult{}, 1000)) ==
               :deadline_exceeded

      assert ConversationOutcome.from_result(%PhaseResult{
               status: :error,
               error: {:session_died, :start_failed, "x"}
             }) == {:session_died, :start_failed}

      assert ConversationOutcome.from_result(%PhaseResult{status: :incomplete}) ==
               :incomplete_session

      assert ConversationOutcome.from_result(nil) == {:error, :no_result}
    end

    test "backgrounded command passes through" do
      r = %PhaseResult{
        status: :ok,
        tool_events: [
          %{
            kind: :call,
            payload: %{
              "name" => "Bash",
              "call_id" => "c1",
              "input" => %{"command" => "sleep 9", "run_in_background" => true}
            }
          },
          %{
            kind: :result,
            payload: %{
              "call_id" => "c1",
              "output" => "Command running in background with ID: b1",
              "is_error" => false
            }
          }
        ]
      }

      case PhaseResult.stranded_background(r) do
        [] -> assert ConversationOutcome.from_result(r) in [:completed, :incomplete_session]
        list -> assert ConversationOutcome.from_result(r) == {:backgrounded_command, list}
      end
    end
  end

  test "encode/decode round-trip" do
    for o <- [
          :completed,
          :exhausted,
          :deadline_exceeded,
          :incomplete_session,
          {:session_died, :start_failed},
          {:session_died, :ended_early},
          {:error, "boom"},
          {:backgrounded_command, []}
        ] do
      assert o |> ConversationOutcome.encode() |> ConversationOutcome.decode() == o
    end

    assert ConversationOutcome.encode({:session_died, :start_failed}) ==
             "session_died:start_failed"

    assert ConversationOutcome.encode({:error, :x}) == "error::x"
    assert ConversationOutcome.decode("weird") == {:error, "weird"}
  end

  test "capture_status/1" do
    assert ConversationOutcome.capture_status(nil) == :captured
    assert ConversationOutcome.capture_status({:open_failed, :eacces}) == :not_captured
    assert ConversationOutcome.capture_status(:recorder_down) == :partial
    assert ConversationOutcome.capture_status(:close_timeout) == :partial
    assert ConversationOutcome.capture_status({:write_failed, :enospc}) == :partial
  end
end
