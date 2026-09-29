defmodule Autonomous.RunContextTest do
  # async: false — mutates global Config app env for the Config-fallback cases.
  use ExUnit.Case, async: false

  alias Autonomous.RunContext

  @config_keys [
    :budget_usd,
    :plan_stack,
    :pr_base,
    :pr_remote,
    :auto_remediation,
    :auto_remediation_threshold,
    :auto_remediation_attempt_limit,
    :auto_remediation_model,
    :auto_remediation_exhaustion_policy,
    :interactive_clarify,
    :clarify_answer_timeout_s,
    :clarify_max_rounds,
    :containment_profile
  ]

  setup do
    prev = for k <- @config_keys, do: {k, Application.get_env(:autonomous, k)}

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:autonomous, k, v),
          else: Application.delete_env(:autonomous, k)
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
        auto_remediation_model: "opus",
        auto_remediation_exhaustion_policy: :proceed,
        interactive_clarify: true,
        clarify_answer_timeout_s: 120,
        clarify_max_rounds: 2,
        containment_profile: :permissive
      ]

      assert RunContext.capture(opts) == %RunContext{
               budget_usd: 7.5,
               plan_stack: ["a", "b"],
               pr_base: "develop",
               pr_remote: "upstream",
               auto_remediation: false,
               auto_remediation_threshold: "critical",
               auto_remediation_attempt_limit: 3,
               auto_remediation_model: "opus",
               auto_remediation_exhaustion_policy: "proceed",
               interactive_clarify: true,
               clarify_answer_timeout_s: 120,
               clarify_max_rounds: 2,
               containment_profile: "permissive"
             }
    end

    test "falls back to live Config when opts is absent/empty" do
      Application.put_env(:autonomous, :budget_usd, 12.0)
      Application.put_env(:autonomous, :plan_stack, ["x"])
      Application.put_env(:autonomous, :pr_base, "trunk")
      Application.put_env(:autonomous, :pr_remote, "origin2")
      Application.put_env(:autonomous, :auto_remediation, false)
      Application.put_env(:autonomous, :auto_remediation_threshold, :medium)
      Application.put_env(:autonomous, :auto_remediation_attempt_limit, 4)
      Application.put_env(:autonomous, :auto_remediation_model, "sonnet")
      Application.put_env(:autonomous, :auto_remediation_exhaustion_policy, :proceed)
      Application.put_env(:autonomous, :interactive_clarify, true)
      Application.put_env(:autonomous, :clarify_answer_timeout_s, 600)
      Application.put_env(:autonomous, :clarify_max_rounds, 1)
      Application.put_env(:autonomous, :containment_profile, :permissive)

      assert RunContext.capture([]) == %RunContext{
               budget_usd: 12.0,
               plan_stack: ["x"],
               pr_base: "trunk",
               pr_remote: "origin2",
               auto_remediation: false,
               auto_remediation_threshold: "medium",
               auto_remediation_attempt_limit: 4,
               auto_remediation_model: "sonnet",
               auto_remediation_exhaustion_policy: "proceed",
               interactive_clarify: true,
               clarify_answer_timeout_s: 600,
               clarify_max_rounds: 1,
               containment_profile: "permissive"
             }
    end

    test "resolves each field independently — opts-present for one, Config-fallback for the rest" do
      Application.put_env(:autonomous, :pr_base, "trunk")

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
      assert ctx.auto_remediation_exhaustion_policy == "escalate"
    end

    test "auto_remediation_threshold is always stored as a string, never an atom" do
      assert RunContext.capture(auto_remediation_threshold: :low).auto_remediation_threshold ==
               "low"

      assert RunContext.capture(auto_remediation_threshold: "low").auto_remediation_threshold ==
               "low"
    end

    test "auto_remediation_exhaustion_policy is always stored as a string, never an atom (feature 021)" do
      assert RunContext.capture(auto_remediation_exhaustion_policy: :proceed).auto_remediation_exhaustion_policy ==
               "proceed"

      assert RunContext.capture(auto_remediation_exhaustion_policy: "proceed").auto_remediation_exhaustion_policy ==
               "proceed"
    end

    test "an opts-supplied :proceed does not change the default a later opts-less capture sees (FR-012)" do
      RunContext.capture(auto_remediation_exhaustion_policy: :proceed)
      assert RunContext.capture([]).auto_remediation_exhaustion_policy == "escalate"
    end

    test "defaults (no opts, no Config override) resolve interactive_clarify off (029, FR-002)" do
      ctx = RunContext.capture([])
      assert ctx.interactive_clarify == false
      assert ctx.clarify_answer_timeout_s == 1_800
      assert ctx.clarify_max_rounds == 3
    end

    test "defaults (no opts, no Config override) resolve containment_profile to \"strict\" (030, FR-002)" do
      assert RunContext.capture([]).containment_profile == "strict"
    end

    test "containment_profile is always stored as a string, never an atom (030)" do
      assert RunContext.capture(containment_profile: :permissive).containment_profile ==
               "permissive"

      assert RunContext.capture(containment_profile: "permissive").containment_profile ==
               "permissive"
    end

    test "resolves the interactive-clarify fields from opts when present" do
      ctx =
        RunContext.capture(
          interactive_clarify: true,
          clarify_answer_timeout_s: 90,
          clarify_max_rounds: 5
        )

      assert ctx.interactive_clarify == true
      assert ctx.clarify_answer_timeout_s == 90
      assert ctx.clarify_max_rounds == 5
    end
  end

  describe "to_map/1" do
    test "produces a JSON-ready string-keyed map of exactly the thirteen settings" do
      ctx = %RunContext{
        budget_usd: 25.0,
        plan_stack: ["research", "plan"],
        pr_base: "main",
        pr_remote: "origin",
        auto_remediation: true,
        auto_remediation_threshold: "high",
        auto_remediation_attempt_limit: 2,
        auto_remediation_model: nil,
        auto_remediation_exhaustion_policy: "escalate",
        interactive_clarify: false,
        clarify_answer_timeout_s: 1_800,
        clarify_max_rounds: 3,
        containment_profile: "strict"
      }

      assert RunContext.to_map(ctx) == %{
               "budget_usd" => 25.0,
               "plan_stack" => ["research", "plan"],
               "pr_base" => "main",
               "pr_remote" => "origin",
               "auto_remediation" => true,
               "auto_remediation_threshold" => "high",
               "auto_remediation_attempt_limit" => 2,
               "auto_remediation_model" => nil,
               "auto_remediation_exhaustion_policy" => "escalate",
               "interactive_clarify" => false,
               "clarify_answer_timeout_s" => 1_800,
               "clarify_max_rounds" => 3,
               "containment_profile" => "strict"
             }
    end

    test "map keys are exactly the thirteen settings, nothing else" do
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
                 "auto_remediation_model",
                 "auto_remediation_exhaustion_policy",
                 "interactive_clarify",
                 "clarify_answer_timeout_s",
                 "clarify_max_rounds",
                 "containment_profile"
               ])
    end
  end

  describe "from_map/1" do
    test "nil returns an all-nil struct except containment_profile, which defaults to \"strict\" (030)" do
      assert RunContext.from_map(nil) == %RunContext{containment_profile: "strict"}
    end

    test "empty map returns an all-nil struct except containment_profile, which defaults to \"strict\" (030)" do
      assert RunContext.from_map(%{}) == %RunContext{containment_profile: "strict"}
    end

    test "a missing containment_profile key decodes to \"strict\" — pre-030 recorded runs were strict" do
      assert RunContext.from_map(%{"pr_base" => "trunk"}) ==
               %RunContext{pr_base: "trunk", containment_profile: "strict"}
    end

    test "a present containment_profile key decodes as stored" do
      assert RunContext.from_map(%{"containment_profile" => "permissive"}).containment_profile ==
               "permissive"
    end

    test "partial map populates only present keys, leaving the rest nil" do
      assert RunContext.from_map(%{"pr_base" => "trunk", "budget_usd" => 10.0}) ==
               %RunContext{pr_base: "trunk", budget_usd: 10.0, containment_profile: "strict"}
    end

    test "never raises on an unexpected/extra key" do
      assert RunContext.from_map(%{"pr_base" => "trunk", "unexpected" => "ignored"}) ==
               %RunContext{pr_base: "trunk", containment_profile: "strict"}
    end

    test "round-trips the five auto-remediation fields through to_map/from_map" do
      ctx = %RunContext{
        auto_remediation: false,
        auto_remediation_threshold: "critical",
        auto_remediation_attempt_limit: 5,
        auto_remediation_model: "opus",
        auto_remediation_exhaustion_policy: "proceed",
        containment_profile: "strict"
      }

      assert ctx |> RunContext.to_map() |> RunContext.from_map() == ctx
    end

    test "round-trips the three interactive-clarify fields through to_map/from_map (029)" do
      ctx = %RunContext{
        interactive_clarify: true,
        clarify_answer_timeout_s: 300,
        clarify_max_rounds: 4
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
      assert length(fell_back) == 13
    end

    test "explicit opt > recorded > absent precedence holds for the auto-remediation fields too" do
      recorded = %RunContext{
        auto_remediation: false,
        auto_remediation_threshold: "critical",
        auto_remediation_attempt_limit: 4,
        auto_remediation_exhaustion_policy: "proceed"
      }

      {merged, fell_back} = RunContext.merge([auto_remediation: true], recorded)

      assert Keyword.get(merged, :auto_remediation) == true
      assert Keyword.get(merged, :auto_remediation_threshold) == "critical"
      assert Keyword.get(merged, :auto_remediation_attempt_limit) == 4
      assert Keyword.get(merged, :auto_remediation_exhaustion_policy) == "proceed"
      assert Keyword.fetch(merged, :auto_remediation_model) == :error
      assert :auto_remediation_model in fell_back
    end

    test "explicit opt > recorded > absent precedence holds for the interactive-clarify fields too (029)" do
      recorded = %RunContext{interactive_clarify: true, clarify_answer_timeout_s: 300}

      {merged, fell_back} = RunContext.merge([interactive_clarify: false], recorded)

      assert Keyword.get(merged, :interactive_clarify) == false
      assert Keyword.get(merged, :clarify_answer_timeout_s) == 300
      assert Keyword.fetch(merged, :clarify_max_rounds) == :error
      assert :clarify_max_rounds in fell_back
    end

    test "explicit opt > recorded > absent precedence holds for containment_profile too (030)" do
      recorded = %RunContext{containment_profile: "permissive"}

      {merged, fell_back} = RunContext.merge([], recorded)
      assert Keyword.get(merged, :containment_profile) == "permissive"
      refute :containment_profile in fell_back

      {merged2, _} = RunContext.merge([containment_profile: "strict"], recorded)
      assert Keyword.get(merged2, :containment_profile) == "strict"
    end

    test "a pre-029 recorded run without the interactive-clarify keys falls back to Config defaults" do
      recorded = %RunContext{pr_base: "trunk"}

      {merged, fell_back} = RunContext.merge([], recorded)

      assert Keyword.fetch(merged, :interactive_clarify) == :error
      assert :interactive_clarify in fell_back
      assert :clarify_answer_timeout_s in fell_back
      assert :clarify_max_rounds in fell_back
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
