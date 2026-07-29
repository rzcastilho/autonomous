defmodule SpeckitOrchestrator.LiveConfigTest do
  # Mutates global app env (:models, :pr_*) and the app-supervised
  # default-named Ledger's budget — must not run concurrently with another
  # test claiming those globals.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Config, Coordinator, Feature, Ledger, LiveConfig}

  setup do
    prior = %{
      models: Config.models(),
      pr_base: Application.get_env(:speckit_orchestrator, :pr_base),
      pr_remote: Application.get_env(:speckit_orchestrator, :pr_remote),
      budget_usd: Ledger.snapshot().budget
    }

    on_exit(fn ->
      Application.put_env(:speckit_orchestrator, :models, prior.models)
      restore(:pr_base, prior.pr_base)
      restore(:pr_remote, prior.pr_remote)
      Ledger.set_budget(prior.budget_usd)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:speckit_orchestrator, key)
  defp restore(key, value), do: Application.put_env(:speckit_orchestrator, key, value)

  describe "bounds validation (Fail Loud, no setter call on reject)" do
    test "rejects a negative budget" do
      before = Ledger.snapshot().budget
      assert {:error, %{budget_usd: _}} = LiveConfig.apply(%{budget_usd: -1})
      assert Ledger.snapshot().budget == before
    end

    test "rejects an invalid per-phase model" do
      assert {:error, %{models: _}} = LiveConfig.apply(%{models: %{specify: "haiku"}})
      refute Config.models()[:specify] == "haiku"
    end

    test "one invalid field rejects the whole change — no setter call for any field" do
      before = Ledger.snapshot().budget

      assert {:error, errors} =
               LiveConfig.apply(%{budget_usd: 50, models: %{specify: "haiku"}})

      assert Map.has_key?(errors, :models)
      assert Ledger.snapshot().budget == before
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

  describe "budget dispatch" do
    test "a valid budget change calls Ledger.set_budget/2" do
      assert {:ok, _change} = LiveConfig.apply(%{budget_usd: 42.0})
      assert Ledger.snapshot().budget == 42.0
    end

    test "a valid budget change applies with no active run" do
      refute Process.whereis(Coordinator)
      assert {:ok, _change} = LiveConfig.apply(%{budget_usd: 33.0})
      assert Ledger.snapshot().budget == 33.0
    end

    test "a valid budget change applies while a run is active — 019 retired the cap, nothing to race" do
      {:ok, pid} =
        Coordinator.start_link(
          name: Coordinator,
          features: [%Feature{id: "lc1", number: 1, slug: "lc1", path: "lc1.md"}],
          runner: fn _feature, _notify -> :ok end,
          owner: self()
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:ok, _change} = LiveConfig.apply(%{budget_usd: 15.0})
      assert Ledger.snapshot().budget == 15.0
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
