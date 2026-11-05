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

  describe "attachment limits (047)" do
    @limits [
      {:attachment_max_files, 10},
      {:attachment_max_file_bytes, 6_000_000},
      {:attachment_max_total_bytes, 25_000_000}
    ]

    setup do
      prior = for {k, _} <- @limits, do: {k, Application.fetch_env(:autonomous, k)}

      on_exit(fn ->
        for {k, v} <- prior do
          case v do
            {:ok, val} -> Application.put_env(:autonomous, k, val)
            :error -> Application.delete_env(:autonomous, k)
          end
        end
      end)

      for {k, _} <- @limits, do: Application.delete_env(:autonomous, k)
      :ok
    end

    test "defaults, override and bad value" do
      assert Config.attachment_max_files() == 10
      assert Config.attachment_max_file_bytes() == 6_000_000
      assert Config.attachment_max_total_bytes() == 25_000_000

      Application.put_env(:autonomous, :attachment_max_files, 3)
      assert Config.attachment_max_files() == 3

      for {k, fun} <- [
            {:attachment_max_files, :attachment_max_files},
            {:attachment_max_file_bytes, :attachment_max_file_bytes},
            {:attachment_max_total_bytes, :attachment_max_total_bytes}
          ],
          bad <- [0, -1, "10", nil] do
        Application.put_env(:autonomous, k, bad)

        assert_raise ArgumentError, ~r/must be a positive integer/, fn ->
          apply(Config, fun, [])
        end
      end
    end

    test "session_max_line_bytes derives from the per-file limit" do
      # 6 MB -> 8 MB of base64, twice, plus 512 KiB: just under the 16 MiB ceiling
      assert Config.session_max_line_bytes() == 2 * 8_000_000 + 524_288
      assert Config.session_max_line_bytes() < 16_777_216

      Application.put_env(:autonomous, :attachment_max_file_bytes, 3_000)
      assert Config.session_max_line_bytes() == 2 * 4_000 + 524_288
    end

    test "session_max_line_bytes never exceeds the transport's 16 MiB line ceiling" do
      Application.put_env(:autonomous, :attachment_max_file_bytes, 10_000_000)
      assert Config.session_max_line_bytes() == 16_777_216
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
