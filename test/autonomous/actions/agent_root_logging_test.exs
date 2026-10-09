defmodule Autonomous.Actions.AgentRootLoggingTest do
  # async: false — toggles the global :jido_claude sdk_module and the Logger level.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Autonomous.Actions.{RunAutoRemediation, RunFeaturePhase, RunRemediation}
  alias Autonomous.Feature
  alias ClaudeAgentSDK.Message

  # A session that runs one scripted Bash call (command, paired tool result). The
  # script rides in the app env because PhaseSession reduces in another process.
  defmodule ScriptedSDK do
    def query(_prompt, _opts) do
      {command, output} = Application.fetch_env!(:autonomous, :__install_call)

      [
        %Message{
          type: :assistant,
          data: %{
            message: %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "i1",
                  "name" => "Bash",
                  "input" => %{"command" => command}
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
                  "tool_use_id" => "i1",
                  "is_error" => false,
                  "content" => output
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
            session_id: "s",
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

  setup do
    original = Application.get_env(:jido_claude, :sdk_module)
    level = Logger.level()
    Application.put_env(:jido_claude, :sdk_module, ScriptedSDK)
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: level)
      Application.delete_env(:autonomous, :__install_call)

      if original,
        do: Application.put_env(:jido_claude, :sdk_module, original),
        else: Application.delete_env(:jido_claude, :sdk_module)
    end)

    :ok
  end

  defp script(command, output),
    do: Application.put_env(:autonomous, :__install_call, {command, output})

  defp ctx(extra) do
    base = %{
      feature: %Feature{id: "003", number: 3, slug: "s", path: "p.md", spec_number: 3},
      worktree: nil,
      layout: nil,
      phase: :analyze,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: [],
      resume_phase: nil,
      resume_prompt: nil,
      remediation_prompt: "fix",
      remediation_model: nil,
      containment: "strict"
    }

    %{agent: %{state: Map.merge(base, extra)}}
  end

  @sites [
    {"RunFeaturePhase", &__MODULE__.run_phase/1, "(implement)"},
    {"RunRemediation", &__MODULE__.run_rem/1, "(remediation)"},
    {"RunAutoRemediation", &__MODULE__.run_auto/1, "(auto_remediation)"}
  ]

  def run_phase(c), do: RunFeaturePhase.run(%{phase: :implement}, c)
  def run_rem(c), do: RunRemediation.run(%{}, c)
  def run_auto(c), do: RunAutoRemediation.run(%{prompt: "fix", model: "sonnet", attempt: 1}, c)

  for {name, _fun, _label} <- @sites do
    test "#{name}: an allowed install is logged" do
      script("sudo apt-get install -y libfoo-dev", "ok")
      {_, fun, label} = Enum.find(@sites, &(elem(&1, 0) == unquote(name)))
      log = capture_log(fn -> fun.(ctx(%{})) end)
      assert log =~ "agent root: feature 003 #{label} installed system packages: libfoo-dev"
    end

    test "#{name}: a denied install is not logged" do
      script(
        "sudo apt-get install -y libfoo-dev",
        "scope_guard[strict|orchestrated]: bash_sudo: sudo"
      )

      {_, fun, _} = Enum.find(@sites, &(elem(&1, 0) == unquote(name)))
      log = capture_log(fn -> fun.(ctx(%{})) end)
      refute log =~ "agent root:"
    end
  end
end
