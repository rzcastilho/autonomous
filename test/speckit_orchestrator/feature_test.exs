defmodule SpeckitOrchestrator.FeatureTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Feature

  test "fresh feature defaults to :pending" do
    f = %Feature{id: "001", slug: "core", path: "x.md"}
    assert f.status == :pending
    assert f.prereqs == []
  end

  test "terminal_statuses are the four end states" do
    assert Enum.sort(Feature.terminal_statuses()) ==
             Enum.sort([:done, :escalated, :halted, :failed])
  end

  test "terminal?/1 on status atoms" do
    for s <- [:done, :escalated, :halted, :failed], do: assert(Feature.terminal?(s))
    for s <- [:pending, :running, :blocked], do: refute(Feature.terminal?(s))
  end

  test "terminal?/1 on a struct reads its status" do
    assert Feature.terminal?(%Feature{id: "1", slug: "s", path: "p", status: :done})
    refute Feature.terminal?(%Feature{id: "1", slug: "s", path: "p", status: :running})
  end
end
