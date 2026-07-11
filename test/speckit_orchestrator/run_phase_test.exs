defmodule SpeckitOrchestrator.RunPhaseTest do
  # async: false — swaps the global :jido_claude sdk_module.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Feature, Ledger, PhaseRequest}
  alias SpeckitOrchestrator.Actions.RunPhase

  # Fake SDK: exercises the real adapter -> mapper -> harness -> reduce path
  # offline (no CLI, no spend) by returning canned ClaudeAgentSDK.Message structs.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, _options) do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "sess-int", tools: []}, raw: %{}},
        %Message{
          type: :assistant,
          subtype: nil,
          data: %{session_id: "sess-int", message: %{"content" => "Spec created."}},
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "sess-int",
            result: "Spec created.",
            num_turns: 2,
            duration_ms: 1000,
            is_error: false,
            total_cost_usd: 0.37,
            usage: %{input_tokens: 100, output_tokens: 50},
            model: "claude-sonnet-4-6"
          },
          raw: %{}
        }
      ]
    end
  end

  defmodule FailSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, _options) do
      [%Message{type: :result, subtype: :error, data: %{session_id: "s", error: "kaboom"}, raw: %{}}]
    end
  end

  setup do
    original = Application.get_env(:jido_claude, :sdk_module)
    on_exit(fn -> restore(:jido_claude, :sdk_module, original) end)
    ledger = start_supervised!({Ledger, budget: 100, name: nil})
    %{ledger: ledger}
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, val), do: Application.put_env(app, key, val)

  defp feature do
    %Feature{id: "001", slug: "core-ledger", path: "/x/docs/breakdown/001-core-ledger.md"}
  end

  test "runs a phase end-to-end, records actual cost to the ledger", %{ledger: ledger} do
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    request = PhaseRequest.build(feature(), :specify)
    {:ok, out} = RunPhase.run(%{request: request, phase: :specify, ledger: ledger}, %{})

    assert out.phase_result.final_text == "Spec created."
    assert out.phase_result.session_id == "sess-int"
    assert out.phase_result.status == :ok
    assert out.cost_usd == 0.37
    assert out.cost_source == :actual
    assert Ledger.spent(ledger) == 0.37
  end

  test "a failed session surfaces an error PhaseResult (still charged an estimate)", %{ledger: ledger} do
    Application.put_env(:jido_claude, :sdk_module, FailSDK)

    request = PhaseRequest.build(feature(), :specify)
    {:ok, out} = RunPhase.run(%{request: request, phase: :specify, ledger: ledger}, %{})

    assert out.phase_result.status == :error
    assert out.phase_result.error == "kaboom"
    # no usage event -> falls back to the config estimate for :specify
    assert out.cost_source == :estimate
    assert Ledger.spent(ledger) == 0.20
  end

  test "runs with no ledger (cost recording is a no-op)" do
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    request = PhaseRequest.build(feature(), :specify)
    assert {:ok, out} = RunPhase.run(%{request: request, phase: :specify, ledger: nil}, %{})
    assert out.cost_usd == 0.37
  end

  test "harness error propagates as {:error, reason}" do
    original = Application.get_env(:jido_harness, :providers)
    Application.put_env(:jido_harness, :providers, %{})
    on_exit(fn -> Application.put_env(:jido_harness, :providers, original) end)

    request = PhaseRequest.build(feature(), :specify)
    assert {:error, _reason} = RunPhase.run(%{request: request, phase: :specify, ledger: nil}, %{})
  end

  @tag :integration
  test "LIVE: runs /speckit.specify against a real Spec Kit repo (paid, opt-in)" do
    repo = System.get_env("SPECKIT_FIXTURE_REPO") || flunk("set SPECKIT_FIXTURE_REPO to a repo path")

    feature = %Feature{id: "001", slug: "smoke", path: Path.join(repo, "docs/breakdown/001-smoke.md")}
    request = PhaseRequest.build(feature, :specify, cwd: repo)

    assert {:ok, out} = RunPhase.run(%{request: request, phase: :specify, ledger: nil}, %{})
    assert out.phase_result.status in [:ok, :error]
    assert is_binary(out.phase_result.final_text)
  end
end
