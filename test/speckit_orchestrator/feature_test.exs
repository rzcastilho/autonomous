defmodule SpeckitOrchestrator.FeatureTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Feature

  test "fresh feature defaults to :pending" do
    f = %Feature{id: "001", number: 1, slug: "core", path: "x.md"}
    assert f.status == :pending
    assert f.group == :backlog
    assert f.created_at == nil
  end

  test "terminal_statuses are the four end states" do
    assert Enum.sort(Feature.terminal_statuses()) ==
             Enum.sort([:done, :escalated, :halted, :failed])
  end

  test "terminal?/1 on status atoms" do
    for s <- [:done, :escalated, :halted, :failed], do: assert(Feature.terminal?(s))
    for s <- [:pending, :running], do: refute(Feature.terminal?(s))
  end

  test "terminal?/1 on a struct reads its status" do
    assert Feature.terminal?(%Feature{id: "1", number: 1, slug: "s", path: "p", status: :done})
    refute Feature.terminal?(%Feature{id: "1", number: 1, slug: "s", path: "p", status: :running})
  end

  describe "spec_id/1" do
    test "falls back to id when spec_number is nil" do
      f = %Feature{id: "001", number: 1, slug: "core", path: "x.md"}
      assert Feature.spec_id(f) == "001"
    end

    test "zero-pads spec_number when allocated" do
      f = %Feature{id: "001", number: 1, slug: "core", path: "x.md", spec_number: 15}
      assert Feature.spec_id(f) == "015"
    end
  end

  describe "spec_label/1" do
    test "nil when unallocated" do
      f = %Feature{id: "001", number: 1, slug: "core", path: "x.md"}
      assert Feature.spec_label(f) == nil
    end

    test "zero-pads spec_number when allocated" do
      f = %Feature{id: "001", number: 1, slug: "core", path: "x.md", spec_number: 7}
      assert Feature.spec_label(f) == "007"
    end
  end
end
