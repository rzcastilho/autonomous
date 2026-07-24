defmodule SpeckitOrchestrator.Actions.RunRemediationTest do
  # async: false — toggles the global :jido_harness providers / :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Actions.RunRemediation
  alias SpeckitOrchestrator.Feature

  defmodule CapturingSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _opts) do
      send(self(), {:captured_prompt, prompt})

      [
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-rem",
            result: "fixed it",
            num_turns: 1,
            duration_ms: 1,
            is_error: false,
            total_cost_usd: 0.12,
            usage: %{input_tokens: 0, output_tokens: 0},
            model: "m"
          },
          raw: %{}
        }
      ]
    end
  end

  defp context(state_overrides \\ %{}) do
    base = %{
      feature: %Feature{id: "001", slug: "s", path: "p.md"},
      worktree: nil,
      layout: nil,
      phase: :analyze,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: [],
      remediation_prompt: "Fix the money-type Critical.",
      remediation_model: nil
    }

    %{agent: %{state: Map.merge(base, state_overrides)}}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  test "folds cost/history/last_outcome on success, no gate signals" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    assert {:ok, update} = RunRemediation.run(%{}, context())

    assert_received {:captured_prompt, prompt}
    assert prompt =~ "Fix the money-type Critical."

    assert update.last_outcome == :ok
    assert update.last_signals == %{}
    assert update.last_result.final_text == "fixed it"
    assert update.session_id == "sess-rem"
    assert update.cost_total == 0.12
    assert [%{phase: :remediation, outcome: :ok, cost: 0.12}] = update.history
  end

  test "an error outcome on a harness failure — no gate signals, no cost recorded" do
    original = Application.get_env(:jido_harness, :providers)
    Application.put_env(:jido_harness, :providers, %{})
    on_exit(fn -> Application.put_env(:jido_harness, :providers, original) end)

    assert {:ok, update} = RunRemediation.run(%{}, context())

    assert update.last_outcome == :error
    assert update.last_signals == %{}
    assert update.last_result == nil
    assert [%{phase: :remediation, outcome: :error}] = update.history
  end

  test "an unknown remediation_model alias folds to an error outcome, no run started" do
    assert {:ok, update} =
             RunRemediation.run(%{}, context(%{remediation_model: "not-a-model"}))

    assert update.last_outcome == :error
    assert update.last_signals == %{}
    assert update.last_result == nil
    assert [%{phase: :remediation, outcome: :error, error: {:unknown_model, "not-a-model"}}] =
             update.history
  end
end
