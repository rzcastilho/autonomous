defmodule SpeckitOrchestrator.RunContextTest do
  # async: false — mutates global Config app env for the Config-fallback cases.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.RunContext

  @config_keys [:pr_workflow, :max_concurrency, :budget_usd, :plan_stack, :pr_base, :pr_remote]

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
        pr_workflow: true,
        max_concurrency: 3,
        budget_usd: 7.5,
        plan_stack: ["a", "b"],
        pr_base: "develop",
        pr_remote: "upstream"
      ]

      assert RunContext.capture(opts) == %RunContext{
               pr_workflow: true,
               max_concurrency: 3,
               budget_usd: 7.5,
               plan_stack: ["a", "b"],
               pr_base: "develop",
               pr_remote: "upstream"
             }
    end

    test "falls back to live Config when opts is absent/empty" do
      Application.put_env(:speckit_orchestrator, :pr_workflow, true)
      Application.put_env(:speckit_orchestrator, :max_concurrency, 5)
      Application.put_env(:speckit_orchestrator, :budget_usd, 12.0)
      Application.put_env(:speckit_orchestrator, :plan_stack, ["x"])
      Application.put_env(:speckit_orchestrator, :pr_base, "trunk")
      Application.put_env(:speckit_orchestrator, :pr_remote, "origin2")

      assert RunContext.capture([]) == %RunContext{
               pr_workflow: true,
               max_concurrency: 5,
               budget_usd: 12.0,
               plan_stack: ["x"],
               pr_base: "trunk",
               pr_remote: "origin2"
             }
    end

    test "resolves each field independently — opts-present for one, Config-fallback for the rest" do
      Application.put_env(:speckit_orchestrator, :max_concurrency, 9)

      ctx = RunContext.capture(pr_workflow: true)
      assert ctx.pr_workflow == true
      assert ctx.max_concurrency == 9
    end
  end

  describe "to_map/1" do
    test "produces a JSON-ready string-keyed map of exactly the six settings" do
      ctx = %RunContext{
        pr_workflow: true,
        max_concurrency: 2,
        budget_usd: 25.0,
        plan_stack: ["research", "plan"],
        pr_base: "main",
        pr_remote: "origin"
      }

      assert RunContext.to_map(ctx) == %{
               "pr_workflow" => true,
               "max_concurrency" => 2,
               "budget_usd" => 25.0,
               "plan_stack" => ["research", "plan"],
               "pr_base" => "main",
               "pr_remote" => "origin"
             }
    end

    test "map keys are exactly the six settings, nothing else" do
      map = RunContext.to_map(%RunContext{})

      assert Map.keys(map) |> Enum.sort() ==
               Enum.sort([
                 "pr_workflow",
                 "max_concurrency",
                 "budget_usd",
                 "plan_stack",
                 "pr_base",
                 "pr_remote"
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
      assert RunContext.from_map(%{"pr_workflow" => true, "budget_usd" => 10.0}) ==
               %RunContext{pr_workflow: true, budget_usd: 10.0}
    end

    test "never raises on an unexpected/extra key" do
      assert RunContext.from_map(%{"pr_workflow" => true, "unexpected" => "ignored"}) ==
               %RunContext{pr_workflow: true}
    end
  end

  describe "merge/2" do
    test "an opts-supplied key always wins over recorded" do
      recorded = %RunContext{pr_workflow: true}
      {merged, fell_back} = RunContext.merge([pr_workflow: false], recorded)

      assert Keyword.get(merged, :pr_workflow) == false
      refute :pr_workflow in fell_back
    end

    test "a recorded non-nil value is injected into merged_opts when opts lacks the key" do
      recorded = %RunContext{max_concurrency: 4}
      {merged, fell_back} = RunContext.merge([], recorded)

      assert Keyword.get(merged, :max_concurrency) == 4
      refute :max_concurrency in fell_back
    end

    test "a key present in neither is left absent and reported in fell_back_keys" do
      {merged, fell_back} = RunContext.merge([], %RunContext{})

      assert Keyword.fetch(merged, :pr_base) == :error
      assert :pr_base in fell_back
      assert length(fell_back) == 6
    end

    test "result is independent of opts vs recorded argument precedence order" do
      opts = [budget_usd: 3.0]
      recorded = %RunContext{budget_usd: 99.0, pr_base: "develop"}

      {merged, _fell_back} = RunContext.merge(opts, recorded)

      assert Keyword.get(merged, :budget_usd) == 3.0
      assert Keyword.get(merged, :pr_base) == "develop"
    end

    test "never injects a nil value for a field the recorded struct doesn't have" do
      {merged, _fell_back} = RunContext.merge([], %RunContext{pr_workflow: nil})
      refute Keyword.has_key?(merged, :pr_workflow)
    end
  end
end
