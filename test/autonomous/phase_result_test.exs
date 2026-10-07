defmodule Autonomous.PhaseResultTest do
  use ExUnit.Case, async: true

  alias Jido.Harness.Event
  alias Autonomous.PhaseResult

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

  describe "backgrounded_commands/1 and stranded_background/1 (032)" do
    @timeout_marker "Command did not complete within its 600s timeout and was moved to the background (ID: b1). " <>
                      "Output is being written to: /tmp/x.out"

    defp bash(id, input \\ %{"command" => "mix test"}),
      do: ev(:tool_call, %{"name" => "Bash", "input" => input, "call_id" => id}, "s")

    defp out(id, text),
      do: ev(:tool_result, %{"output" => text, "call_id" => id, "is_error" => false}, "s")

    defp backgrounded_session(extra \\ [], opts \\ []) do
      session([bash("c1"), out("c1", @timeout_marker)] ++ extra, opts)
    end

    test "1: marker with nothing after it is stranded" do
      r = backgrounded_session()
      assert PhaseResult.stranded_background(r) == ["mix test"]

      assert [
               %PhaseResult.BackgroundedCommand{
                 mode: :timeout,
                 task_id: "b1",
                 output_path: "/tmp/x.out",
                 resolved?: false
               }
             ] =
               PhaseResult.backgrounded_commands(r)
    end

    test "2: a Read of the output path resolves it" do
      r =
        backgrounded_session([
          ev(
            :tool_call,
            %{"name" => "Read", "input" => %{"file_path" => "/tmp/x.out"}, "call_id" => "r1"},
            "s"
          ),
          out("r1", "all passed")
        ])

      assert PhaseResult.stranded_background(r) == []
    end

    test "3: any later event containing the task id resolves it" do
      r = backgrounded_session([call("m1", "Monitor"), out("m1", "watching b1")])
      assert PhaseResult.stranded_background(r) == []
    end

    test "4: unrelated later calls leave it stranded" do
      r =
        backgrounded_session([
          bash("c2", %{"command" => "ls"}),
          out("c2", "a b"),
          call("e1", "Edit"),
          out("e1", "ok")
        ])

      assert PhaseResult.stranded_background(r) == ["mix test"]
    end

    test "5: explicit run_in_background with marker, never read" do
      r =
        session([
          bash("c1", %{"command" => "sleep 5", "run_in_background" => true}),
          out(
            "c1",
            "Command running in background with ID: be1. Output is being written to: /tmp/e.out"
          )
        ])

      assert PhaseResult.stranded_background(r) == ["sleep 5"]
      assert [%{mode: :explicit, task_id: "be1"}] = PhaseResult.backgrounded_commands(r)
    end

    test "6: explicit call with no marker and no ids is stranded forever" do
      r =
        session([
          bash("c1", %{"command" => "sleep 5", "run_in_background" => true}),
          out("c1", "started"),
          call("x", "Read"),
          out("x", "started")
        ])

      assert PhaseResult.stranded_background(r) == ["sleep 5"]
      assert [%{task_id: nil, output_path: nil}] = PhaseResult.backgrounded_commands(r)
    end

    test "6b: explicit call that never returned a result is stranded" do
      r = session([bash("c1", %{"command" => "sleep 5", "run_in_background" => true})])
      assert PhaseResult.stranded_background(r) == ["sleep 5"]
    end

    test "7: the marker result never resolves itself" do
      # the marker text contains its own id and path
      assert PhaseResult.stranded_background(backgrounded_session()) == ["mix test"]
    end

    test "8: non-:ok sessions return []" do
      assert PhaseResult.stranded_background(backgrounded_session([], is_error: true)) == []

      incomplete = PhaseResult.reduce([bash("c1"), out("c1", @timeout_marker)])
      assert incomplete.status == :incomplete
      assert PhaseResult.stranded_background(incomplete) == []
      assert PhaseResult.stranded_background(nil) == []
    end

    test "9: sessions without backgrounding return []" do
      r = session([call("a", "Read"), result("a"), bash("b"), out("b", "12 tests, 0 failures")])
      assert PhaseResult.stranded_background(r) == []
      assert PhaseResult.backgrounded_commands(r) == []
      assert PhaseResult.stranded_background(session([])) == []
    end

    test "10: SC-001 replay fixture is stranded" do
      events =
        "../fixtures/sessions/background_wait_014.exs"
        |> Path.expand(__DIR__)
        |> Code.eval_file()
        |> elem(0)
        |> Enum.map(fn {type, payload} -> ev(type, payload, "3e935ca9") end)

      r = PhaseResult.reduce(events)
      assert r.status == :ok
      assert PhaseResult.stranded_background(r) == ["npm run test:e2e -- --reporter=line"]
      # the pre-032 gate saw every call return: no outstanding work
      refute PhaseResult.outstanding_work?(r)
    end

    test "reset_session_died/2 clears a stale death only when the new run has none" do
      died = %{kind: :start_failed, excerpt: "x"}

      assert PhaseResult.reset_session_died(%{}, %{session_died: died}) == %{session_died: nil}

      assert PhaseResult.reset_session_died(%{y: 1}, %{session_died: died}) == %{
               y: 1,
               session_died: nil
             }

      other = %{kind: :ended_early, excerpt: "z"}

      assert PhaseResult.reset_session_died(%{session_died: other}, %{session_died: died}) ==
               %{session_died: other}

      assert PhaseResult.reset_session_died(%{y: 1}, %{}) == %{y: 1}
      assert PhaseResult.reset_session_died(%{y: 1}, nil) == %{y: 1}
      assert PhaseResult.reset_session_died(%{y: 1}, %{session_died: nil}) == %{y: 1}
    end

    test "a reset signal survives the agent's deep merge and replaces the stale death" do
      died = %{kind: :start_failed, excerpt: "x"}
      reset = PhaseResult.reset_session_died(%{}, %{session_died: died})

      merged =
        Jido.Util.DeepMerge.merge(%{last_signals: %{session_died: died}}, %{last_signals: reset})

      assert merged.last_signals.session_died == nil
    end

    test "reset_background/2 clears a stale list only when the new run has none" do
      assert PhaseResult.reset_background(%{}, %{backgrounded: ["a"]}) == %{backgrounded: []}

      assert PhaseResult.reset_background(%{x: 1}, %{backgrounded: ["a"]}) == %{
               x: 1,
               backgrounded: []
             }

      assert PhaseResult.reset_background(%{backgrounded: ["b"]}, %{backgrounded: ["a"]}) == %{
               backgrounded: ["b"]
             }

      # runs that never backgrounded stay byte-identical
      assert PhaseResult.reset_background(%{x: 1}, %{}) == %{x: 1}
      assert PhaseResult.reset_background(%{x: 1}, nil) == %{x: 1}
      assert PhaseResult.reset_background(%{x: 1}, %{backgrounded: []}) == %{x: 1}
    end

    test "command falls back to description, then a placeholder" do
      r =
        session([
          bash("c1", %{"description" => "run e2e"}),
          out("c1", @timeout_marker),
          out("orphan", "Command was moved to the background (ID: b9)")
        ])

      assert PhaseResult.stranded_background(r) == ["run e2e", "(unknown command)"]
    end

    test "one entry per call even when matched by marker and explicit" do
      r =
        session([
          bash("c1", %{"command" => "x", "run_in_background" => true}),
          out("c1", "Command running in background with ID: be1")
        ])

      assert [%{mode: :explicit}] = PhaseResult.backgrounded_commands(r)
    end
  end
end
