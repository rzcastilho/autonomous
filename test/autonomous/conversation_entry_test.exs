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

  test "stream_event produces nothing; unknown type keeps the whole raw" do
    assert E.from_frame(frame(:stream_event, %{"type" => "stream_event"})) == []
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
    assert %E{kind: :end} = E.new(:end, %{})
    assert [%E{kind: :other, body: %{"raw" => [1, "a", "pid"]}}] = E.from_frame([1, :a, "pid"])
  end
end
