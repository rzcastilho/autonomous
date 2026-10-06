defmodule Autonomous.Actions.RunRemediationTest do
  # async: false — toggles the global :jido_harness providers / :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias Autonomous.Actions.RunRemediation
  alias Autonomous.Feature

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

  defmodule EnvCapturingSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, opts) do
      send(self(), {:captured_env, opts.env})

      [
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-rem-env",
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

  # 032: a session that reports success after a Bash command was auto-backgrounded
  # at the CLI's 10-min cap and never read back — every call id is matched, so the
  # pre-032 outstanding-work gate sees nothing wrong.
  defmodule BackgroundingSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _opts) do
      send(self(), {:captured_prompt, prompt})

      [
        %Message{
          type: :assistant,
          data: %{
            message: %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "bg-1",
                  "name" => "Bash",
                  "input" => %{"command" => "npm run test:e2e"}
                }
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :user,
          data: %{
            message: %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "bg-1",
                  "is_error" => false,
                  "content" =>
                    "Command did not complete within its 600s timeout and was moved to the background (ID: bgx1). " <>
                      "Output is being written to: /tmp/bgx1.output"
                }
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-bg",
            result: "Waiting for the e2e run.",
            num_turns: 2,
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

  defp context(state_overrides \\ %{}) do
    base = %{
      feature: %Feature{id: "001", number: 1, slug: "s", path: "p.md"},
      worktree: nil,
      layout: nil,
      phase: :analyze,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: [],
      remediation_prompt: "Fix the money-type Critical.",
      remediation_model: nil,
      containment: "strict"
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

  describe "containment env markers (030, T016)" do
    setup do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, EnvCapturingSDK)
      on_exit(fn -> restore_sdk(original) end)
      :ok
    end

    defp restore_sdk(nil), do: Application.delete_env(:jido_claude, :sdk_module)
    defp restore_sdk(val), do: Application.put_env(:jido_claude, :sdk_module, val)

    test "carries AUTONOMOUS_ORCHESTRATED=1 under strict" do
      assert {:ok, _} = RunRemediation.run(%{}, context(%{containment: "strict"}))
      assert_received {:captured_env, env}
      assert env["AUTONOMOUS_ORCHESTRATED"] == "1"
      assert env["AUTONOMOUS_CONTAINMENT_PROFILE"] == "strict"
    end

    test "carries AUTONOMOUS_ORCHESTRATED=1 under permissive" do
      assert {:ok, _} = RunRemediation.run(%{}, context(%{containment: "permissive"}))
      assert_received {:captured_env, env}
      assert env["AUTONOMOUS_ORCHESTRATED"] == "1"
      assert env["AUTONOMOUS_CONTAINMENT_PROFILE"] == "permissive"
    end
  end

  describe "the background-wait gate (032, US1)" do
    test "a remediation that ends on a backgrounded command is an error, not a success" do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, BackgroundingSDK)
      on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

      assert {:ok, update} = RunRemediation.run(%{}, context())
      assert update.last_outcome == :error
      assert update.last_signals == %{outstanding_work?: true, backgrounded: ["npm run test:e2e"]}
    end
  end
end
