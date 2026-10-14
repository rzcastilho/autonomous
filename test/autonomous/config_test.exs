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

  describe "conversation stderr caps" do
    for {fun, key} <- [
          {:conversation_stderr_head, :conversation_stderr_head},
          {:conversation_stderr_tail, :conversation_stderr_tail}
        ] do
      test "#{fun}/0 defaults to 1000, honours an override, raises on bad values" do
        key = unquote(key)
        fun = unquote(fun)
        prior = Application.fetch_env(:autonomous, key)

        on_exit(fn ->
          case prior do
            {:ok, v} -> Application.put_env(:autonomous, key, v)
            :error -> Application.delete_env(:autonomous, key)
          end
        end)

        Application.delete_env(:autonomous, key)
        assert apply(Config, fun, []) == 1000

        Application.put_env(:autonomous, key, 5)
        assert apply(Config, fun, []) == 5

        for bad <- [0, -1, "10", 1.5, nil] do
          Application.put_env(:autonomous, key, bad)

          assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
            apply(Config, fun, [])
          end
        end
      end
    end
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
