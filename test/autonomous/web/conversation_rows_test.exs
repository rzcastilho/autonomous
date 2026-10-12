defmodule Autonomous.Web.ConversationRowsTest do
  use ExUnit.Case, async: true

  alias Autonomous.ConversationEntry
  alias Autonomous.Web.ConversationRows

  defp entry(seq, kind, body), do: %ConversationEntry{seq: seq, at: "t", kind: kind, body: body}

  defp call(seq, id, name \\ "Bash"),
    do:
      entry(seq, :tool_call, %{
        "tool_use_id" => id,
        "name" => name,
        "input" => %{"command" => "ls"}
      })

  defp result(seq, id, out, err? \\ false),
    do: entry(seq, :tool_result, %{"tool_use_id" => id, "output" => out, "is_error" => err?})

  test "one row per entry, in order, keyed by seq" do
    entries = [
      entry(1, :prompt, %{"text" => "go"}),
      entry(2, :assistant_text, %{"text" => "hi"}),
      entry(3, :system, %{"subtype" => "init", "data" => %{}})
    ]

    {rows, _ctx} = ConversationRows.rows(entries)
    assert Enum.map(rows, & &1.key) == ["entry-1", "entry-2", "entry-3"]
    assert Enum.map(rows, & &1.kind) == [:prompt, :assistant_text, :system]
  end

  test "a tool result is paired to its call by tool_use_id" do
    {rows, _} = ConversationRows.rows([call(1, "t1", "Grep"), result(2, "t1", "found")])
    assert [%{tool_name: "Grep"}, %{tool_name: "Grep", text: "found", error?: false}] = rows
  end

  test "result error flag is carried as is_error, not a status colour" do
    {[row], _} = ConversationRows.rows([result(1, "x", "boom", true)])
    assert row.error?
    assert row.chip == nil
  end

  test "a call with no result at :end is tagged unfinished (in the same batch)" do
    end_entry = entry(3, :end, %{"outcome" => "deadline_exceeded"})

    {rows, ctx} =
      ConversationRows.rows([call(1, "t1"), call(2, "t2"), result(2, "t2", "x"), end_entry])

    assert [%{unfinished?: true}, _, _, %{kind: :end}] = rows
    assert ctx.stale == []
  end

  test "streamed one by one, earlier unfinished calls come back in ctx.stale" do
    {_, ctx} = ConversationRows.rows([call(1, "t1")])
    {[end_row], ctx} = ConversationRows.rows([entry(2, :end, %{"outcome" => "completed"})], ctx)

    assert end_row.kind == :end
    assert [%{key: "entry-1", unfinished?: true}] = ctx.stale
  end

  test "long bodies are truncated at 40 lines with omitted counts; the entry is untouched" do
    text = Enum.map_join(1..100, "\n", &"line #{&1}")
    e = entry(1, :tool_result, %{"tool_use_id" => "a", "output" => text, "is_error" => false})

    {[row], _} = ConversationRows.rows([e])
    assert length(String.split(row.text, "\n")) == 40
    assert %{lines: 60, chars: chars} = row.omitted
    assert chars > 0
    assert e.body["output"] == text

    {[full], _} = ConversationRows.rows([e], ConversationRows.new(), expand: true)
    assert full.text == text
    assert full.omitted == nil
  end

  test "bodies over 4,000 chars are cut even when short in lines" do
    e = entry(1, :assistant_text, %{"text" => String.duplicate("x", 9_000)})
    {[row], _} = ConversationRows.rows([e])
    assert String.length(row.text) == 4_000
    assert %{chars: 5_000} = row.omitted
  end

  test "thinking rows are plain text (the component collapses them)" do
    {[row], _} = ConversationRows.rows([entry(1, :thinking, %{"text" => "hmm"})])
    assert row.kind == :thinking
    assert row.format == :plain
  end

  test "end marker carries the outcome rendered through Report, with a status name" do
    {[done], _} = ConversationRows.rows([entry(1, :end, %{"outcome" => "completed"})])
    assert done.outcome == "completed"
    assert done.chip == "done"

    {[cut], _} = ConversationRows.rows([entry(1, :end, %{"outcome" => "deadline_exceeded"})])
    assert cut.outcome == "deadline exceeded"
    assert cut.chip == "failed"

    {[died], _} =
      ConversationRows.rows([entry(1, :end, %{"outcome" => "session_died:start_failed"})])

    assert died.chip == "failed"
    refute died.outcome =~ "{"
  end

  test "an unknown entry kind renders as other with the whole body" do
    {[row], _} = ConversationRows.rows([entry(1, :other, %{"raw" => %{"a" => 1}})])
    assert row.label == "other"
    assert row.text =~ "\"a\": 1"
  end

  test "start, prompt, system and result rows" do
    {rows, _} =
      ConversationRows.rows([
        entry(0, :start, %{
          "run_id" => "r1",
          "feature_id" => "001",
          "phase" => "plan",
          "model" => nil
        }),
        entry(1, :prompt, %{"text" => "go"}),
        entry(2, :system, %{"subtype" => "init", "data" => %{"m" => 1}}),
        entry(3, :system, %{"data" => %{}}),
        entry(4, :result, %{"result" => "ok"})
      ])

    assert [start, prompt, sys, sys2, res] = rows
    assert start.text == "r1 · 001 · plan"
    assert prompt.text == "go"
    assert sys.label == "system · init"
    assert sys2.label == "system"
    assert res.label == "result"
  end

  test "tool output as blocks, nil, or other terms; id-less calls are not paired" do
    {[a, b, c, d, e], _} =
      ConversationRows.rows([
        result(1, "x", [%{"text" => "one"}, %{"k" => 1}]),
        result(2, "y", nil),
        result(3, "z", %{"k" => 2}),
        entry(4, :tool_call, %{"name" => "Bash", "input" => nil}),
        entry(5, :end, %{"outcome" => "completed"})
      ])

    assert a.text =~ "one"
    assert a.text =~ "\"k\": 1"
    assert b.text == ""
    assert c.text =~ "\"k\": 2"
    assert d.tool_use_id == nil
    assert e.chip == "done"
  end

  test "end chips: backgrounded and incomplete are blocked; expand renders whole; row/3" do
    {[a, b], _} =
      ConversationRows.rows([
        entry(1, :end, %{"outcome" => "incomplete_session"}),
        entry(2, :end, %{"outcome" => "deadline_exceeded"})
      ])

    assert a.chip == "blocked"
    assert b.chip == "failed"

    long = Enum.map_join(1..60, "\n", &"line #{&1}")
    e = entry(1, :assistant_text, %{"text" => long})
    assert ConversationRows.row(e, ConversationRows.new()).omitted
    refute ConversationRows.row(e, ConversationRows.new(), expand: true).omitted
    assert {_, nil} = ConversationRows.truncate("short")
  end
end
