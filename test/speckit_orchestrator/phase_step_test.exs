defmodule SpeckitOrchestrator.PhaseStepTest do
  # async: false — swaps the global :jido_claude sdk_module + a scenario flag.
  use ExUnit.Case, async: false

  alias Jido.{AgentServer, Signal}
  alias SpeckitOrchestrator.{Config, Feature, FeatureAgent, PhaseStep}

  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, _options) do
      case Application.get_env(:speckit_orchestrator, :phase_step_test_scenario, :happy) do
        :transient_once ->
          if first_call?(), do: transient_messages(), else: success_messages()

        :transient_always ->
          transient_messages()

        _ ->
          success_messages()
      end
    end

    defp success_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: "done", is_error: false, total_cost_usd: 0.10},
          raw: %{}
        }
      ]
    end

    defp transient_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error,
          data: %{
            session_id: "s",
            result: "API Error: Server error mid-response.",
            is_error: true,
            total_cost_usd: nil
          },
          raw: %{}
        }
      ]
    end

    defp first_call? do
      case Application.get_env(:speckit_orchestrator, :phase_step_test_counter) do
        nil -> false
        agent -> Agent.get_and_update(agent, fn n -> {n == 0, n + 1} end)
      end
    end
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.put_env(:speckit_orchestrator, :phase_step_test_scenario, :happy)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:speckit_orchestrator, :phase_step_test_scenario)
      Application.delete_env(:speckit_orchestrator, :phase_step_test_counter)
    end)

    :ok
  end

  defp feature, do: %Feature{id: "042", number: 42, slug: "phase-step", path: "docs/breakdown/042.md"}

  defp start_agent! do
    {:ok, pid} =
      AgentServer.start_link(
        agent: FeatureAgent,
        id: "phase-step-#{System.unique_integer([:positive])}",
        register_global: false
      )

    {:ok, _agent} =
      AgentServer.call(
        pid,
        Signal.new!("feature.init", %{feature: feature(), phase: :specify}, source: "/test"),
        5_000
      )

    pid
  end

  defp attach_phase_telemetry do
    test_pid = self()
    handler = "phase-step-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:speckit, :phase, :start], [:speckit, :phase, :stop]],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "default opts: span meta matches the original run_phase_with_retry shape" do
    pid = start_agent!()
    attach_phase_telemetry()

    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000)

    assert agent.state.last_outcome == :ok

    model = Config.model_for(:specify)

    assert_received {:tele, [:speckit, :phase, :start],
                     %{feature_id: "042", phase: :specify, model: ^model, step: 1}}

    assert_received {:tele, [:speckit, :phase, :stop],
                     %{
                       feature_id: "042",
                       phase: :specify,
                       model: ^model,
                       step: 1,
                       outcome: :ok,
                       cost: 0.10
                     }}
  end

  test ":span_meta keys merge into the telemetry span meta without displacing the base keys" do
    pid = start_agent!()
    attach_phase_telemetry()

    PhaseStep.run(pid, feature(), :specify,
      step: 1,
      timeout: 5_000,
      span_meta: %{attempt: 1, limit: 2}
    )

    assert_received {:tele, [:speckit, :phase, :stop],
                     %{phase: :specify, step: 1, attempt: 1, limit: 2}}
  end

  test "retries a transient failure up to :retries times, then succeeds" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Application.put_env(:speckit_orchestrator, :phase_step_test_counter, counter)
    Application.put_env(:speckit_orchestrator, :phase_step_test_scenario, :transient_once)

    pid = start_agent!()

    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000, retries: 1)

    assert agent.state.last_outcome == :ok
    Agent.stop(counter)
  end

  test "gives up after exhausting :retries on a persistent transient failure" do
    Application.put_env(:speckit_orchestrator, :phase_step_test_scenario, :transient_always)

    pid = start_agent!()

    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000, retries: 1)

    assert agent.state.last_outcome == :error
  end

  test "default :retries falls back to Config.phase_max_retries/0" do
    Application.put_env(:speckit_orchestrator, :phase_step_test_scenario, :transient_always)
    prev = Application.get_env(:speckit_orchestrator, :phase_max_retries)
    Application.put_env(:speckit_orchestrator, :phase_max_retries, 0)

    pid = start_agent!()
    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000)

    assert agent.state.last_outcome == :error

    if prev,
      do: Application.put_env(:speckit_orchestrator, :phase_max_retries, prev),
      else: Application.delete_env(:speckit_orchestrator, :phase_max_retries)
  end
end
