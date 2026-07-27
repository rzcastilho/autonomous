defmodule SpeckitOrchestrator.RemediationTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{AnalyzeResult, RunContext}
  alias SpeckitOrchestrator.Remediation
  alias SpeckitOrchestrator.Remediation.Settings

  defp result(findings) do
    {:ok, r} = AnalyzeResult.parse(Jason.encode!(%{summary: "s", findings: findings}))
    r
  end

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        settings: %Settings{},
        attempts_used: 0,
        analyze_runs: 1,
        last_result: nil,
        last_outcome: :ok
      },
      overrides
    )
  end

  describe "Settings.validate/1" do
    test "defaults when given an empty input" do
      assert {:ok, %Settings{enabled?: true, threshold: :high, attempt_limit: 2}} =
               Settings.validate(%{})
    end

    test "accepts a keyword list too" do
      assert {:ok, %Settings{threshold: :critical}} =
               Settings.validate(threshold: :critical)
    end

    test "rejects an unparseable threshold, never clamping to a default" do
      assert Settings.validate(%{threshold: "severe"}) ==
               {:error, {:invalid_threshold, "severe"}}
    end

    test "accepts a threshold as a case-insensitive string" do
      assert {:ok, %Settings{threshold: :high}} = Settings.validate(%{threshold: "HIGH"})
    end

    for bad <- [0, 6, "2", 2.0, nil] do
      test "rejects attempt_limit #{inspect(bad)}, never clamping to a default" do
        assert Settings.validate(%{attempt_limit: unquote(Macro.escape(bad))}) ==
                 {:error, {:invalid_attempt_limit, unquote(Macro.escape(bad))}}
      end
    end

    test "accepts every integer in 1..5" do
      for n <- 1..5 do
        assert {:ok, %Settings{attempt_limit: ^n}} = Settings.validate(%{attempt_limit: n})
      end
    end

    test "nil model resolves to the analyze model" do
      assert {:ok, %Settings{model: model}} = Settings.validate(%{})
      assert model == SpeckitOrchestrator.Config.model_for(:analyze)
    end

    test "rejects an unknown model alias" do
      assert Settings.validate(%{model: "gpt-5"}) == {:error, {:unknown_model, "gpt-5"}}
    end

    test "accepts a known model alias" do
      assert {:ok, %Settings{model: "opus"}} = Settings.validate(%{model: "opus"})
    end

    test "raises on a non-boolean enabled? — programmer error, not a run-time input" do
      assert_raise ArgumentError, fn -> Settings.validate(%{enabled?: "yes"}) end
    end
  end

  describe "Settings.from_context/1" do
    test "nil context resolves to full defaults" do
      assert {:ok, %Settings{enabled?: true, threshold: :high, attempt_limit: 2}} =
               Settings.from_context(nil)
    end

    test "an absent field falls back to its default" do
      ctx = %RunContext{auto_remediation: false}

      assert {:ok, %Settings{enabled?: false, threshold: :high, attempt_limit: 2}} =
               Settings.from_context(ctx)
    end

    test "a present but invalid field still errors — the only fallback is absence" do
      ctx = %RunContext{auto_remediation_attempt_limit: 9}
      assert Settings.from_context(ctx) == {:error, {:invalid_attempt_limit, 9}}
    end

    test "reads a string-keyed manifest-decoded map" do
      map =
        RunContext.to_map(%RunContext{auto_remediation: false, auto_remediation_threshold: "low"})

      assert {:ok, %Settings{enabled?: false, threshold: :low}} = Settings.from_context(map)
    end

    test "empty map (bare test Coordinator context) resolves to full defaults" do
      assert {:ok, %Settings{enabled?: true}} = Settings.from_context(%{})
    end
  end

  describe "next/2 — row order and outcomes" do
    test "row 1: disabled short-circuits to :gate regardless of everything else" do
      state = base_state(%{settings: %Settings{enabled?: false}})
      signals = %{step: :analyze, outcome: :error, breaker?: true}
      assert {:gate, result_state} = Remediation.next(state, signals)
      assert result_state.attempts_used == 0
    end

    test "row 2 before row 4: an errored analyze step gates even if the breaker tripped" do
      state = base_state()
      signals = %{step: :analyze, outcome: :error, breaker?: true}
      assert {:gate, _state} = Remediation.next(state, signals)
    end

    test "row 3 before row 4: a remediation failure is named even if the breaker tripped" do
      state = base_state()
      signals = %{step: :remediation, outcome: :error, breaker?: true}
      assert {:failed, :remediation_failed, _state} = Remediation.next(state, signals)
    end

    test "row 4: breaker tripped between steps halts" do
      state = base_state()
      signals = %{step: :analyze, outcome: :ok, result: result([]), breaker?: true}
      assert {:halted, :breaker, _state} = Remediation.next(state, signals)
    end

    test "row 5 before row 6: a converged final run advances even on the last allowed attempt" do
      state = base_state(%{settings: %Settings{attempt_limit: 1}, attempts_used: 1})
      signals = %{step: :analyze, outcome: :ok, result: result([])}
      assert {:gate, _state} = Remediation.next(state, signals)
    end

    test "row 6 before row 7: attempts_used never exceeds attempt_limit" do
      state = base_state(%{settings: %Settings{attempt_limit: 1}, attempts_used: 1})
      signals = %{step: :analyze, outcome: :ok, result: result([%{"severity" => "high"}])}
      assert {:gate, {:exhausted, 1}, _state} = Remediation.next(state, signals)
    end

    test "row 7: an at-or-above finding under the limit remediates and increments attempts_used" do
      state = base_state(%{settings: %Settings{attempt_limit: 2}, attempts_used: 0})
      findings = [%{"severity" => "high", "title" => "gap"}]
      signals = %{step: :analyze, outcome: :ok, result: result(findings)}

      assert {:remediate, ^findings, new_state} = Remediation.next(state, signals)
      assert new_state.attempts_used == 1
    end

    test "below-threshold findings never trigger remediation" do
      state = base_state()
      signals = %{step: :analyze, outcome: :ok, result: result([%{"severity" => "low"}])}
      assert {:gate, _state} = Remediation.next(state, signals)
    end

    test "the gate is decided against the last analyze result carried in signals" do
      state = base_state(%{last_result: result([%{"severity" => "high"}])})
      signals = %{step: :analyze, outcome: :ok, result: result([])}
      assert {:gate, new_state} = Remediation.next(state, signals)
      assert new_state.last_result.findings == []
    end
  end

  describe "instruction/2" do
    test "is deterministic for a given input" do
      findings = [%{"severity" => "high", "title" => "gap"}]
      opts = [attempt: 1, limit: 2, threshold: :high]

      assert Remediation.instruction(findings, opts) == Remediation.instruction(findings, opts)
    end

    test "passes findings through verbatim, as pretty-printed JSON" do
      findings = [%{"severity" => "high", "title" => "gap", "detail" => "plan.md missing"}]
      text = Remediation.instruction(findings, attempt: 1, limit: 2, threshold: :high)

      assert text =~ "\"severity\": \"high\""
      assert text =~ "\"detail\": \"plan.md missing\""
      assert text =~ "Attempt 1 of 2"
      assert text =~ "Severity threshold: high"
    end

    test "excludes nothing the caller didn't already filter — below-threshold findings are the caller's job" do
      # instruction/2 renders whatever findings it's given; scoping to
      # at-or-above-threshold is AnalyzeResult.findings_at_or_above/2's job.
      text = Remediation.instruction([], attempt: 1, limit: 2, threshold: :high)
      assert text =~ "[]"
    end
  end

  describe "terminal_reason/2" do
    test "unchanged when the loop never ran (attempts_used == 0)" do
      state = base_state(%{attempts_used: 0})

      assert Remediation.terminal_reason({:halted, :critical_finding}, state) ==
               {:halted, :critical_finding}
    end

    test "unchanged when the loop is disabled (attempts_used stays 0)" do
      state = base_state(%{settings: %Settings{enabled?: false}, attempts_used: 0})

      assert Remediation.terminal_reason({:escalated, :high_findings}, state) ==
               {:escalated, :high_findings}
    end

    test "decorates a halted-on-critical after remediation attempts" do
      state = base_state(%{attempts_used: 2})

      assert Remediation.terminal_reason({:halted, :critical_finding}, state) ==
               {:halted, {:critical_finding, :auto_remediation_exhausted}}
    end

    test "decorates an escalated-on-high after remediation attempts" do
      state = base_state(%{attempts_used: 1})

      assert Remediation.terminal_reason({:escalated, :high_findings}, state) ==
               {:escalated, {:high_findings, :auto_remediation_exhausted}}
    end

    test "leaves an unrelated transition unchanged even after attempts" do
      state = base_state(%{attempts_used: 2})
      assert Remediation.terminal_reason({:cont, :implement}, state) == {:cont, :implement}
    end
  end
end
