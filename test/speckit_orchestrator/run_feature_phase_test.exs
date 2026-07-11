defmodule SpeckitOrchestrator.Actions.RunFeaturePhaseTest do
  # async: false — toggles the global :jido_harness providers.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Actions.RunFeaturePhase
  alias SpeckitOrchestrator.Feature

  defp context(state_overrides \\ %{}) do
    base = %{
      feature: %Feature{id: "001", slug: "s", path: "p.md"},
      worktree: nil,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: []
    }

    %{agent: %{state: Map.merge(base, state_overrides)}}
  end

  test "a harness error is folded into an :error outcome (no crash, no cost)" do
    original = Application.get_env(:jido_harness, :providers)
    Application.put_env(:jido_harness, :providers, %{})
    on_exit(fn -> Application.put_env(:jido_harness, :providers, original) end)

    assert {:ok, update} = RunFeaturePhase.run(%{phase: :specify}, context())
    assert update.last_outcome == :error
    assert update.last_result == nil
    assert [%{phase: :specify, outcome: :error}] = update.history
  end
end
