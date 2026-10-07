defmodule Autonomous.Web.RunSettingsViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.RunContext
  alias Autonomous.Web.RunSettingsView

  @full RunContext.to_map(%RunContext{
          budget_usd: 50.0,
          plan_stack: ["a", "b"],
          pr_base: "main",
          pr_remote: "origin",
          auto_remediation: true,
          auto_remediation_threshold: "high",
          auto_remediation_attempt_limit: 2,
          auto_remediation_model: "opus",
          auto_remediation_exhaustion_policy: "escalate",
          interactive_clarify: false,
          clarify_answer_timeout_s: 600,
          clarify_max_rounds: 3,
          containment_profile: "permissive"
        })

  test "emits only allowlisted keys and drops bookkeeping and containment_profile" do
    settings =
      Map.merge(@full, %{"__given__" => %{x: 1}, :__given__ => %{}, "__x" => 1, "other" => 2})

    keys = settings |> RunSettingsView.rows() |> Enum.map(&elem(&1, 0))

    refute "__given__" in keys
    refute "other" in keys
    refute "containment_profile" in keys
    assert "budget_usd" in keys
  end

  test "atom and string key forms collapse to one row, string wins" do
    rows = RunSettingsView.rows(%{"pr_base" => "main", pr_base: "develop"})
    assert rows == [{"pr_base", "main"}]
  end

  test "atom-keyed settings render" do
    assert RunSettingsView.rows(%{pr_base: "main"}) == [{"pr_base", "main"}]
  end

  test "order is stable (RunContext key order) and keys are unique" do
    keys = @full |> RunSettingsView.rows() |> Enum.map(&elem(&1, 0))

    assert keys ==
             RunContext.keys()
             |> Enum.map(&Atom.to_string/1)
             |> Enum.reject(&(&1 == "containment_profile"))

    assert keys == Enum.uniq(keys)
  end

  test "no value contains quoting artefacts" do
    for {_k, v} <- RunSettingsView.rows(@full), do: refute(v =~ ~r/"|%\{/)
  end

  test "budget renders as money" do
    assert {"budget_usd", "$50.00"} in RunSettingsView.rows(@full)
  end

  test "non-map settings yield no rows" do
    assert RunSettingsView.rows(nil) == []
  end

  describe "format_value/1" do
    test "scalars" do
      assert RunSettingsView.format_value("main") == "main"
      assert RunSettingsView.format_value(:high) == ":high"
      assert RunSettingsView.format_value(nil) == "—"
      assert RunSettingsView.format_value(3) == "3"
      assert RunSettingsView.format_value(1.5) == "1.5"
      assert RunSettingsView.format_value(true) == "true"
      assert RunSettingsView.format_value(false) == "false"
    end

    test "list is comma-joined" do
      assert RunSettingsView.format_value(["a", :b, 1]) == "a, :b, 1"
      assert RunSettingsView.format_value([]) == ""
    end

    test "map is sorted k=v without __ keys" do
      assert RunSettingsView.format_value(%{"__z" => 3, b: 2, a: "x", __given__: 1}) == "a=x b=2"
    end

    test "tuple and unrenderable terms never raise" do
      assert RunSettingsView.format_value({:ok, "x"}) == "{:ok, x}"
      assert RunSettingsView.format_value(self()) == "—"
    end
  end
end
