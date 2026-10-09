defmodule Autonomous.ConfigTest do
  use ExUnit.Case, async: false

  alias Autonomous.Config

  test "accessors read the configured values" do
    assert Config.repo() == "."
    assert Config.breakdown_dir() == "docs/breakdown"
    assert Config.worktree_root() == "../.speckit-worktrees"
    assert Config.implement_max_turns() == 200
    assert Config.implement_no_progress_limit() == 3

    # Empty by default: plan derives the stack from the target's own
    # constitution/manifest. Set per-target via AUTONOMOUS_PLAN_STACK — a stack that
    # contradicts the target makes plan refuse and ask an unanswerable question.
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
    original = Application.get_env(:autonomous, :pr_remote)
    Application.put_env(:autonomous, :pr_remote, "upstream-override")

    on_exit(fn ->
      if original,
        do: Application.put_env(:autonomous, :pr_remote, original),
        else: Application.delete_env(:autonomous, :pr_remote)
    end)

    assert Config.pr_remote() == "upstream-override"
  end

  test "defaults apply when a key is unset" do
    original = Application.get_env(:autonomous, :plan_stack)
    Application.delete_env(:autonomous, :plan_stack)
    on_exit(fn -> Application.put_env(:autonomous, :plan_stack, original) end)
    assert Config.plan_stack() == []
  end
end
