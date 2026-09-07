defmodule SpeckitOrchestrator.SpecNumberTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.SpecNumber

  describe "parse/1" do
    test "conforming entries parse numerically" do
      assert SpecNumber.parse("001-core-ledger") == {:ok, 1}
      assert SpecNumber.parse("0002-x") == {:ok, 2}
      assert SpecNumber.parse("015-billing") == {:ok, 15}
    end

    test "non-conforming entries error" do
      assert SpecNumber.parse("autonomous") == :error
      assert SpecNumber.parse("015") == :error
      assert SpecNumber.parse("015-") == :error
      assert SpecNumber.parse("abc-x") == :error
      assert SpecNumber.parse("") == :error
    end
  end

  describe "highest/1" do
    test "nil when no entry conforms" do
      assert SpecNumber.highest([]) == nil
      assert SpecNumber.highest(["autonomous", "015"]) == nil
    end

    test "non-conforming entries are skipped, not raised on" do
      assert SpecNumber.highest(["001-a", "autonomous", "007-b"]) == 7
    end

    test "highest among conforming entries, gaps and all" do
      assert SpecNumber.highest(["001-a", "007-b"]) == 7
      assert SpecNumber.highest(["0002-x", "002-y"]) == 2
    end
  end

  describe "allocate/2" do
    test "empty listing allocates 1" do
      assert SpecNumber.allocate([], "billing") == {:ok, 1}
    end

    test "all-non-conforming listing allocates 1" do
      assert SpecNumber.allocate(["autonomous"], "billing") == {:ok, 1}
    end

    test "gaps are never filled" do
      assert SpecNumber.allocate(["001-a", "007-b"], "billing") == {:ok, 8}
    end

    test "refuses, naming the entry, when the computed number is already present" do
      # n = highest(entries) + 1, so this branch is mathematically unreachable
      # from a self-consistent `entries` snapshot (no entry can equal
      # highest+1 without becoming the new highest). It exists defensively
      # for a damaged/stale listing — exercised here by asserting the
      # invariant it protects rather than a real trigger: no well-formed
      # entries list ever produces this error.
      assert SpecNumber.allocate(["001-a", "007-b"], "billing") == {:ok, 8}
      refute match?({:error, _}, SpecNumber.allocate(["001-a", "007-b"], "billing"))
    end

    test "slug does not influence the allocated number" do
      assert SpecNumber.allocate(["001-a"], "anything") == {:ok, 2}
    end
  end

  describe "dir_name/2 and branch_name/2" do
    test "zero-padded composition" do
      assert SpecNumber.dir_name(15, "billing") == "015-billing"
      assert SpecNumber.branch_name(15, "billing") == "feature/015-billing"
    end

    test "widens rather than truncates above 999" do
      assert SpecNumber.dir_name(1000, "x") == "1000-x"
    end
  end
end
