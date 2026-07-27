defmodule SpeckitOrchestrator.SeverityTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Severity

  describe "values/0" do
    test "the four severities in ascending order" do
      assert Severity.values() == [:low, :medium, :high, :critical]
    end
  end

  describe "rank/1" do
    test "total order — each severity outranks the one before it" do
      ranks = Enum.map(Severity.values(), &Severity.rank/1)
      assert ranks == [1, 2, 3, 4]
      assert ranks == Enum.sort(ranks)
    end

    test ":unknown has no rank" do
      assert Severity.rank(:unknown) == nil
    end
  end

  describe "parse/1" do
    test "accepts atoms already in the vocabulary" do
      assert Severity.parse(:high) == {:ok, :high}
    end

    test "accepts strings, case-insensitively" do
      assert Severity.parse("High") == {:ok, :high}
      assert Severity.parse("high") == {:ok, :high}
      assert Severity.parse("HIGH") == {:ok, :high}
    end

    test "\"blocker\" is a case-insensitive synonym for :critical" do
      assert Severity.parse("blocker") == {:ok, :critical}
      assert Severity.parse("BLOCKER") == {:ok, :critical}
      assert Severity.parse("Blocker") == {:ok, :critical}
    end

    test "unrecognized strings/atoms return :error, never raise" do
      assert Severity.parse("severe") == :error
      assert Severity.parse(:unknown) == :error
      assert Severity.parse("") == :error
    end

    test "non-string/non-atom input returns :error" do
      assert Severity.parse(nil) == :error
      assert Severity.parse(42) == :error
    end

    test "never calls String.to_atom/1 on unrecognized input (no atom-table growth)" do
      assert Severity.parse("totally-unrecognized-#{System.unique_integer([:positive])}") ==
               :error
    end
  end

  describe "parse_finding/1" do
    test "reads the \"severity\" key" do
      assert Severity.parse_finding(%{"severity" => "critical"}) == :critical
    end

    test "absent severity key is :unknown" do
      assert Severity.parse_finding(%{"title" => "no severity here"}) == :unknown
    end

    test "unparseable severity value is :unknown, not dropped" do
      assert Severity.parse_finding(%{"severity" => "severe"}) == :unknown
    end
  end

  describe "at_or_above?/2 — inclusive floor (FR-001a)" do
    test "critical threshold matches only critical" do
      assert Severity.at_or_above?(:critical, :critical)
      refute Severity.at_or_above?(:high, :critical)
    end

    test "high threshold matches high and critical" do
      assert Severity.at_or_above?(:high, :high)
      assert Severity.at_or_above?(:critical, :high)
      refute Severity.at_or_above?(:medium, :high)
    end

    test "medium threshold matches medium, high, critical" do
      assert Severity.at_or_above?(:medium, :medium)
      assert Severity.at_or_above?(:high, :medium)
      assert Severity.at_or_above?(:critical, :medium)
      refute Severity.at_or_above?(:low, :medium)
    end

    test "low threshold matches everything recognized" do
      for s <- Severity.values(), do: assert(Severity.at_or_above?(s, :low))
    end

    test "reflexive at every level" do
      for s <- Severity.values(), do: assert(Severity.at_or_above?(s, s))
    end

    test "unknown matches no threshold, including :low (research R3)" do
      for threshold <- Severity.values() do
        refute Severity.at_or_above?(:unknown, threshold)
      end
    end
  end

  describe "max/1" do
    test "empty enumerable is nil" do
      assert Severity.max([]) == nil
    end

    test "picks the highest recognized severity" do
      assert Severity.max([:low, :high, :medium]) == :high
    end

    test "ignores :unknown entries when a recognized one is present" do
      assert Severity.max([:unknown, :low, :unknown]) == :low
    end

    test "all-unknown, non-empty enumerable is :unknown" do
      assert Severity.max([:unknown, :unknown]) == :unknown
    end
  end
end
