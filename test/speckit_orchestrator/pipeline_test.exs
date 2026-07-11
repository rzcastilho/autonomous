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
