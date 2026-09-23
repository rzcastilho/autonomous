defmodule SpeckitOrchestrator.PublishOutcomeTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.PublishOutcome

  describe "describe/1" do
    test ":empty_branch" do
      reason =
        {:publish_failed, :empty_branch,
         %{
           branch: "feature/001-core-ledger",
           base: "main",
           branch_sha: "abc1234",
           base_sha: "abc1234"
         }}

      assert PublishOutcome.describe(reason) ==
               "publish_failed :empty_branch — feature/001-core-ledger has no commits beyond main (abc1234 = abc1234)"
    end

    test ":push_failed carries verbatim output, unmodified" do
      reason =
        {:publish_failed, :push_failed,
         %{
           branch: "feature/001-core-ledger",
           remote: "origin",
           output: "! [rejected]        feature/001-core-ledger -> feature/001-core-ledger (stale info)"
         }}

      assert PublishOutcome.describe(reason) ==
               "publish_failed :push_failed — git push origin feature/001-core-ledger:\n" <>
                 "! [rejected]        feature/001-core-ledger -> feature/001-core-ledger (stale info)"
    end

    test ":pr_failed names the gh invocation and exit status" do
      reason =
        {:publish_failed, :pr_failed,
         %{
           branch: "feature/001-core-ledger",
           base: "main",
           exit: 1,
           output: "pull request create failed: GraphQL: Head sha can't be blank"
         }}

      assert PublishOutcome.describe(reason) ==
               "publish_failed :pr_failed — gh pr create --head feature/001-core-ledger --base main (exit 1):\n" <>
                 "pull request create failed: GraphQL: Head sha can't be blank"
    end

    test "branch_drift on a named observed branch" do
      reason =
        {:branch_drift, :specify,
         %{expected: "feature/001-core-ledger", observed: "NNN-core-ledger"}}

      assert PublishOutcome.describe(reason) ==
               "branch_drift in :specify — expected feature/001-core-ledger, HEAD on NNN-core-ledger"
    end

    test "branch_drift renders a detached HEAD as detached@<sha>" do
      reason =
        {:branch_drift, :implement,
         %{expected: "feature/001-core-ledger", observed: {:detached, "abc1234"}}}

      assert PublishOutcome.describe(reason) ==
               "branch_drift in :implement — expected feature/001-core-ledger, HEAD on detached@abc1234"
    end

    test "anything else falls back to nil, so the caller can inspect/1 it" do
      assert PublishOutcome.describe(:some_other_reason) == nil
      assert PublishOutcome.describe({:critical_finding, :auto_remediation_exhausted}) == nil
      assert PublishOutcome.describe(nil) == nil
    end
  end
end
