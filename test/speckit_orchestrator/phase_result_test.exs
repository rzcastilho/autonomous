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
      ev(
        :session_completed,
        %{"result" => "FINAL", "num_turns" => 3, "is_error" => false},
        "sess-1"
      )
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
    assert r.subtype == "error"
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
               final_text:
                 "API Error: Server error mid-response. The response above may be incomplete."
             })

      assert PhaseResult.transient?(%PhaseResult{
               status: :error,
               error: "upstream 503 unavailable"
             })

      assert PhaseResult.transient?(%PhaseResult{
               status: :error,
               final_text: "model overloaded, try later"
             })
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

  describe "exhausted?/1" do
    test "a session_failed with subtype error_max_turns folds to exhausted? true" do
      events = [ev(:session_failed, %{"error" => "boom", "subtype" => "error_max_turns"}, "s")]
      r = PhaseResult.reduce(events)
      assert PhaseResult.exhausted?(r)
    end

    test "a server-error subtype is not exhausted, and transient?/1 is unaffected" do
      events = [
        ev(
          :session_failed,
          %{"error" => "API Error: Server error mid-response.", "subtype" => "error"},
          "s"
        )
      ]

      r = PhaseResult.reduce(events)
      refute PhaseResult.exhausted?(r)
      assert PhaseResult.transient?(r)
    end

    test "a clean application error is neither exhausted nor transient" do
      r = %PhaseResult{status: :error, error: "no such file", subtype: "error"}
      refute PhaseResult.exhausted?(r)
      refute PhaseResult.transient?(r)
    end

    test "a successful result is not exhausted" do
      refute PhaseResult.exhausted?(%PhaseResult{status: :ok, subtype: nil})
    end

    test "nil (harness-level error) is not exhausted" do
      refute PhaseResult.exhausted?(nil)
    end
  end

  describe "outstanding_work?/1" do
    defp session(tool_events, opts \\ []) do
      completed =
        ev(
          :session_completed,
          %{
            "result" => "done",
            "num_turns" => 2,
            "is_error" => Keyword.get(opts, :is_error, false)
          },
          "s"
        )

      terminal = Keyword.get(opts, :terminal, completed)
      PhaseResult.reduce(tool_events ++ [terminal])
    end

    defp call(id, name \\ "Task"),
      do: ev(:tool_call, %{"name" => name, "input" => %{}, "call_id" => id}, "s")

    defp result(id),
      do: ev(:tool_result, %{"output" => "ok", "call_id" => id, "is_error" => false}, "s")

    test "flags an :ok session that stranded calls, and names them" do
      r =
        session([
          call("a", "Read"),
          result("a"),
          call("b", "Grep"),
          result("b"),
          call("c", "Read"),
          result("c"),
          call("d", "Task"),
          call("e", "Agent")
        ])

      assert PhaseResult.outstanding_work?(r)
      assert PhaseResult.outstanding_calls(r) == ["Task", "Agent"]
    end

    test "does not flag a session whose calls all returned" do
      r = session([call("a"), result("a"), call("b"), result("b")])

      refute PhaseResult.outstanding_work?(r)
      assert PhaseResult.outstanding_calls(r) == []
    end

    test "does not flag when no result ever arrived — the transport guard" do
      r = session([call("a"), call("b"), call("c")])

      refute PhaseResult.outstanding_work?(r)
    end

    test "does not flag a session with no tool events at all" do
      refute PhaseResult.outstanding_work?(session([]))
    end

    test "does not flag a non-:ok session, leaving exhaustion and transience distinct" do
      stranded = [call("a"), result("a"), call("b")]

      failed =
        session(stranded,
          terminal: ev(:session_failed, %{"error" => "boom", "subtype" => "error_max_turns"}, "s")
        )

      assert failed.status == :error
      assert PhaseResult.exhausted?(failed)
      refute PhaseResult.outstanding_work?(failed)

      errored = session(stranded, is_error: true)
      assert errored.status == :error
      refute PhaseResult.outstanding_work?(errored)

      incomplete = PhaseResult.reduce(stranded)
      assert incomplete.status == :incomplete
      assert PhaseResult.transient?(incomplete)
      refute PhaseResult.outstanding_work?(incomplete)
    end

    test "ignores events carrying no call_id rather than counting them stranded" do
      r =
        session([
          call("a"),
          result("a"),
          ev(:tool_call, %{"name" => "Bash", "input" => %{}}, "s")
        ])

      refute PhaseResult.outstanding_work?(r)
    end

    test "nil is never outstanding" do
      refute PhaseResult.outstanding_work?(nil)
      assert PhaseResult.outstanding_calls(nil) == []
    end
  end
end
