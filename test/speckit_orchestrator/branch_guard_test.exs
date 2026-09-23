defmodule SpeckitOrchestrator.BranchGuardTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.BranchGuard

  describe "check/2" do
    test "the same branch name is :ok" do
      assert BranchGuard.check("feature/001-core-ledger", "feature/001-core-ledger") == :ok
    end

    test "a different branch name is drift" do
      assert BranchGuard.check("feature/001-core-ledger", "feature/002-other") ==
               {:drift, %{expected: "feature/001-core-ledger", observed: "feature/002-other"}}
    end

    test "a detached HEAD is drift, never treated as a match" do
      assert BranchGuard.check("feature/001-core-ledger", {:detached, "abc1234"}) ==
               {:drift, %{expected: "feature/001-core-ledger", observed: {:detached, "abc1234"}}}
    end

    test "an unrelated stray branch name is drift" do
      assert BranchGuard.check("feature/015-core-ledger", "NNN-core-ledger") ==
               {:drift, %{expected: "feature/015-core-ledger", observed: "NNN-core-ledger"}}
    end
  end
end
