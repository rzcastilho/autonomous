defmodule SpeckitOrchestrator.Actions.RunAutoRemediationTest do
  # async: false — toggles the global :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Actions.RunAutoRemediation
  alias SpeckitOrchestrator.Feature

  defmodule EnvCapturingSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, opts) do
      send(self(), {:captured_env, opts.env})

      [
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-auto-rem-env",
            result: "ok",
            num_turns: 1,
            duration_ms: 1,
            is_error: false,
            total_cost_usd: 0.0,
            usage: %{input_tokens: 0, output_tokens: 0},
            model: "m"
          },
          raw: %{}
        }
      ]
    end
  end

  defp context(state_overrides) do
    base = %{
      feature: %Feature{id: "001", number: 1, slug: "s", path: "p.md"},
      worktree: nil,
      layout: nil,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: [],
      containment: "strict"
    }

    %{agent: %{state: Map.merge(base, state_overrides)}}
  end

  defp restore_sdk(nil), do: Application.delete_env(:jido_claude, :sdk_module)
  defp restore_sdk(val), do: Application.put_env(:jido_claude, :sdk_module, val)

  describe "containment env markers (030, T016)" do
    setup do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, EnvCapturingSDK)
      on_exit(fn -> restore_sdk(original) end)
      :ok
    end

    test "carries SPECKIT_ORCHESTRATED=1 under strict" do
      params = %{prompt: "fix it", model: "sonnet", attempt: 1}
      assert {:ok, _} = RunAutoRemediation.run(params, context(%{containment: "strict"}))
      assert_received {:captured_env, env}
      assert env["SPECKIT_ORCHESTRATED"] == "1"
      assert env["SPECKIT_CONTAINMENT_PROFILE"] == "strict"
    end

    test "carries SPECKIT_ORCHESTRATED=1 under permissive" do
      params = %{prompt: "fix it", model: "sonnet", attempt: 1}
      assert {:ok, _} = RunAutoRemediation.run(params, context(%{containment: "permissive"}))
      assert_received {:captured_env, env}
      assert env["SPECKIT_ORCHESTRATED"] == "1"
      assert env["SPECKIT_CONTAINMENT_PROFILE"] == "permissive"
    end
  end
end
