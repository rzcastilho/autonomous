defmodule Autonomous.Web.ConversationRowsTest do
  use ExUnit.Case, async: true

  alias Autonomous.{ConversationEntry, ConversationFile}
  alias Autonomous.Web.ConversationRows

  @fixture "test/fixtures/conversations/042_sample.jsonl"

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

  defp sample do
    {:ok, entries, :eof} = ConversationFile.page(@fixture, 0, 1_000)
    entries
  end

  defp stream_blocks(entries, opts) do
    {blocks, _ctx} =
      Enum.reduce(entries, {[], ConversationRows.new(opts)}, fn e, {acc, ctx} ->
        {rows, ctx} = ConversationRows.rows([e], ctx)
        {acc ++ rows ++ ctx.stale, ctx}
      end)

    blocks
  end

  defp final_by_key(blocks), do: Map.new(blocks, &{&1.key, &1})

  test "blocks are keyed by the opening entry's seq, in order; signals are hidden" do
    entries = [
      entry(1, :prompt, %{"text" => "go"}),
      entry(2, :assistant_text, %{"text" => "hi"}),
      entry(3, :system, %{"subtype" => "init", "data" => %{}}),
      entry(4, :system, %{"subtype" => "status", "data" => %{}})
    ]

    {rows, _ctx} = ConversationRows.rows(entries)
    assert Enum.map(rows, & &1.key) == ["entry-1", "entry-2"]
    assert Enum.map(rows, & &1.class) == [:context, :prose]
  end

  test "a result is grouped inside its call block, which is re-emitted under the same key" do
    {[c1], ctx} = ConversationRows.rows([call(1, "t1", "Grep")])
    assert c1.result == nil
    assert c1.summary == "Grep"

    {[paired], _} = ConversationRows.rows([result(2, "t1", "found")], ctx)
    assert paired.key == c1.key
    assert %{preview: "found", more_lines: 0, error?: false, seq: 2} = paired.result
  end

  test "within one batch a call and its result collapse to one block" do
    {rows, _} = ConversationRows.rows([call(1, "t1"), result(2, "t1", "x")])
    assert [%{key: "entry-1", result: %{preview: "x"}}] = rows
  end

  test "parallel calls keep call order even when results arrive out of order" do
    entries = [call(1, "a"), call(2, "b"), result(3, "b", "rb"), result(4, "a", "ra")]
    {rows, _} = ConversationRows.rows(entries)
    assert Enum.map(rows, & &1.key) == ["entry-1", "entry-2"]
    assert Enum.map(rows, & &1.result.preview) == ["ra", "rb"]
  end

  test "result preview is five lines with a +N count; error flag, not a status colour" do
    out = Enum.map_join(1..40, "\n", &"line #{&1}")
    {[b], _} = ConversationRows.rows([call(1, "t"), result(2, "t", out, true)])
    assert b.result.preview == Enum.map_join(1..5, "\n", &"line #{&1}")
    assert b.result.more_lines == 35
    assert b.result.error?
    assert b.flag == :is_error
    assert b.chip == nil
  end

  test "an orphan result is a standalone block with the tool name when known" do
    {[b], _} = ConversationRows.rows([result(5, "gone", "late", true)])
    assert %{class: :result, key: "entry-5", flag: :is_error, tool_name: nil} = b
    assert b.result.preview == "late"
  end

  test "expand/2 of a result seq returns the owning call block with the full result" do
    out = Enum.map_join(1..40, "\n", &"line #{&1}")
    r = result(2, "t", out)
    {_, ctx} = ConversationRows.rows([call(1, "t"), r])
    block = ConversationRows.expand(r, ctx)
    assert block.key == "entry-1"
    assert block.result.full == out
  end

  test "expand/2 of an orphan result and of another entry" do
    r = result(5, "gone", "late\nmore")

    assert %{class: :result, result: %{full: "late\nmore"}} =
             ConversationRows.expand(r, ConversationRows.new())

    long = Enum.map_join(1..60, "\n", &"line #{&1}")
    e = entry(1, :assistant_text, %{"text" => long})
    block = ConversationRows.expand(e, ConversationRows.new())
    assert block.omitted == nil
    assert block.body == long
  end

  test "hidden entries still advance pairing" do
    entries = [
      call(1, "t1"),
      entry(2, :system, %{"subtype" => "hook_started", "data" => %{}}),
      result(3, "t1", "ok")
    ]

    {rows, _} = ConversationRows.rows(entries)
    assert [%{result: %{preview: "ok"}}] = rows
  end

  test "a call with no result at :end is tagged unfinished (same batch)" do
    end_entry = entry(4, :end, %{"outcome" => "deadline_exceeded"})

    {rows, ctx} =
      ConversationRows.rows([call(1, "t1"), call(2, "t2"), result(3, "t2", "x"), end_entry])

    assert [%{unfinished?: true}, %{unfinished?: false}, %{class: :end}] = rows
    assert ctx.stale == []
  end

  test "streamed one by one, earlier unfinished calls come back in ctx.stale" do
    {_, ctx} = ConversationRows.rows([call(1, "t1")])
    {[end_row], ctx} = ConversationRows.rows([entry(2, :end, %{"outcome" => "completed"})], ctx)

    assert end_row.class == :end
    assert [%{key: "entry-1", unfinished?: true}] = ctx.stale
  end

  test "a late result pairs normally and clears unfinished" do
    {_, ctx} = ConversationRows.rows([call(1, "t1"), entry(2, :end, %{"outcome" => "completed"})])
    {[b], _} = ConversationRows.rows([result(3, "t1", "x")], ctx)
    assert b.result.preview == "x"
    refute b.unfinished?
  end

  test "long bodies are truncated at 40 lines with omitted counts; the entry is untouched" do
    text = Enum.map_join(1..100, "\n", &"line #{&1}")
    e = entry(1, :assistant_text, %{"text" => text})

    {[row], _} = ConversationRows.rows([e])
    assert length(String.split(row.body, "\n")) == 40
    assert %{lines: 60, chars: chars} = row.omitted
    assert chars > 0
    assert e.body["text"] == text

    {[full], _} = ConversationRows.rows([e], ConversationRows.new(), expand: true)
    assert full.body == text
    assert full.omitted == nil
  end

  test "bodies over 4,000 chars are cut even when short in lines" do
    e = entry(1, :assistant_text, %{"text" => String.duplicate("x", 9_000)})
    {[row], _} = ConversationRows.rows([e])
    assert String.length(row.body) == 4_000
    assert %{chars: 5_000} = row.omitted
    assert {_, nil} = ConversationRows.truncate("short")
  end

  test "thinking: plain, first line as summary; prompt likewise" do
    {[t, p], _} =
      ConversationRows.rows([
        entry(1, :thinking, %{"text" => "hmm\nmore"}),
        entry(2, :prompt, %{"text" => "go\nnow"})
      ])

    assert %{class: :thinking, format: :plain, summary: "hmm"} = t
    assert %{class: :context, summary: "go"} = p
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

    {[a, b], _} =
      ConversationRows.rows([
        entry(1, :end, %{"outcome" => "incomplete_session"}),
        entry(2, :end, %{"outcome" => "backgrounded_command"})
      ])

    assert a.chip == "blocked"
    assert b.chip == "blocked"
  end

  test "unknown entry renders as a raw block with the whole body" do
    {[row], _} = ConversationRows.rows([entry(1, :other, %{"raw" => %{"a" => 1}})])
    assert %{class: :raw, label: "other"} = row
    assert row.body =~ "\"a\": 1"
  end

  test "start renders a divider with the model alias" do
    {[d], _} =
      ConversationRows.rows([
        entry(0, :start, %{
          "run_id" => "r1",
          "feature_id" => "001",
          "phase" => "plan",
          "model" => "opus"
        })
      ])

    assert %{class: :divider, summary: "session opened · opus", body: "r1 · 001 · plan · opus"} =
             d

    {[d2], _} = ConversationRows.rows([entry(0, :start, %{"model" => nil})])
    assert d2.summary == "session opened"
  end

  test "marker summaries" do
    entries = [
      entry(1, :system, %{"subtype" => "task_started", "data" => %{"description" => "suite"}}),
      entry(2, :system, %{
        "subtype" => "task_notification",
        "data" => %{"status" => "completed", "summary" => "green"}
      }),
      entry(3, :system, %{
        "subtype" => "api_retry",
        "data" => %{
          "attempt" => 1,
          "max_retries" => 3,
          "error" => "busy",
          "retry_delay_ms" => 500
        }
      }),
      entry(4, :system, %{
        "subtype" => "hook_response",
        "data" => %{"hook_name" => "Pre", "outcome" => "error", "exit_code" => 1}
      }),
      entry(5, :result, %{"subtype" => "error_max_turns"})
    ]

    {rows, _} = ConversationRows.rows(entries)

    assert Enum.map(rows, & &1.summary) == [
             "task started · suite",
             "task completed · green",
             "api_retry · attempt 1/3 · busy · 500 ms",
             "hook_response · Pre · exit 1",
             "result · error_max_turns"
           ]

    assert Enum.map(rows, & &1.flag) == [nil, nil, nil, :hook_failed, :result_error]
  end

  test "injected text is a context block" do
    {[b], _} =
      ConversationRows.rows([
        entry(1, :other, %{"raw" => %{"type" => "text", "text" => "skill\nbody"}})
      ])

    assert %{class: :context, label: "context", summary: "skill", body: "skill\nbody"} = b
  end

  test "tool output as blocks, nil, or other terms" do
    {[a, b, c], _} =
      ConversationRows.rows([
        result(1, "x", [%{"text" => "one"}, %{"k" => 1}]),
        result(2, "y", nil),
        result(3, "z", %{"k" => 2})
      ])

    assert a.result.preview =~ "one"
    assert a.result.preview =~ "\"k\": 1"
    assert b.result.preview == ""
    assert c.result.preview =~ "\"k\": 2"
  end

  describe "sample fixture" do
    test "stream equivalence: batch == one at a time" do
      entries = sample()
      {batch, _} = ConversationRows.rows(entries)
      assert final_by_key(batch) == final_by_key(stream_blocks(entries, []))
      assert Enum.map(batch, & &1.key) == Enum.uniq(Enum.map(batch, & &1.key))
    end

    test "SC-002: all_frames shows every entry, results folded into their calls" do
      entries = sample()
      {blocks, _} = ConversationRows.rows(entries, ConversationRows.new(all_frames: true))
      results = Enum.count(entries, &(&1.kind == :tool_result))
      assert length(Enum.uniq_by(blocks, & &1.key)) == length(entries) - results
    end

    test "default view has far fewer blocks than entries, none for pure progress" do
      entries = sample()
      {blocks, _} = ConversationRows.rows(entries)
      assert length(blocks) < length(entries)
      refute Enum.any?(blocks, &(&1.class == :raw))
      assert Enum.any?(blocks, &(&1.flag == :hook_failed))
      assert Enum.all?(Enum.filter(blocks, &(&1.class == :call)), & &1.result)
    end
  end

  describe "result marker error text (043)" do
    defp res_entry(seq, body),
      do:
        entry(
          seq,
          :result,
          Map.merge(%{"subtype" => "error_during_execution", "is_error" => true}, body)
        )

    test "an error result appends its error text" do
      {[b], _} = ConversationRows.rows([res_entry(1, %{"error" => "CLI exited 1"})])
      assert b.summary == "result · error_during_execution — CLI exited 1"
      assert b.flag == :result_error
    end

    test "a nil error reads no reason given" do
      {[b], _} = ConversationRows.rows([res_entry(1, %{"error" => nil})])
      assert b.summary == "result · error_during_execution — no reason given"
    end

    test "a success marker is unchanged" do
      {rows, _} =
        ConversationRows.rows([
          entry(1, :result, %{"subtype" => "error_max_turns", "is_error" => false})
        ])

      assert [%{summary: "result · error_max_turns"}] = rows
    end
  end

  describe "stderr rows (043)" do
    defp err(seq, line), do: entry(seq, :stderr, %{"line" => line})

    test "consecutive identical lines collapse into one block with a repeat count" do
      {rows, _} = ConversationRows.rows([err(1, "warn"), err(2, "warn"), err(3, "warn")])
      assert [b] = rows

      assert {b.class, b.repeat, b.seqs, b.body, b.label} ==
               {:stderr, 3, [1, 2, 3], "warn", "stderr"}

      assert b.key == "entry-1"
    end

    test "a different visible entry in between ends the run" do
      {rows, _} =
        ConversationRows.rows([
          err(1, "warn"),
          err(2, "other"),
          err(3, "warn"),
          entry(4, :assistant_text, %{"text" => "hi"}),
          err(5, "warn")
        ])

      assert Enum.map(rows, &{&1.class, &1.repeat}) ==
               [stderr: 1, stderr: 1, stderr: 1, prose: 1, stderr: 1]
    end

    test "hidden signal entries do not break a run" do
      {rows, _} =
        ConversationRows.rows([
          err(1, "warn"),
          entry(2, :usage, %{"event" => "message_delta", "output_tokens" => 5}),
          err(3, "warn")
        ])

      assert [%{repeat: 2, seqs: [1, 3]}] = rows
    end

    test "streaming one entry at a time collapses under the same key" do
      blocks = stream_blocks([err(1, "warn"), err(2, "warn"), err(3, "warn")], [])

      assert [%{key: "entry-1", repeat: 3, seqs: [1, 2, 3]}] =
               Enum.uniq_by(Enum.reverse(blocks), & &1.key)
    end

    test "the dropped notice renders its count" do
      {[b], _} =
        ConversationRows.rows([entry(1, :stderr, %{"notice" => "dropped", "dropped" => 98_000})])

      assert b.class == :marker
      assert b.summary == "stderr · 98000 lines dropped"
    end

    test "show-all-frames leaves stderr rows unchanged" do
      entries = [err(1, "warn"), err(2, "warn")]
      {default, _} = ConversationRows.rows(entries)
      {all, _} = ConversationRows.rows(entries, ConversationRows.new(all_frames: true))
      assert default == all
    end
  end

  describe "parent_tool_use_id (043)" do
    test "renders identically with or without the recorded id" do
      plain = [
        entry(1, :assistant_text, %{"text" => "a", "message_id" => "m"}),
        call(2, "t1"),
        result(3, "t1", "ok")
      ]

      tagged =
        Enum.map(plain, &%{&1 | body: Map.put(&1.body, "parent_tool_use_id", "toolu_sub1")})

      assert ConversationRows.rows(plain) == ConversationRows.rows(tagged)
    end
  end
end
