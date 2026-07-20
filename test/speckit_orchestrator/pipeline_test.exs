defmodule SpeckitOrchestrator.PipelineTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Pipeline

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
    end

    test "critical? outranks high? (halt beats escalate)" do
      assert Pipeline.next(:analyze, :ok, %{critical?: true, high?: true}) ==
               {:halted, :critical_finding}
    end

    test "high? on a non-analyze phase does NOT escalate" do
      assert Pipeline.next(:plan, :ok, %{high?: true}) == {:cont, :tasks}
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
