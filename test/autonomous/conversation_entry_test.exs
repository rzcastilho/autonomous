defmodule Autonomous.ConversationEntryTest do
  use ExUnit.Case, async: true

  alias Autonomous.ConversationEntry, as: E
  alias ClaudeAgentSDK.Message

  defp frame(type, raw, subtype \\ nil),
    do: %Message{type: type, subtype: subtype, data: %{}, raw: raw}

  test "system frame" do
    [e] =
      E.from_frame(
        frame(:system, %{"type" => "system", "subtype" => "init", "model" => "m"}, :init)
      )

    assert e.kind == :system
    assert e.body == %{"subtype" => "init", "data" => %{"model" => "m"}}
  end

  test "assistant frame with N blocks yields N entries" do
    raw = %{
      "type" => "assistant",
      "message" => %{
        "id" => "msg_1",
        "content" => [
          %{"type" => "thinking", "thinking" => "hmm"},
          %{"type" => "text", "text" => "hello"},
          %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "Bash",
            "input" => %{"command" => "ls"}
          }
        ]
      }
    }

    assert [t, a, c] = E.from_frame(frame(:assistant, raw))
    assert {t.kind, t.body["text"]} == {:thinking, "hmm"}
    assert {a.kind, a.body} == {:assistant_text, %{"text" => "hello", "message_id" => "msg_1"}}
    assert c.kind == :tool_call

    assert c.body == %{
             "tool_use_id" => "toolu_1",
             "name" => "Bash",
             "input" => %{"command" => "ls"}
           }
  end

  test "user tool_result" do
    raw = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "toolu_1",
            "content" => "out",
            "is_error" => true
          }
        ]
      }
    }

    assert [e] = E.from_frame(frame(:user, raw))
    assert e.kind == :tool_result
    assert e.body == %{"tool_use_id" => "toolu_1", "output" => "out", "is_error" => true}
  end

  test "result frame" do
    raw = %{
      "type" => "result",
      "subtype" => "success",
      "result" => "done",
      "num_turns" => 3,
      "duration_ms" => 10,
      "total_cost_usd" => 0.5
    }

    [e] = E.from_frame(frame(:result, raw, :success))
    assert e.kind == :result
    assert e.body["cost_usd"] == 0.5
    assert e.body["is_error"] == false
  end

  describe "result error rule (043 R1)" do
    defp result_frame(data, raw, subtype),
      do: %Message{type: :result, subtype: subtype, data: data, raw: raw}

    test "synthetic error result records is_error and the error text verbatim" do
      [e] =
        E.from_frame(
          result_frame(%{is_error: true, error: "CLI exited 1"}, %{}, :error_during_execution)
        )

      assert e.body["is_error"] == true
      assert e.body["error"] == "CLI exited 1"
      assert e.body["subtype"] == "error_during_execution"
    end

    test "blank or absent error text is recorded as nil, never invented" do
      for data <- [
            %{is_error: true, error: ""},
            %{is_error: true, error: "  "},
            %{is_error: true}
          ] do
        [e] = E.from_frame(result_frame(data, %{}, :error_during_execution))
        assert e.body["is_error"] == true
        assert Map.has_key?(e.body, "error")
        assert e.body["error"] == nil
      end
    end

    test "raw error text is the fallback when data has none" do
      [e] =
        E.from_frame(
          result_frame(%{is_error: true}, %{"error" => "from raw"}, :error_during_execution)
        )

      assert e.body["error"] == "from raw"
    end

    test "a genuine success body is byte-identical to before: no error key" do
      raw = %{
        "subtype" => "success",
        "result" => "ok",
        "num_turns" => 1,
        "duration_ms" => 5,
        "total_cost_usd" => 0.1,
        "is_error" => false
      }

      [e] = E.from_frame(result_frame(%{is_error: false}, raw, :success))

      assert e.body == %{
               "subtype" => "success",
               "result" => "ok",
               "num_turns" => 1,
               "duration_ms" => 5,
               "cost_usd" => 0.1,
               "is_error" => false
             }
    end

    test "a genuine error subtype with raw is_error absent is still an error" do
      raw = %{"subtype" => "error_max_turns"}
      [e] = E.from_frame(result_frame(%{is_error: true}, raw, :error_max_turns))
      assert e.body["is_error"] == true
    end
  end

  test "stream_event without usage produces nothing; unknown type keeps the whole raw" do
    assert E.from_frame(frame(:stream_event, %{"type" => "stream_event"})) == []

    assert E.from_frame(
             frame(:stream_event, %{
               "event" => %{"type" => "content_block_delta", "delta" => %{"text" => "x"}}
             })
           ) == []

    [e] = E.from_frame(frame(:rate_limit_event, %{"type" => "rate_limit_event", "x" => 1}))
    assert e.kind == :other
    assert e.body == %{"raw" => %{"type" => "rate_limit_event", "x" => 1}}
    assert [%E{kind: :other}] = E.from_frame(:garbage)
  end

  test "assistant with unknown block and plain-string content lose nothing" do
    [e] = E.from_frame(frame(:assistant, %{"message" => %{"content" => [%{"type" => "image"}]}}))
    assert e.kind == :other
    [e] = E.from_frame(frame(:assistant, %{"message" => %{"content" => "plain"}}))
    assert e.kind == :assistant_text
  end

  test "encode/decode round-trip incl. unknown kind" do
    e = %E{seq: 4, at: "2026-10-10T00:00:00Z", kind: :tool_call, body: %{"name" => "Bash"}}
    assert e |> E.encode() |> Jason.encode!() |> Jason.decode!() |> E.decode() == e

    d = E.decode(%{"seq" => 1, "at" => "x", "kind" => "future_kind", "body" => %{"a" => 1}})
    assert d.kind == :other
    assert d.body["raw"] == %{"a" => 1}
  end

  test "frames without raw fall back to the frame struct; subtype taken from the frame" do
    [e] = E.from_frame(frame(:system, %{}, :init))
    assert e.body["subtype"] == "init"
    [e] = E.from_frame(frame(:result, %{}, nil))
    assert e.body["subtype"] == nil
    [e] = E.from_frame(%Message{type: :weird, subtype: :x, data: %{a: {1, 2}}, raw: nil})
    assert e.kind == :other
    assert e.body["raw"]["type"] == "weird"
    assert e.body["raw"]["data"]["a"] == "{1, 2}"
  end

  test "assistant without usable content and user with non-list content become :other" do
    assert [%E{kind: :other}] = E.from_frame(frame(:assistant, %{"message" => %{}}))
    assert [%E{kind: :other}] = E.from_frame(frame(:user, %{"message" => %{"content" => "x"}}))

    assert [%E{kind: :other}] =
             E.from_frame(frame(:user, %{"message" => %{"content" => [%{"type" => "text"}]}}))
  end

  test "thinking falls back to text; tool_use without input gets an empty map" do
    raw = %{
      "message" => %{
        "content" => [
          %{"type" => "thinking", "text" => "t"},
          %{"type" => "thinking"},
          %{"type" => "tool_use", "id" => "i", "name" => "Read"}
        ]
      }
    }

    assert [a, b, c] = E.from_frame(frame(:assistant, raw))
    assert a.body["text"] == "t"
    assert b.body["text"] == ""
    assert c.body["input"] == %{}
  end

  test "jsonable renders atoms, lists, structs and opaque terms" do
    [e] = E.from_frame(%Message{type: :odd, subtype: nil, data: %{}, raw: nil})
    assert Jason.encode!(e.body)
    assert E.kinds() |> Enum.member?(:end)
    assert :usage in E.kinds() and :stderr in E.kinds()
    assert %E{kind: :end} = E.new(:end, %{})
    assert [%E{kind: :other, body: %{"raw" => [1, "a", "pid"]}}] = E.from_frame([1, :a, "pid"])
  end

  describe "stderr entries (feature 043)" do
    test "stderr/1 carries the line" do
      e = E.stderr("warn: slow")
      assert {e.kind, e.body} == {:stderr, %{"line" => "warn: slow"}}
    end

    test "stderr_dropped/1 carries the dropped count" do
      e = E.stderr_dropped(98_000)
      assert {e.kind, e.body} == {:stderr, %{"notice" => "dropped", "dropped" => 98_000}}
    end
  end

  describe "usage entries (feature 043)" do
    defp stream(event, extra \\ %{}),
      do: frame(:stream_event, Map.merge(%{"type" => "stream_event", "event" => event}, extra))

    test "message_start records only the integer fields present" do
      event = %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "usage" => %{
            "input_tokens" => 1200,
            "output_tokens" => 1,
            "cache_read_input_tokens" => 4000
          }
        }
      }

      assert [e] = E.from_frame(stream(event))
      assert e.kind == :usage

      assert e.body == %{
               "event" => "message_start",
               "message_id" => "msg_1",
               "input_tokens" => 1200,
               "output_tokens" => 1,
               "cache_read_input_tokens" => 4000
             }
    end

    test "message_delta records the cumulative output; absent is never 0" do
      event = %{"type" => "message_delta", "usage" => %{"output_tokens" => 300}}
      assert [e] = E.from_frame(stream(event))
      assert e.body == %{"event" => "message_delta", "output_tokens" => 300}
    end

    test "non-integer usage values are ignored" do
      event = %{
        "type" => "message_delta",
        "usage" => %{"output_tokens" => "x", "input_tokens" => 5}
      }

      assert [e] = E.from_frame(stream(event))
      assert e.body == %{"event" => "message_delta", "input_tokens" => 5}
    end

    test "usage carries the scope when the frame has a parent_tool_use_id" do
      event = %{"type" => "message_delta", "usage" => %{"output_tokens" => 3}}
      [e] = E.from_frame(stream(event, %{"parent_tool_use_id" => "toolu_sub1"}))
      assert e.body["parent_tool_use_id"] == "toolu_sub1"
    end

    test "event is read from the parsed data when raw is empty" do
      f = %Message{
        type: :stream_event,
        data: %{
          event: %{"type" => "message_delta", "usage" => %{"output_tokens" => 7}},
          parent_tool_use_id: "toolu_x"
        },
        raw: %{}
      }

      assert [e] = E.from_frame(f)
      assert e.body["output_tokens"] == 7
      assert e.body["parent_tool_use_id"] == "toolu_x"
    end
  end

  describe "parent_tool_use_id (feature 043)" do
    test "kept on every entry kind built from assistant/user frames" do
      sub = %{"parent_tool_use_id" => "toolu_sub1"}

      assistant =
        Map.merge(sub, %{
          "message" => %{
            "id" => "m",
            "content" => [
              %{"type" => "text", "text" => "a"},
              %{"type" => "thinking", "thinking" => "t"},
              %{"type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => %{}},
              %{"type" => "image"}
            ]
          }
        })

      user =
        Map.merge(sub, %{
          "message" => %{
            "content" => [
              %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "ok"},
              %{"type" => "text", "text" => "ctx"}
            ]
          }
        })

      entries = E.from_frame(frame(:assistant, assistant)) ++ E.from_frame(frame(:user, user))

      assert Enum.map(entries, & &1.kind) ==
               [:assistant_text, :thinking, :tool_call, :other, :tool_result, :other]

      assert Enum.all?(entries, &(&1.body["parent_tool_use_id"] == "toolu_sub1"))
    end

    test "absent (no key) when nil, empty or missing" do
      for pid <- [nil, "", :missing] do
        raw =
          %{"message" => %{"id" => "m", "content" => [%{"type" => "text", "text" => "a"}]}}
          |> then(&if(pid == :missing, do: &1, else: Map.put(&1, "parent_tool_use_id", pid)))

        assert [e] = E.from_frame(frame(:assistant, raw))
        refute Map.has_key?(e.body, "parent_tool_use_id")
      end
    end
  end
end
