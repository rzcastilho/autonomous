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

    test "defaults exhaustion_policy to :escalate when absent (FR-002)" do
      assert {:ok, %Settings{exhaustion_policy: :escalate}} = Settings.validate(%{})
    end

    test "accepts exhaustion_policy atoms :escalate and :proceed" do
      assert {:ok, %Settings{exhaustion_policy: :escalate}} =
               Settings.validate(%{exhaustion_policy: :escalate})

      assert {:ok, %Settings{exhaustion_policy: :proceed}} =
               Settings.validate(%{exhaustion_policy: :proceed})
    end

    test "accepts exhaustion_policy as a case-insensitive string" do
      assert {:ok, %Settings{exhaustion_policy: :proceed}} =
               Settings.validate(%{exhaustion_policy: "Proceed"})

      assert {:ok, %Settings{exhaustion_policy: :escalate}} =
               Settings.validate(%{exhaustion_policy: "ESCALATE"})
    end

    test "rejects an unrecognized exhaustion_policy, never clamping to a default (FR-010)" do
      assert Settings.validate(%{exhaustion_policy: "proceeed"}) ==
               {:error, {:invalid_exhaustion_policy, "proceeed"}}

      assert Settings.validate(%{exhaustion_policy: :bogus}) ==
               {:error, {:invalid_exhaustion_policy, :bogus}}
    end
  end

  describe "Settings.parse_policy/1" do
    test "atoms pass through" do
      assert Settings.parse_policy(:escalate) == {:ok, :escalate}
      assert Settings.parse_policy(:proceed) == {:ok, :proceed}
    end

    test "strings match case-insensitively" do
      assert Settings.parse_policy("escalate") == {:ok, :escalate}
      assert Settings.parse_policy("PROCEED") == {:ok, :proceed}
    end

    test "anything else errors, never String.to_atom/1" do
      assert Settings.parse_policy("proceeed") == :error
      assert Settings.parse_policy(nil) == :error
      assert Settings.parse_policy(42) == :error
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

    test "an absent exhaustion_policy falls back to :escalate (feature 021)" do
      assert {:ok, %Settings{exhaustion_policy: :escalate}} =
               Settings.from_context(%RunContext{})
    end

    test "a recorded exhaustion_policy string is decoded" do
      ctx = %RunContext{auto_remediation_exhaustion_policy: "proceed"}
      assert {:ok, %Settings{exhaustion_policy: :proceed}} = Settings.from_context(ctx)
    end

    test "a present but invalid exhaustion_policy still errors" do
      ctx = %RunContext{auto_remediation_exhaustion_policy: "bogus"}
      assert Settings.from_context(ctx) == {:error, {:invalid_exhaustion_policy, "bogus"}}
    end

    test "round-trips through RunContext.to_map/1" do
      map = RunContext.to_map(%RunContext{auto_remediation_exhaustion_policy: "proceed"})
      assert {:ok, %Settings{exhaustion_policy: :proceed}} = Settings.from_context(map)
    end
  end

  describe "next/2 — row order and outcomes" do
    test "row 1: disabled short-circuits to :gate regardless of everything else" do
      state = base_state(%{settings: %Settings{enabled?: false}})
      signals = %{step: :analyze, outcome: :error, breaker?: true}
      assert {:gate, result_state} = Remediation.next(state, signals)
      assert result_state.attempts_used == 0
    end

    # Feature 021 regression pin (FR-015): disabled means zero attempts, for
    # either exhaustion_policy value — there is no loop for the policy to act
    # on, so `attempts_used` stays 0 regardless of which policy is configured.
    for policy <- [:escalate, :proceed] do
      test "row 1: disabled stays at 0 attempts regardless of exhaustion_policy #{policy} (FR-015)" do
        state =
          base_state(%{settings: %Settings{enabled?: false, exhaustion_policy: unquote(policy)}})

        signals = %{step: :analyze, outcome: :ok, result: result([%{"severity" => "high"}])}
        assert {:gate, result_state} = Remediation.next(state, signals)
        assert result_state.attempts_used == 0
      end
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

  describe "exhaustion_advance/2 (feature 021, contracts/advanced-record.md §1.1)" do
    defp advance_state(overrides \\ %{}) do
      Map.merge(
        %{
          attempts_used: 2,
          attempt_limit: 2,
          findings: [%{"severity" => "high", "title" => "gap"}],
          advanced_at: ~U[2026-07-31 12:00:00Z]
        },
        overrides
      )
    end

    test "marks the one observable cell: exhausted + :proceed + high at threshold :high" do
      signals = %{
        exhausted?: true,
        exhaustion_policy: :proceed,
        high?: true,
        critical?: false,
        gate_threshold: :high
      }

      assert {:mark, record} = Remediation.exhaustion_advance(signals, advance_state())
      assert record.policy == "proceed"
      assert record.attempts_used == 2
      assert record.attempt_limit == 2
      assert record.threshold == "high"
      assert record.max_severity == "high"
      assert record.findings == [%{"severity" => "high", "title" => "gap"}]
      assert record.advanced_at == ~U[2026-07-31 12:00:00Z]
    end

    test "marks when the gate_threshold is below :high too — the gate would still have escalated" do
      for threshold <- [:low, :medium] do
        signals = %{
          exhausted?: true,
          exhaustion_policy: :proceed,
          high?: true,
          critical?: false,
          gate_threshold: threshold
        }

        assert {:mark, _record} = Remediation.exhaustion_advance(signals, advance_state())
      end
    end

    test "does not mark at threshold :critical — the gate advances anyway (FR-009)" do
      signals = %{
        exhausted?: true,
        exhaustion_policy: :proceed,
        high?: true,
        critical?: false,
        gate_threshold: :critical
      }

      assert Remediation.exhaustion_advance(signals, advance_state()) == :none
    end

    test "does not mark a Critical finding — halted before this is ever consulted (FR-005)" do
      signals = %{
        exhausted?: true,
        exhaustion_policy: :proceed,
        high?: true,
        critical?: true,
        gate_threshold: :high
      }

      assert Remediation.exhaustion_advance(signals, advance_state()) == :none
    end

    test "does not mark below-threshold residuals — the gate advances anyway (FR-009)" do
      signals = %{
        exhausted?: true,
        exhaustion_policy: :proceed,
        high?: false,
        critical?: false,
        gate_threshold: :high
      }

      assert Remediation.exhaustion_advance(signals, advance_state()) == :none
    end

    test "does not mark under policy :escalate — escalated, not advanced (FR-003)" do
      signals = %{
        exhausted?: true,
        exhaustion_policy: :escalate,
        high?: true,
        critical?: false,
        gate_threshold: :high
      }

      assert Remediation.exhaustion_advance(signals, advance_state()) == :none
    end

    test "does not mark a clean/converged analyze run (never exhausted, FR-006)" do
      signals = %{
        exhausted?: false,
        exhaustion_policy: :proceed,
        high?: true,
        critical?: false,
        gate_threshold: :high
      }

      assert Remediation.exhaustion_advance(signals, advance_state()) == :none
    end

    test "an absent exhausted?/exhaustion_policy never marks (SC-002 defaults)" do
      assert Remediation.exhaustion_advance(
               %{high?: true, gate_threshold: :high},
               advance_state()
             ) ==
               :none
    end
  end

  describe "pr_note/1" do
    test "nil renders the empty string" do
      assert Remediation.pr_note(nil) == ""
    end

    test "renders the policy, attempts, threshold, and every finding verbatim" do
      record = %{
        policy: "proceed",
        attempts_used: 2,
        attempt_limit: 2,
        threshold: "high",
        max_severity: "high",
        findings: [
          %{"severity" => "high", "title" => "tasks.md has no task for FR-004"},
          %{"severity" => "high", "title" => "plan.md wording nit"}
        ],
        advanced_at: ~U[2026-07-31 12:00:00Z]
      }

      note = Remediation.pr_note(record)

      assert note =~ "Advanced with unresolved analyze findings"
      assert note =~ "auto_remediation_exhaustion_policy: proceed"
      assert note =~ "2 of 2"
      assert note =~ "Severity threshold: `high`"
      assert note =~ "tasks.md has no task for FR-004"
      assert note =~ "plan.md wording nit"
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
