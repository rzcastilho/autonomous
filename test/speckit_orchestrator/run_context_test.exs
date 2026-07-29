defmodule SpeckitOrchestrator.RunContextTest do
  # async: false — mutates global Config app env for the Config-fallback cases.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.RunContext

  @config_keys [
    :budget_usd,
    :plan_stack,
    :pr_base,
    :pr_remote,
    :auto_remediation,
    :auto_remediation_threshold,
    :auto_remediation_attempt_limit,
    :auto_remediation_model
  ]

  setup do
    prev = for k <- @config_keys, do: {k, Application.get_env(:speckit_orchestrator, k)}

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:speckit_orchestrator, k, v),
          else: Application.delete_env(:speckit_orchestrator, k)
      end
    end)

    :ok
  end

  describe "capture/1" do
    test "resolves each field from opts when present" do
      opts = [
        budget_usd: 7.5,
        plan_stack: ["a", "b"],
        pr_base: "develop",
        pr_remote: "upstream",
        auto_remediation: false,
        auto_remediation_threshold: :critical,
        auto_remediation_attempt_limit: 3,
        auto_remediation_model: "opus"
      ]

      assert RunContext.capture(opts) == %RunContext{
               budget_usd: 7.5,
               plan_stack: ["a", "b"],
               pr_base: "develop",
               pr_remote: "upstream",
               auto_remediation: false,
               auto_remediation_threshold: "critical",
               auto_remediation_attempt_limit: 3,
               auto_remediation_model: "opus"
             }
    end

    test "falls back to live Config when opts is absent/empty" do
      Application.put_env(:speckit_orchestrator, :budget_usd, 12.0)
      Application.put_env(:speckit_orchestrator, :plan_stack, ["x"])
      Application.put_env(:speckit_orchestrator, :pr_base, "trunk")
      Application.put_env(:speckit_orchestrator, :pr_remote, "origin2")
      Application.put_env(:speckit_orchestrator, :auto_remediation, false)
      Application.put_env(:speckit_orchestrator, :auto_remediation_threshold, :medium)
      Application.put_env(:speckit_orchestrator, :auto_remediation_attempt_limit, 4)
      Application.put_env(:speckit_orchestrator, :auto_remediation_model, "sonnet")

      assert RunContext.capture([]) == %RunContext{
               budget_usd: 12.0,
               plan_stack: ["x"],
               pr_base: "trunk",
               pr_remote: "origin2",
               auto_remediation: false,
               auto_remediation_threshold: "medium",
               auto_remediation_attempt_limit: 4,
               auto_remediation_model: "sonnet"
             }
    end

    test "resolves each field independently — opts-present for one, Config-fallback for the rest" do
      Application.put_env(:speckit_orchestrator, :pr_base, "trunk")

      ctx = RunContext.capture(pr_remote: "upstream")
      assert ctx.pr_remote == "upstream"
      assert ctx.pr_base == "trunk"
    end

    test "defaults (no opts, no Config override) resolve auto_remediation on with threshold \"high\"" do
      ctx = RunContext.capture([])
      assert ctx.auto_remediation == true
      assert ctx.auto_remediation_threshold == "high"
      assert ctx.auto_remediation_attempt_limit == 2
      assert ctx.auto_remediation_model == nil
    end

    test "auto_remediation_threshold is always stored as a string, never an atom" do
      assert RunContext.capture(auto_remediation_threshold: :low).auto_remediation_threshold ==
               "low"

      assert RunContext.capture(auto_remediation_threshold: "low").auto_remediation_threshold ==
               "low"
    end
  end

  describe "to_map/1" do
    test "produces a JSON-ready string-keyed map of exactly the eight settings" do
      ctx = %RunContext{
        budget_usd: 25.0,
        plan_stack: ["research", "plan"],
        pr_base: "main",
        pr_remote: "origin",
        auto_remediation: true,
        auto_remediation_threshold: "high",
        auto_remediation_attempt_limit: 2,
        auto_remediation_model: nil
      }

      assert RunContext.to_map(ctx) == %{
               "budget_usd" => 25.0,
               "plan_stack" => ["research", "plan"],
               "pr_base" => "main",
               "pr_remote" => "origin",
               "auto_remediation" => true,
               "auto_remediation_threshold" => "high",
               "auto_remediation_attempt_limit" => 2,
               "auto_remediation_model" => nil
             }
    end

    test "map keys are exactly the eight settings, nothing else" do
      map = RunContext.to_map(%RunContext{})

      assert Map.keys(map) |> Enum.sort() ==
               Enum.sort([
                 "budget_usd",
                 "plan_stack",
                 "pr_base",
                 "pr_remote",
                 "auto_remediation",
                 "auto_remediation_threshold",
                 "auto_remediation_attempt_limit",
                 "auto_remediation_model"
               ])
    end
  end

  describe "from_map/1" do
    test "nil returns an all-nil struct" do
      assert RunContext.from_map(nil) == %RunContext{}
    end

    test "empty map returns an all-nil struct" do
      assert RunContext.from_map(%{}) == %RunContext{}
    end

    test "partial map populates only present keys, leaving the rest nil" do
      assert RunContext.from_map(%{"pr_base" => "trunk", "budget_usd" => 10.0}) ==
               %RunContext{pr_base: "trunk", budget_usd: 10.0}
    end

    test "never raises on an unexpected/extra key" do
      assert RunContext.from_map(%{"pr_base" => "trunk", "unexpected" => "ignored"}) ==
               %RunContext{pr_base: "trunk"}
    end

    test "round-trips the four auto-remediation fields through to_map/from_map" do
      ctx = %RunContext{
        auto_remediation: false,
        auto_remediation_threshold: "critical",
        auto_remediation_attempt_limit: 5,
        auto_remediation_model: "opus"
      }

      assert ctx |> RunContext.to_map() |> RunContext.from_map() == ctx
    end
  end

  describe "merge/2" do
    test "an opts-supplied key always wins over recorded" do
      recorded = %RunContext{pr_base: "trunk"}
      {merged, fell_back} = RunContext.merge([pr_base: "develop"], recorded)

      assert Keyword.get(merged, :pr_base) == "develop"
      refute :pr_base in fell_back
    end

    test "a recorded non-nil value is injected into merged_opts when opts lacks the key" do
      recorded = %RunContext{budget_usd: 4.0}
      {merged, fell_back} = RunContext.merge([], recorded)

      assert Keyword.get(merged, :budget_usd) == 4.0
      refute :budget_usd in fell_back
    end

    test "a key present in neither is left absent and reported in fell_back_keys" do
      {merged, fell_back} = RunContext.merge([], %RunContext{})

      assert Keyword.fetch(merged, :pr_base) == :error
      assert :pr_base in fell_back
      assert length(fell_back) == 8
    end

    test "explicit opt > recorded > absent precedence holds for the auto-remediation fields too" do
      recorded = %RunContext{
        auto_remediation: false,
        auto_remediation_threshold: "critical",
        auto_remediation_attempt_limit: 4
      }

      {merged, fell_back} = RunContext.merge([auto_remediation: true], recorded)

      assert Keyword.get(merged, :auto_remediation) == true
      assert Keyword.get(merged, :auto_remediation_threshold) == "critical"
      assert Keyword.get(merged, :auto_remediation_attempt_limit) == 4
      assert Keyword.fetch(merged, :auto_remediation_model) == :error
      assert :auto_remediation_model in fell_back
    end

    test "result is independent of opts vs recorded argument precedence order" do
      opts = [budget_usd: 3.0]
      recorded = %RunContext{budget_usd: 99.0, pr_base: "develop"}

      {merged, _fell_back} = RunContext.merge(opts, recorded)

      assert Keyword.get(merged, :budget_usd) == 3.0
      assert Keyword.get(merged, :pr_base) == "develop"
    end

    test "never injects a nil value for a field the recorded struct doesn't have" do
      {merged, _fell_back} = RunContext.merge([], %RunContext{pr_base: nil})
      refute Keyword.has_key?(merged, :pr_base)
    end
  end
end
