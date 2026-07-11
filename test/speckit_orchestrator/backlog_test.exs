defmodule SpeckitOrchestrator.BacklogTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Backlog

  @dir Path.expand("../fixtures/breakdown", __DIR__)
  @cyclic Path.expand("../fixtures/breakdown_cyclic", __DIR__)
  @missing Path.expand("../fixtures/breakdown_missing", __DIR__)

  describe "load!/1 over the LedgerLite fixtures" do
    setup do
      %{features: Backlog.load!(@dir)}
    end

    test "parses all seven features, sorted by id, README ignored", %{features: features} do
      assert Enum.map(features, & &1.id) == ~w(001 002 003 004 005 006 007)
    end

    test "reconstructs the expected dependency DAG", %{features: features} do
      by_id = Map.new(features, &{&1.id, &1})
      assert by_id["001"].prereqs == []
      assert by_id["002"].prereqs == ["001"]
      assert by_id["003"].prereqs == ["002"]
      assert by_id["004"].prereqs == ["002"]
      assert by_id["005"].prereqs == ["001"]
      assert by_id["006"].prereqs == ["002"]
      assert by_id["007"].prereqs == ["001"]
    end

    test "features load as :pending with slug and path", %{features: features} do
      f = Enum.find(features, &(&1.id == "001"))
      assert f.slug == "core-ledger"
      assert f.status == :pending
      assert String.ends_with?(f.path, "001-core-ledger.md")
    end

    test "dependents/1 maps reverse edges", %{features: features} do
      deps = Backlog.dependents(features)
      assert Enum.sort(deps["001"]) == ["002", "005", "007"]
      assert Enum.sort(deps["002"]) == ["003", "004", "006"]
      refute Map.has_key?(deps, "003")
    end
  end

  test "load!/1 raises CycleError on a cyclic backlog" do
    assert_raise Backlog.CycleError, ~r/cycle/, fn -> Backlog.load!(@cyclic) end
  end

  test "load!/1 raises MissingPrereqError on a dangling prereq" do
    assert_raise Backlog.MissingPrereqError, ~r/999/, fn -> Backlog.load!(@missing) end
  end

  test "load!/1 raises ParseError on an unreadable dir" do
    assert_raise Backlog.ParseError, fn -> Backlog.load!(Path.join(@dir, "nope")) end
  end

  describe "extract_prereqs/1" do
    test "None means no prerequisites" do
      assert Backlog.extract_prereqs("## Prerequisites\n\nNone\n") == []
    end

    test "no section means no prerequisites" do
      assert Backlog.extract_prereqs("# Title\n\nSome body 123 text\n") == []
    end

    test "reads ids only from the Prerequisites section" do
      content = """
      # 500 Title with a number

      ## Prerequisites

      - 001 Core
      - 042 Other

      ## Notes

      Ignore 999 out here.
      """

      assert Backlog.extract_prereqs(content) == ["001", "042"]
    end

    test "dedupes repeated ids and is case-insensitive on the heading" do
      content = "### prerequisites\n\n- 001\n- 001\n"
      assert Backlog.extract_prereqs(content) == ["001"]
    end
  end
end
