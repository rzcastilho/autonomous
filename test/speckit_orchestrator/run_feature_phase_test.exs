defmodule SpeckitOrchestrator.Actions.RunFeaturePhaseTest do
  # async: false — toggles the global :jido_harness providers / :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Actions.RunFeaturePhase
  alias SpeckitOrchestrator.{Config, Feature, PhaseRequest}

  # Fake SDK that reports the built prompt back to the test process so the
  # resume-guidance injection can be asserted end-to-end (no CLI, no spend).
  defmodule CapturingSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _opts) do
      send(self(), {:captured_prompt, prompt})

      [
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-cap",
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

  defp context(state_overrides \\ %{}) do
    base = %{
      feature: %Feature{id: "001", slug: "s", path: "p.md"},
      worktree: nil,
      session_id: nil,
      ledger: nil,
      cost_total: 0.0,
      history: [],
      resume_phase: nil,
      resume_prompt: nil
    }

    %{agent: %{state: Map.merge(base, state_overrides)}}
  end

  test "resume_prompt re-injects on every retry of the resumed phase" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    ctx =
      context(%{
        resume_phase: :analyze,
        resume_prompt: "resolved: use integer cents"
      })

    assert {:ok, _} = RunFeaturePhase.run(%{phase: :analyze}, ctx)
    assert_received {:captured_prompt, prompt1}

    assert {:ok, _} = RunFeaturePhase.run(%{phase: :analyze}, ctx)
    assert_received {:captured_prompt, prompt2}

    for prompt <- [prompt1, prompt2] do
      assert prompt =~ "Operator guidance (resume): resolved: use integer cents"
    end

    assert prompt1 == prompt2
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  @all_phases [:specify, :clarify, :plan, :tasks, :analyze, :implement]

  test "resume guidance reaches only the resume phase, never downstream" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    ctx = context(%{resume_phase: :clarify, resume_prompt: "use REST, not GraphQL"})

    prompts =
      for phase <- @all_phases, into: %{} do
        assert {:ok, _} = RunFeaturePhase.run(%{phase: phase}, ctx)
        assert_received {:captured_prompt, prompt}
        {phase, prompt}
      end

    assert prompts[:clarify] =~ "Operator guidance (resume): use REST, not GraphQL"

    for phase <- @all_phases, phase != :clarify do
      refute prompts[phase] =~ "use REST, not GraphQL"
    end
  end

  test "a fresh run (no resume state) builds byte-identical prompts on every phase" do
    original = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, CapturingSDK)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)

    ctx = context()
    feature = ctx.agent.state.feature

    for phase <- @all_phases do
      assert {:ok, _} = RunFeaturePhase.run(%{phase: phase}, ctx)
      assert_received {:captured_prompt, prompt}

      expected = PhaseRequest.build(feature, phase, cwd: Config.repo()).prompt
      assert prompt == expected
    end
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
