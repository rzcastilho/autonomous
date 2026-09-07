defmodule SpeckitOrchestrator.CheckpointTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Checkpoint

  describe "armed?/1" do
    test "true only for specify/plan/tasks" do
      assert Checkpoint.armed?(:specify)
      assert Checkpoint.armed?(:plan)
      assert Checkpoint.armed?(:tasks)
    end

    test "false for every other phase" do
      refute Checkpoint.armed?(:clarify)
      refute Checkpoint.armed?(:analyze)
      refute Checkpoint.armed?(:implement)
      refute Checkpoint.armed?(:converge)
    end
  end

  describe "verdict/3 — armed phases" do
    for phase <- [:specify, :plan, :tasks] do
      test "#{phase}: absent at start + noop commit fails with {:empty_checkpoint, #{phase}}" do
        assert Checkpoint.verdict(unquote(phase), true, :noop) ==
                 {:failed, {:empty_checkpoint, unquote(phase)}}
      end

      test "#{phase}: absent at start + ok commit advances" do
        assert Checkpoint.verdict(unquote(phase), true, :ok) == :advance
      end

      test "#{phase}: absent at start + git failure advances (not evidence of nothing written)" do
        assert Checkpoint.verdict(unquote(phase), true, {:error, :boom}) == :advance
      end

      test "#{phase}: present at start advances regardless of commit result (FR-014a)" do
        assert Checkpoint.verdict(unquote(phase), false, :noop) == :advance
        assert Checkpoint.verdict(unquote(phase), false, :ok) == :advance
        assert Checkpoint.verdict(unquote(phase), false, {:error, :boom}) == :advance
      end
    end
  end

  describe "verdict/3 — unarmed phases (FR-015)" do
    for phase <- [:clarify, :analyze, :implement, :converge] do
      test "#{phase}: always advances regardless of absent?/commit_result" do
        assert Checkpoint.verdict(unquote(phase), true, :noop) == :advance
        assert Checkpoint.verdict(unquote(phase), true, :ok) == :advance
        assert Checkpoint.verdict(unquote(phase), false, :noop) == :advance
        assert Checkpoint.verdict(unquote(phase), false, {:error, :boom}) == :advance
      end
    end
  end
end
