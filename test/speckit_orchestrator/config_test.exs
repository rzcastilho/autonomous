defmodule SpeckitOrchestrator.ConfigTest do
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Config

  test "accessors read the configured values" do
    assert Config.repo() == "."
    assert Config.breakdown_dir() == "docs/breakdown"
    assert Config.worktree_root() == "../.speckit-worktrees"
    assert Config.max_concurrency() == 2
    assert Config.budget_usd() == 74.0
    assert Config.implement_max_turns() == 80
    assert Config.plan_stack() == []
    assert Config.speckit_version() == "v0.12.11"
    assert is_map(Config.models())
  end

  test "model_for/1 returns the model alias per phase" do
    assert Config.model_for(:clarify) == "opus"
    assert Config.model_for(:implement) == "sonnet"
  end

  test "model_for/1 raises on an unconfigured phase" do
    assert_raise ArgumentError, ~r/no model configured for phase :bogus/, fn ->
      Config.model_for(:bogus)
    end
  end

  test "put_env override is honored" do
    original = Application.get_env(:speckit_orchestrator, :max_concurrency)
    Application.put_env(:speckit_orchestrator, :max_concurrency, 7)
    on_exit(fn -> Application.put_env(:speckit_orchestrator, :max_concurrency, original) end)
    assert Config.max_concurrency() == 7
  end

  test "defaults apply when a key is unset" do
    original = Application.get_env(:speckit_orchestrator, :plan_stack)
    Application.delete_env(:speckit_orchestrator, :plan_stack)
    on_exit(fn -> Application.put_env(:speckit_orchestrator, :plan_stack, original) end)
    assert Config.plan_stack() == []
  end
end
