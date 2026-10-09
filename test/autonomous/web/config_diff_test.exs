defmodule Autonomous.Web.ConfigDiffTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.ConfigDiff

  @applied %{
    "model_plan" => "sonnet",
    "model_clarify" => "opus",
    "pr_base" => "main",
    "pr_remote" => "origin"
  }

  test "039: there is no budget parsing left" do
    Code.ensure_loaded!(ConfigDiff)
    refute function_exported?(ConfigDiff, :parse_cents, 1)
  end

  describe "diff/2" do
    test "omits fields equal to the applied value" do
      edited = %{@applied | "model_plan" => "sonnet"}
      assert ConfigDiff.diff(@applied, edited) == %{}
    end

    test "reports changed fields as {old, new}" do
      edited = %{@applied | "model_plan" => "opus", "pr_remote" => "upstream"}

      assert ConfigDiff.diff(@applied, edited) == %{
               "model_plan" => {"sonnet", "opus"},
               "pr_remote" => {"origin", "upstream"}
             }
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
      changes = %{"model_plan" => {"sonnet", "opus"}, "pr_base" => {"main", "release"}}

      assert ConfigDiff.apply_echo(changes, nil) ==
               [~s|LiveConfig.apply(%{model_plan: "opus", pr_base: "release"})|]
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
