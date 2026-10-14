defmodule Autonomous.Web.ConversationClassTest do
  use ExUnit.Case, async: true

  alias Autonomous.ConversationEntry, as: E
  alias Autonomous.Web.ConversationClass

  defp c(kind, body), do: ConversationClass.classify(E.new(kind, body))
  defp sys(sub, data \\ %{}), do: c(:system, %{"subtype" => sub, "data" => data})
  defp oth(type), do: c(:other, %{"raw" => %{"type" => type}})

  test "table rows" do
    assert %{placement: :row_signal, row_class: :divider, fold: :open} = c(:start, %{})
    assert %{placement: :row, row_class: :context, fold: :line} = c(:prompt, %{})
    assert %{placement: :row, row_class: :context, fold: :line} = oth("text")
    assert %{placement: :row_signal, row_class: :prose, fold: :open} = c(:assistant_text, %{})
    assert %{placement: :row_signal, row_class: :thinking, fold: :line} = c(:thinking, %{})
    assert %{placement: :row_signal, row_class: :call, fold: :line} = c(:tool_call, %{})
    assert %{placement: :row_signal, row_class: :result, fold: :preview5} = c(:tool_result, %{})
    assert %{placement: :row_signal, row_class: :end, fold: :open} = c(:end, %{})

    for s <- ~w(task_started task_notification api_retry) do
      assert %{placement: :row_signal, row_class: :marker, flag: nil} = sys(s)
    end

    assert %{placement: :row_signal, row_class: :marker, flag: :hook_failed} =
             sys("hook_response", %{"outcome" => "error", "exit_code" => 1})

    assert %{placement: :row_signal, flag: :hook_failed} =
             sys("hook_response", %{"outcome" => "success", "exit_code" => 2})

    assert %{placement: :signal, row_class: :raw} =
             sys("hook_response", %{"outcome" => "success", "exit_code" => 0})

    for s <- ~w(status thinking_tokens hook_started hook_progress) do
      assert %{placement: :signal, row_class: :raw} = sys(s)
    end

    assert %{placement: :header_signal} = sys("init")
    assert %{placement: :signal} = oth("tool_progress")
    assert %{placement: :signal} = oth("rate_limit_event")

    assert %{placement: :signal, row_class: :raw} = c(:result, %{"subtype" => "success"})

    assert %{placement: :row_signal, row_class: :marker, flag: :result_error} =
             c(:result, %{"subtype" => "success", "is_error" => true})

    assert %{placement: :row_signal, flag: :result_error} =
             c(:result, %{"subtype" => "error_max_turns"})
  end

  test "unknown kind and sub-kind are raw rows" do
    assert %{placement: :row, row_class: :raw, fold: :line, label: "system · mystery"} =
             sys("mystery")

    assert %{placement: :row, row_class: :raw, label: "other · weird"} = oth("weird")
    assert %{placement: :row, row_class: :raw, label: "system"} = c(:system, %{})

    decoded = E.decode(%{"seq" => 1, "kind" => "future_kind", "body" => %{"a" => 1}})

    assert %{placement: :row, row_class: :raw, label: "future_kind"} =
             ConversationClass.classify(decoded)
  end

  test "043 kinds: usage is a raw signal, stderr a quiet row, the dropped notice a marker" do
    assert %{placement: :signal, row_class: :raw, fold: :line, label: "usage · message_delta"} =
             c(:usage, %{"event" => "message_delta"})

    assert %{label: "usage"} = c(:usage, %{})

    assert %{placement: :row, row_class: :stderr, fold: :line, label: "stderr"} =
             c(:stderr, %{"line" => "warn"})

    assert %{placement: :row, row_class: :marker, fold: :line, label: "stderr"} =
             c(:stderr, %{"notice" => "dropped", "dropped" => 3})
  end

  test "completeness: every kind is a row or a signal" do
    for kind <- E.kinds() do
      assert %{placement: p} = c(kind, %{})
      assert p in [:row, :signal, :row_signal, :header_signal]
    end

    assert :usage in E.kinds() and :stderr in E.kinds()
  end

  test "total: never raises on odd bodies" do
    for kind <- E.kinds(), body <- [%{}, %{"subtype" => 1}, %{"raw" => "x"}, %{"data" => nil}] do
      assert %{placement: _} = c(kind, body)
    end
  end

  test "visible?/2" do
    for kind <- E.kinds() do
      assert ConversationClass.visible?(c(kind, %{}), true)
    end

    refute ConversationClass.visible?(sys("status"), false)
    assert ConversationClass.visible?(c(:prompt, %{}), false)
    refute ConversationClass.visible?(sys("init"), false)
  end

  test "sub_kind/1" do
    assert ConversationClass.sub_kind(E.new(:system, %{"subtype" => "init"})) == "init"
    assert ConversationClass.sub_kind(E.new(:other, %{"raw" => %{"type" => "text"}})) == "text"
    assert ConversationClass.sub_kind(E.new(:prompt, %{})) == nil
    assert ConversationClass.sub_kind(E.new(:other, %{})) == nil
  end
end
