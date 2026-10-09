defmodule Autonomous.Actions.RunAutoRemediationTest do
  # async: false — toggles the global :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias Autonomous.Actions.RunAutoRemediation
  alias Autonomous.Feature

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

  defp context(state_overrides) do
    base = %{
      feature: %Feature{id: "001", number: 1, slug: "s", path: "p.md"},
      worktree: nil,
      layout: nil,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: []
    }

    %{agent: %{state: Map.merge(base, state_overrides)}}
  end

  defp restore_sdk(nil), do: Application.delete_env(:jido_claude, :sdk_module)
  defp restore_sdk(val), do: Application.put_env(:jido_claude, :sdk_module, val)

  describe "no containment env markers (039)" do
    setup do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, EnvCapturingSDK)
      on_exit(fn -> restore_sdk(original) end)
      :ok
    end

    test "carries neither retired marker (039)" do
      assert {:ok, _} =
               RunAutoRemediation.run(
                 %{prompt: "fix it", model: "sonnet", attempt: 1},
                 context(%{})
               )

      assert_received {:captured_env, env}
      refute Map.has_key?(env, "AUTONOMOUS_ORCHESTRATED")
      refute Map.has_key?(env, "AUTONOMOUS_CONTAINMENT_PROFILE")
    end
  end

  describe "the background-wait gate (032, US1)" do
    test "an attempt that ends on a backgrounded command is an error" do
      original = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, BackgroundingSDK)
      on_exit(fn -> restore_sdk(original) end)

      params = %{prompt: "fix it", model: "sonnet", attempt: 1}
      assert {:ok, update} = RunAutoRemediation.run(params, context(%{}))
      assert update.last_outcome == :error
      assert update.last_signals == %{outstanding_work?: true, backgrounded: ["npm run test:e2e"]}
    end
  end
end
