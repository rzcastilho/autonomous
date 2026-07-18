defmodule SpeckitOrchestrator.PhaseResultTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Event
  alias SpeckitOrchestrator.PhaseResult

  defp ev(type, payload, session_id) do
    Event.new!(%{type: type, provider: :claude, session_id: session_id, payload: payload})
  end

  test "folds a full happy stream, preferring the completed result text" do
    events = [
      ev(:session_started, %{"tools" => []}, "sess-1"),
      ev(:output_text_delta, %{"text" => "partial "}, "sess-1"),
      ev(:thinking_delta, %{"text" => "hmm"}, "sess-1"),
      ev(:output_text_delta, %{"text" => "chunks"}, "sess-1"),
      ev(:tool_call, %{"name" => "Read", "input" => %{}, "call_id" => "t1"}, "sess-1"),
      ev(:tool_result, %{"output" => "ok", "call_id" => "t1", "is_error" => false}, "sess-1"),
      ev(:usage, %{"cost_usd" => 0.42, "input_tokens" => 10, "output_tokens" => 5}, "sess-1"),
      ev(:session_completed, %{"result" => "FINAL", "num_turns" => 3, "is_error" => false}, "sess-1")
    ]

    r = PhaseResult.reduce(events)

    assert r.final_text == "FINAL"
    assert r.session_id == "sess-1"
    assert r.cost_usd == 0.42
    assert r.usage["input_tokens"] == 10
    assert r.status == :ok
    assert r.num_turns == 3
    assert length(r.tool_events) == 2
    assert [%{kind: :call}, %{kind: :result}] = r.tool_events
    assert r.event_count == 8
  end

  test "falls back to concatenated deltas when no completed result text" do
    events = [
      ev(:output_text_delta, %{"text" => "a"}, "s"),
      ev(:output_text_delta, %{"text" => "b"}, "s"),
      ev(:session_completed, %{"result" => nil, "is_error" => false}, "s")
    ]

    assert PhaseResult.reduce(events).final_text == "ab"
  end

  test "session_failed yields an error status with the error payload" do
    events = [ev(:session_failed, %{"error" => "boom", "subtype" => "error"}, "s")]
    r = PhaseResult.reduce(events)
    assert r.status == :error
    assert r.error == "boom"
  end

  test "completed with is_error true is an error" do
    events = [ev(:session_completed, %{"result" => "bad", "is_error" => true}, "s")]
    r = PhaseResult.reduce(events)
    assert r.status == :error
    assert r.error == "bad"
  end

  test "empty stream is incomplete with empty text" do
    r = PhaseResult.reduce([])
    assert r.status == :incomplete
    assert r.final_text == ""
    assert r.cost_usd == nil
    assert r.event_count == 0
  end

  test "captures session id from the first event that carries one" do
    events = [ev(:output_text_delta, %{"text" => "x"}, nil), ev(:session_started, %{}, "late")]
    assert PhaseResult.reduce(events).session_id == "late"
  end

  test "consumes a lazy stream (adapter-agnostic)" do
    stream = Stream.map(["a", "b", "c"], &ev(:output_text_delta, %{"text" => &1}, "s"))
    assert PhaseResult.reduce(stream).final_text == "abc"
  end

  describe "transient?/1" do
    test "harness-level nil (no stream returned) is transient" do
      assert PhaseResult.transient?(nil)
    end

    test "an incomplete stream (no terminal event) is transient" do
      assert PhaseResult.transient?(%PhaseResult{status: :incomplete})
    end

    test "an :error carrying a server/API drop signature is transient" do
      assert PhaseResult.transient?(%PhaseResult{
               status: :error,
               final_text: "API Error: Server error mid-response. The response above may be incomplete."
             })

      assert PhaseResult.transient?(%PhaseResult{status: :error, error: "upstream 503 unavailable"})
      assert PhaseResult.transient?(%PhaseResult{status: :error, final_text: "model overloaded, try later"})
    end

    test "a clean application :error is NOT transient" do
      refute PhaseResult.transient?(%PhaseResult{
               status: :error,
               final_text: "no such file: lib/foo.ex"
             })
    end

    test "a successful result is never transient" do
      refute PhaseResult.transient?(%PhaseResult{status: :ok, final_text: "done"})
    end
  end
end
