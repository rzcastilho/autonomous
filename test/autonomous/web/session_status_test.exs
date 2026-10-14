defmodule Autonomous.Web.SessionStatusTest do
  use ExUnit.Case, async: true

  alias Autonomous.{ConversationEntry, ConversationFile}
  alias Autonomous.Web.SessionStatus

  @fixture "test/fixtures/conversations/042_sample.jsonl"

  defp e(seq, kind, body),
    do: %ConversationEntry{seq: seq, at: "2026-10-13T12:00:00Z", kind: kind, body: body}

  defp sys(seq, sub, data), do: e(seq, :system, %{"subtype" => sub, "data" => data})
  defp oth(seq, raw), do: e(seq, :other, %{"raw" => raw})

  defp call(seq, id, name),
    do: e(seq, :tool_call, %{"tool_use_id" => id, "name" => name, "input" => %{}})

  defp res(seq, id),
    do: e(seq, :tool_result, %{"tool_use_id" => id, "output" => "", "is_error" => false})

  defp fold(entries), do: SessionStatus.apply_all(SessionStatus.new(), entries)
  defp act(entries), do: entries |> fold() |> SessionStatus.activity_text()

  test "activity transitions" do
    assert act([sys(0, "status", %{"status" => "requesting"})]) == "requesting"

    assert act([sys(0, "thinking_tokens", %{"estimated_tokens" => 1200})]) ==
             "thinking · ~1.2k tok"

    assert act([sys(0, "thinking_tokens", %{"estimated_tokens" => 80})]) == "thinking · ~80 tok"

    assert act([sys(0, "hook_started", %{"hook_id" => "h", "hook_name" => "Pre"})]) ==
             "hook · Pre"

    assert act([e(0, :assistant_text, %{"text" => "x"})]) == "responding"
    assert act([call(0, "t", "Bash")]) == "running Bash"

    assert act([
             oth(0, %{
               "type" => "tool_progress",
               "tool_name" => "Bash",
               "elapsed_time_seconds" => 30
             })
           ]) == "running Bash · 30s"

    assert act([e(0, :result, %{"subtype" => "success", "num_turns" => 2})]) == "done"
    assert act([e(0, :end, %{"outcome" => "completed"})]) == "completed"
    assert SessionStatus.activity_text(SessionStatus.new()) == nil
  end

  test "thinking tokens: latest value, not accumulated" do
    s =
      fold([
        sys(0, "thinking_tokens", %{"estimated_tokens" => 100}),
        sys(1, "thinking_tokens", %{"estimated_tokens" => 150})
      ])

    assert s.activity == {:thinking, 150}
  end

  test "tool results close calls; activity follows the next open call" do
    s = fold([call(0, "a", "Bash"), call(1, "b", "Read"), res(2, "b")])
    assert s.tool_calls == 2
    assert s.open_calls == %{"a" => "Bash"}
    assert s.activity == {:running, "Bash", nil}

    s = fold([call(0, "a", "Bash"), res(1, "a")])
    assert s.open_calls == %{}
  end

  test "turn counting (R6)" do
    s =
      fold([
        e(0, :prompt, %{"text" => "go"}),
        e(1, :thinking, %{"text" => "", "message_id" => "m1"}),
        e(2, :assistant_text, %{"text" => "x", "message_id" => "m1"}),
        call(3, "a", "Bash"),
        call(4, "b", "Read"),
        res(5, "a"),
        res(6, "b"),
        call(7, "c", "Bash"),
        e(8, :assistant_text, %{"text" => "y", "message_id" => "m3"})
      ])

    # m1 (thinking + text + two parallel calls) is one turn; the call after the
    # results opens the second, and the text that follows belongs to it.
    assert s.turns == 2
  end

  test "a different message_id opens a new turn without a user entry" do
    s =
      fold([
        e(0, :assistant_text, %{"message_id" => "m1"}),
        e(1, :assistant_text, %{"message_id" => "m2"})
      ])

    assert s.turns == 2
  end

  test "result replaces the live turn count and sets cost and duration" do
    s = fold([e(0, :assistant_text, %{"message_id" => "m1"})])
    assert s.cost_usd == nil and s.duration_ms == nil

    s =
      SessionStatus.apply(
        s,
        e(1, :result, %{
          "subtype" => "success",
          "num_turns" => 7,
          "cost_usd" => 0.77,
          "duration_ms" => 716_000
        })
      )

    assert %{turns: 7, cost_usd: 0.77, duration_ms: 716_000} = s
  end

  test "open_tasks never goes below 0; open_hooks tracks started minus responded" do
    s =
      fold([
        sys(0, "task_notification", %{}),
        sys(1, "task_started", %{}),
        sys(2, "task_started", %{})
      ])

    assert s.open_tasks == 2
    s = SessionStatus.apply(s, sys(3, "task_notification", %{}))
    assert s.open_tasks == 1
    s = fold([sys(0, "task_notification", %{}), sys(1, "task_notification", %{})])
    assert s.open_tasks == 0

    s =
      fold([
        sys(0, "hook_started", %{"hook_id" => "h1"}),
        sys(1, "hook_started", %{"hook_id" => "h2"}),
        sys(2, "hook_response", %{"hook_id" => "h1"})
      ])

    assert MapSet.to_list(s.open_hooks) == ["h2"]
  end

  test "rate limit set, announce on onset, clear" do
    ev = fn seq, status ->
      oth(seq, %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => status,
          "rateLimitType" => "five_hour",
          "resetsAt" => 1_760_400_000
        }
      })
    end

    s = fold([ev.(0, "allowed")])
    assert s.rate_limit == nil and s.announce == nil

    s = SessionStatus.apply(s, ev.(1, "limited"))
    assert %{type: "five_hour", resets_at: 1_760_400_000} = s.rate_limit
    assert s.announce == "rate limited · five_hour"

    s = SessionStatus.apply(s, ev.(2, "limited"))
    assert s.announce == "rate limited · five_hour"

    s = SessionStatus.apply(s, ev.(3, "allowed"))
    assert s.rate_limit == nil
  end

  test "init feeds header fields; start feeds alias and started_at" do
    s =
      fold([
        e(0, :start, %{"model" => "opus"}),
        sys(1, "init", %{
          "model" => "claude-opus-4-8",
          "claude_code_version" => "2.1.100",
          "session_id" => "s1"
        })
      ])

    assert %{
             model_alias: "opus",
             model_resolved: "claude-opus-4-8",
             cli_version: "2.1.100",
             session_id: "s1",
             started_at: "2026-10-13T12:00:00Z"
           } = s
  end

  test "idempotent by seq" do
    en = call(0, "a", "Bash")
    once = SessionStatus.apply(SessionStatus.new(), en)
    assert SessionStatus.apply(once, en) == once
    assert once.tool_calls == 1
  end

  test "freezes after end" do
    s = fold([e(0, :start, %{}), e(1, :end, %{"outcome" => "deadline_exceeded"})])
    assert s.outcome == {"deadline exceeded", "failed"}
    frozen = s
    s = SessionStatus.apply(s, call(2, "x", "Bash"))
    assert %{activity: a, ended_at: ea, outcome: o} = s
    assert {a, ea, o} == {frozen.activity, frozen.ended_at, frozen.outcome}
    assert s.last_seq == 2
    assert s.tool_calls == 0
    assert s.announce == "deadline exceeded"
  end

  test "lower bound counters" do
    s = SessionStatus.mark_lower_bound(SessionStatus.new())
    assert s.lower_bound?
    assert SessionStatus.count_text(212, true) == "≥ 212"
    assert SessionStatus.count_text(212, false) == "212"
  end

  test "status_name" do
    assert SessionStatus.status_name(SessionStatus.new(), true) == "running"
    assert SessionStatus.status_name(SessionStatus.new(), false) == nil
    s = fold([e(0, :end, %{"outcome" => "completed"})])
    assert SessionStatus.status_name(s, true) == "done"
  end

  test "elapsed_s: live, frozen, nil" do
    now = ~U[2026-10-13 12:10:00Z]
    assert SessionStatus.elapsed_s(SessionStatus.new(), now) == nil

    s = %{SessionStatus.new() | started_at: "2026-10-13T12:00:00Z"}
    assert SessionStatus.elapsed_s(s, now) == 600
    assert SessionStatus.elapsed_s(s, ~U[2026-10-13 11:00:00Z]) == 0

    s = %{s | ended_at: "2026-10-13T12:05:00Z"}
    assert SessionStatus.elapsed_s(s, now) == 300

    assert SessionStatus.elapsed_s(%{s | started_at: "garbage"}, now) == nil
  end

  test "put_started_at only fills a missing start" do
    s = SessionStatus.put_started_at(SessionStatus.new(), "2026-10-13T12:00:00Z")
    assert s.started_at == "2026-10-13T12:00:00Z"
    assert SessionStatus.put_started_at(s, "other").started_at == "2026-10-13T12:00:00Z"
    assert SessionStatus.put_started_at(SessionStatus.new(), nil).started_at == nil
  end

  test "sample fixture: apply_all == incremental fold, and final figures" do
    {:ok, entries, :eof} = ConversationFile.page(@fixture, 0, 1_000)
    all = SessionStatus.apply_all(SessionStatus.new(), entries)

    inc =
      Enum.reduce(entries, SessionStatus.new(), fn en, acc -> SessionStatus.apply(acc, en) end)

    assert all == inc

    assert %{tool_calls: 8, open_tasks: 0, cost_usd: 0.77, turns: 3, rate_limit: nil} = all
    assert all.outcome == {"completed", "done"}
    assert all.model_resolved == "claude-opus-4-8"
    assert MapSet.size(all.open_hooks) == 0
    assert all.open_calls == %{}
  end
end
