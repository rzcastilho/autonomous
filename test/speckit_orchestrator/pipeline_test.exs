defmodule SpeckitOrchestrator.PipelineTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Pipeline, Severity}

  @advances %{
    specify: :clarify,
    clarify: :plan,
    plan: :tasks,
    tasks: :analyze,
    analyze: :implement,
    implement: :converge
  }

  test "phases/0 is the ordered run list and first/0 is its head" do
    assert Pipeline.phases() ==
             [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge]

    assert Pipeline.first() == :specify
  end

  describe "phase?/1" do
    test "true for every member of phases/0" do
      for phase <- Pipeline.phases() do
        assert Pipeline.phase?(phase)
      end
    end

    test "false for a non-phase atom" do
      refute Pipeline.phase?(:bogus)
    end
  end

  describe "parse/1" do
    test "returns {:ok, phase} for every member of phases/0, as a string" do
      for phase <- Pipeline.phases() do
        assert Pipeline.parse(Atom.to_string(phase)) == {:ok, phase}
      end
    end

    test "returns :error for a string naming no known phase (never String.to_atom/1)" do
      assert Pipeline.parse("bogus") == :error
    end

    test "returns :error for a string naming a real but non-ordered atom (e.g. :done)" do
      assert Pipeline.parse("done") == :error
    end

    test "returns :error for a non-string" do
      assert Pipeline.parse(nil) == :error
      assert Pipeline.parse(:specify) == :error
    end
  end

  describe "step_of/1" do
    test "matches each phase's 1-indexed position in phases/0" do
      for {phase, step} <- Enum.with_index(Pipeline.phases(), 1) do
        assert Pipeline.step_of(phase) == step
      end
    end

    test "boundaries" do
      assert Pipeline.step_of(:specify) == 1
      assert Pipeline.step_of(:converge) == 7
    end
  end

  describe "next/3 — :ok advances each phase" do
    for {phase, expected} <- @advances do
      test "#{phase} advances to #{expected}" do
        assert Pipeline.next(unquote(phase), :ok, %{}) == {:cont, unquote(expected)}
      end
    end

    test "converge reaches :done" do
      assert Pipeline.next(:converge, :ok, %{}) == {:done, :done}
    end
  end

  describe "next/3 — :error fails from every phase" do
    for phase <- [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge] do
      test "#{phase} + :error -> failed" do
        assert Pipeline.next(unquote(phase), :error, %{}) == {:failed, {unquote(phase), :error}}
      end
    end
  end

  describe "clarify gate" do
    test "needs_human? at clarify escalates" do
      assert Pipeline.next(:clarify, :ok, %{needs_human?: true}) == {:escalated, :needs_human}
    end

    test "needs_human? false at clarify still advances" do
      assert Pipeline.next(:clarify, :ok, %{needs_human?: false}) == {:cont, :plan}
    end

    test "needs_human? on a non-clarify phase does NOT escalate" do
      assert Pipeline.next(:specify, :ok, %{needs_human?: true}) == {:cont, :clarify}
      assert Pipeline.next(:analyze, :ok, %{needs_human?: true}) == {:cont, :implement}
    end
  end

  describe "analyze gate" do
    test "critical? at analyze halts" do
      assert Pipeline.next(:analyze, :ok, %{critical?: true}) == {:halted, :critical_finding}

      # Feature 021 regression pin (FR-005, SC-003): no exhaustion policy
      # value reaches a Critical finding — it always halts.
      assert Pipeline.next(:analyze, :ok, %{
               critical?: true,
               exhausted?: true,
               exhaustion_policy: :proceed
             }) == {:halted, :critical_finding}
    end

    test "critical? false at analyze advances" do
      assert Pipeline.next(:analyze, :ok, %{critical?: false}) == {:cont, :implement}
    end

    test "critical? on a non-analyze phase does NOT halt" do
      assert Pipeline.next(:clarify, :ok, %{critical?: true}) == {:cont, :plan}
    end
  end

  describe "analyze high gate" do
    test "high? at analyze escalates for a human" do
      assert Pipeline.next(:analyze, :ok, %{high?: true}) == {:escalated, :high_findings}

      # Feature 021 regression pin (SC-002): the exhaustion policy — absent,
      # or explicitly :escalate — must not change this pre-021 case.
      assert Pipeline.next(:analyze, :ok, %{high?: true, exhaustion_policy: :escalate}) ==
               {:escalated, :high_findings}

      assert Pipeline.next(:analyze, :ok, %{high?: true, exhausted?: true}) ==
               {:escalated, :high_findings}
    end

    test "critical? outranks high? (halt beats escalate)" do
      assert Pipeline.next(:analyze, :ok, %{critical?: true, high?: true}) ==
               {:halted, :critical_finding}
    end

    test "high? on a non-analyze phase does NOT escalate" do
      assert Pipeline.next(:plan, :ok, %{high?: true}) == {:cont, :tasks}
    end
  end

  # The run's severity threshold is one knob: it decides both when
  # auto-remediation runs and when the gate diverts to a human (amended
  # Constitution Principle V, 017 FR-006).
  describe "analyze gate severity threshold" do
    test "an absent threshold defaults to :high — the pre-threshold gate exactly" do
      assert Pipeline.next(:analyze, :ok, %{high?: true}) == {:escalated, :high_findings}

      assert Pipeline.next(:analyze, :ok, %{high?: true, gate_threshold: :high}) ==
               {:escalated, :high_findings}

      # Feature 021 regression pin (SC-002): an absent/explicit-:escalate
      # exhaustion policy must not change this pre-021, pre-threshold case
      # even once exhausted.
      assert Pipeline.next(:analyze, :ok, %{
               high?: true,
               gate_threshold: :high,
               exhausted?: true,
               exhaustion_policy: :escalate
             }) == {:escalated, :high_findings}
    end

    test "threshold :critical lets a High finding advance instead of escalating" do
      assert Pipeline.next(:analyze, :ok, %{high?: true, gate_threshold: :critical}) ==
               {:cont, :implement}
    end

    test "threshold :critical still halts on a Critical finding" do
      assert Pipeline.next(:analyze, :ok, %{critical?: true, gate_threshold: :critical}) ==
               {:halted, :critical_finding}

      assert Pipeline.next(:analyze, :ok, %{
               critical?: true,
               high?: true,
               gate_threshold: :critical
             }) == {:halted, :critical_finding}
    end

    test "Critical outranks every threshold, so it always halts" do
      for threshold <- [:low, :medium, :high, :critical] do
        assert Pipeline.next(:analyze, :ok, %{critical?: true, gate_threshold: threshold}) ==
                 {:halted, :critical_finding}
      end
    end

    test "a threshold below :high creates no new terminal state (FR-006)" do
      for threshold <- [:low, :medium] do
        assert Pipeline.next(:analyze, :ok, %{high?: true, gate_threshold: threshold}) ==
                 {:escalated, :high_findings}

        # Low/Medium findings have no gate signal at all, so they advance —
        # exactly as they do today.
        assert Pipeline.next(:analyze, :ok, %{gate_threshold: threshold}) == {:cont, :implement}
      end
    end
  end

  # Feature 021: the exhaustion policy reaches row 3 of the amended analyze
  # gate only when the loop actually exhausted its attempts on a High finding
  # the threshold would otherwise escalate. Absent signals (`exhausted?`,
  # `exhaustion_policy`) must reproduce the pre-021 gate exactly.
  describe "exhaustion policy gate (feature 021)" do
    test "high? + exhausted? + policy :proceed at threshold :high advances (FR-004)" do
      assert Pipeline.next(:analyze, :ok, %{
               high?: true,
               exhausted?: true,
               exhaustion_policy: :proceed,
               gate_threshold: :high
             }) == {:cont, :implement}
    end

    test "the same signals with exhaustion_policy :escalate still escalates (FR-003)" do
      assert Pipeline.next(:analyze, :ok, %{
               high?: true,
               exhausted?: true,
               exhaustion_policy: :escalate,
               gate_threshold: :high
             }) == {:escalated, :high_findings}
    end

    test "the same signals with exhausted? absent still escalates (SC-002)" do
      assert Pipeline.next(:analyze, :ok, %{
               high?: true,
               exhaustion_policy: :proceed,
               gate_threshold: :high
             }) == {:escalated, :high_findings}
    end

    test "the same signals with exhaustion_policy absent still escalates (FR-002 default)" do
      assert Pipeline.next(:analyze, :ok, %{
               high?: true,
               exhausted?: true,
               gate_threshold: :high
             }) == {:escalated, :high_findings}
    end

    test "exhausted? + policy :proceed at a below-threshold gate_threshold advances anyway (row 2, unchanged)" do
      assert Pipeline.next(:analyze, :ok, %{
               high?: true,
               exhausted?: true,
               exhaustion_policy: :escalate,
               gate_threshold: :critical
             }) == {:cont, :implement}
    end

    test "I1 — critical? always halts, for every threshold and every policy (SC-003)" do
      for threshold <- Severity.values(),
          policy <- [:escalate, :proceed],
          exhausted? <- [true, false] do
        assert Pipeline.next(:analyze, :ok, %{
                 critical?: true,
                 high?: true,
                 gate_threshold: threshold,
                 exhaustion_policy: policy,
                 exhausted?: exhausted?
               }) == {:halted, :critical_finding}
      end
    end

    test "I2 — exhausted? absent or false reproduces the pre-021 outcome for the same map" do
      base = %{high?: true, gate_threshold: :high}

      for exhausted? <- [nil, false],
          policy <- [:escalate, :proceed] do
        signals =
          base
          |> Map.put(:exhaustion_policy, policy)
          |> then(fn s ->
            if is_nil(exhausted?), do: s, else: Map.put(s, :exhausted?, exhausted?)
          end)

        assert Pipeline.next(:analyze, :ok, signals) == {:escalated, :high_findings}
      end
    end

    test "I3 — policy :escalate reproduces the pre-021 outcome for the same map, exhausted or not" do
      for threshold <- Severity.values(), exhausted? <- [true, false] do
        signals = %{
          high?: true,
          gate_threshold: threshold,
          exhaustion_policy: :escalate,
          exhausted?: exhausted?
        }

        expected =
          if Severity.at_or_above?(:high, threshold),
            do: {:escalated, :high_findings},
            else: {:cont, :implement}

        assert Pipeline.next(:analyze, :ok, signals) == expected
      end
    end

    test "I4 — the policy never changes a non-analyze phase's outcome" do
      for phase <- [:specify, :clarify, :plan, :tasks, :implement, :converge] do
        assert Pipeline.next(phase, :ok, %{
                 high?: true,
                 exhausted?: true,
                 exhaustion_policy: :proceed
               }) == Pipeline.next(phase, :ok, %{})
      end
    end

    test "I4 — the policy never changes an :error outcome at analyze" do
      assert Pipeline.next(:analyze, :error, %{
               high?: true,
               exhausted?: true,
               exhaustion_policy: :proceed
             }) == {:failed, {:analyze, :error}}
    end
  end

  describe "artifact gate" do
    test "a missing artifact fails the phase that should have written it" do
      for {phase, artifact} <- [
            {:plan, "specs/**/plan.md"},
            {:tasks, "specs/**/tasks.md"},
            {:implement, "implementation changes"}
          ] do
        assert Pipeline.next(phase, :ok, %{missing_artifact: artifact}) ==
                 {:failed, {:missing_artifact, phase, artifact}}
      end
    end

    test "no missing_artifact signal advances normally" do
      assert Pipeline.next(:plan, :ok, %{}) == {:cont, :tasks}
    end

    # The false-green this gate exists to close: a phase can refuse or ask an
    # unanswerable question and still return a perfectly successful transcript.
    test "a successful outcome does not rescue a phase that wrote nothing" do
      assert Pipeline.next(:plan, :ok, %{missing_artifact: "specs/**/plan.md"}) ==
               {:failed, {:missing_artifact, :plan, "specs/**/plan.md"}}
    end
  end

  describe "converge gate" do
    test "not_ready? at converge fails instead of reaching :done" do
      assert Pipeline.next(:converge, :ok, %{not_ready?: true}) == {:failed, :converge_not_ready}
    end

    test "not_ready? false at converge reaches :done" do
      assert Pipeline.next(:converge, :ok, %{not_ready?: false}) == {:done, :done}
    end

    test "not_ready? on a non-converge phase does NOT fail" do
      assert Pipeline.next(:plan, :ok, %{not_ready?: true}) == {:cont, :tasks}
    end
  end

  test "error takes precedence over gate signals" do
    assert Pipeline.next(:clarify, :error, %{needs_human?: true}) == {:failed, {:clarify, :error}}
    assert Pipeline.next(:analyze, :error, %{critical?: true}) == {:failed, {:analyze, :error}}
  end

  test "next/3 defaults signals to empty map (arity-2 friendly call)" do
    assert Pipeline.next(:specify, :ok) == {:cont, :clarify}
  end

  test "a full happy-path walk reaches :done" do
    walk = fn phase, walk ->
      case Pipeline.next(phase, :ok, %{}) do
        {:cont, next} -> walk.(next, walk)
        terminal -> terminal
      end
    end

    assert walk.(Pipeline.first(), walk) == {:done, :done}
  end
end
