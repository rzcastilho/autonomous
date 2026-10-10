defmodule Autonomous.ConversationWindowTest do
  use ExUnit.Case, async: true

  alias Autonomous.ConversationWindow, as: W

  test "empty window" do
    assert W.snapshot(W.new()) == {[], nil, false}
  end

  test "default cap is 500; push evicts oldest and counts dropped" do
    w = Enum.reduce(0..501, W.new(), &W.push(&2, %{seq: &1}))
    {entries, last, truncated?} = W.snapshot(w)
    assert length(entries) == 500
    assert hd(entries).seq == 2
    assert last == 501
    assert truncated?
    assert w.dropped == 2
  end

  test "small cap, no truncation until exceeded" do
    w = W.new(3) |> W.push(%{seq: 0}) |> W.push(%{seq: 1}) |> W.push(%{seq: 2})
    assert {[%{seq: 0}, %{seq: 1}, %{seq: 2}], 2, false} = W.snapshot(w)
    w = W.push(w, %{seq: 3})
    assert {[%{seq: 1}, %{seq: 2}, %{seq: 3}], 3, true} = W.snapshot(w)
  end

  test "fetch/2" do
    w = W.new(2) |> W.push(%{seq: 0}) |> W.push(%{seq: 1}) |> W.push(%{seq: 2})
    assert W.fetch(w, 0) == :not_in_window
    assert {:ok, %{seq: 2}} = W.fetch(w, 2)
  end
end
