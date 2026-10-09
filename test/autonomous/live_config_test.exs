defmodule Autonomous.LiveConfigTest do
  # Mutates global app env (:models, :pr_*) — must not run concurrently with
  # another test claiming those globals.
  use ExUnit.Case, async: false

  alias Autonomous.{Config, LiveConfig}

  setup do
    prior = %{
      models: Config.models(),
      pr_base: Application.get_env(:autonomous, :pr_base),
      pr_remote: Application.get_env(:autonomous, :pr_remote)
    }

    on_exit(fn ->
      Application.put_env(:autonomous, :models, prior.models)
      restore(:pr_base, prior.pr_base)
      restore(:pr_remote, prior.pr_remote)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:autonomous, key)
  defp restore(key, value), do: Application.put_env(:autonomous, key, value)

  describe "bounds validation (Fail Loud, no setter call on reject)" do
    test "rejects an invalid per-phase model" do
      assert {:error, %{models: _}} = LiveConfig.apply(%{models: %{specify: "haiku"}})
      refute Config.models()[:specify] == "haiku"
    end

    test "one invalid field rejects the whole change — no setter call for any field" do
      assert {:error, errors} =
               LiveConfig.apply(%{pr_base: "rejected-branch", models: %{specify: "haiku"}})

      assert Map.has_key?(errors, :models)
      refute Config.pr_base() == "rejected-branch"
    end

    test "rejects an unknown field" do
      assert {:error, %{max_concurrency: _}} = LiveConfig.apply(%{max_concurrency: 1})
    end
  end

  describe "model-routing change (forward-only, FR-032/FR-037)" do
    test "a valid model change updates app env only, read at call time via Config.model_for/1" do
      assert {:ok, _change} = LiveConfig.apply(%{models: %{specify: "opus"}})
      assert Config.model_for(:specify) == "opus"
    end
  end

  describe "budget_usd is retired (039)" do
    test "an edit naming budget_usd is refused as retired, and nothing applies" do
      assert {:error, %{budget_usd: message}} =
               LiveConfig.apply(%{budget_usd: 42.0, pr_base: "not-applied"})

      assert message =~ "budget_usd is retired"
      refute message =~ "unknown field"
      refute Config.pr_base() == "not-applied"
    end
  end

  describe "PR settings (app env, forward-only)" do
    test "pr_base/pr_remote apply to app env" do
      assert {:ok, _change} =
               LiveConfig.apply(%{pr_base: "develop", pr_remote: "upstream"})

      assert Config.pr_base() == "develop"
      assert Config.pr_remote() == "upstream"
    end
  end
end
