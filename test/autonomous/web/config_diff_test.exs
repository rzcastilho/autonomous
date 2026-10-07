defmodule Autonomous.Web.ConfigDiffTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.ConfigDiff

  @applied %{
    "model_plan" => "sonnet",
    "model_clarify" => "opus",
    "budget_usd" => 50.0,
    "pr_base" => "main",
    "pr_remote" => "origin"
  }

  describe "parse_cents/1" do
    test "accepts whole, one-decimal and two-decimal amounts" do
      assert ConfigDiff.parse_cents("12") == {:ok, 1200}
      assert ConfigDiff.parse_cents("12.3") == {:ok, 1230}
      assert ConfigDiff.parse_cents("12.34") == {:ok, 1234}
      assert ConfigDiff.parse_cents("0") == {:ok, 0}
    end

    test "refuses more than two decimals, negatives and non-numbers" do
      assert ConfigDiff.parse_cents("12.345") == :invalid
      assert ConfigDiff.parse_cents("-1") == :invalid
      assert ConfigDiff.parse_cents("abc") == :invalid
      assert ConfigDiff.parse_cents("") == :invalid
      assert ConfigDiff.parse_cents("1e3") == :invalid
      assert ConfigDiff.parse_cents(nil) == :invalid
    end

    test "accepts an applied number" do
      assert ConfigDiff.parse_cents(50.0) == {:ok, 5000}
      assert ConfigDiff.parse_cents(42.5) == {:ok, 4250}
    end
  end

  describe "diff/2" do
    test "omits fields equal after normalization" do
      edited = %{@applied | "budget_usd" => "50.00", "model_plan" => "sonnet"}
      assert ConfigDiff.diff(@applied, edited) == %{}
    end

    test "reports changed fields as {old, new}" do
      edited = %{@applied | "model_plan" => "opus", "budget_usd" => "12.34"}

      assert ConfigDiff.diff(@applied, edited) == %{
               "model_plan" => {"sonnet", "opus"},
               "budget_usd" => {50.0, 12.34}
             }
    end

    test "keeps an unparseable budget as the raw edited text" do
      edited = %{@applied | "budget_usd" => "12.345"}
      assert ConfigDiff.diff(@applied, edited) == %{"budget_usd" => {50.0, "12.345"}}
    end

    test "ignores fields absent from edited" do
      assert ConfigDiff.diff(@applied, %{"pr_base" => "release"}) ==
               %{"pr_base" => {"main", "release"}}
    end
  end

  test "dirty?/1 is true iff there are changes" do
    refute ConfigDiff.dirty?(%{})
    assert ConfigDiff.dirty?(%{"pr_base" => {"main", "release"}})
  end

  describe "apply_echo/2" do
    test "line 1 lists only the changed keys, in key order" do
      changes = %{"model_plan" => {"sonnet", "opus"}, "budget_usd" => {50.0, 12.34}}

      assert ConfigDiff.apply_echo(changes, nil) ==
               [~s|LiveConfig.apply(%{budget_usd: 12.34, model_plan: "opus"})|]
    end

    test "line 2 only with an active run" do
      changes = %{"pr_base" => {"main", "release"}}

      assert ConfigDiff.apply_echo(changes, "r000007") == [
               ~s|LiveConfig.apply(%{pr_base: "release"})|,
               "applies forward-only to r000007 · not saved as default"
             ]
    end
  end
end
