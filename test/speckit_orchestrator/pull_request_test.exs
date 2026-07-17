defmodule SpeckitOrchestrator.PullRequestTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.PullRequest

  test "build_args produces the gh pr create argv (head/base/title/body)" do
    args =
      PullRequest.build_args(%{
        head: "feature/002-vote",
        base: "feature/001-core",
        title: "feat(002-vote): autonomous build",
        body: "Stacked on `feature/001-core`."
      })

    assert args == [
             "pr",
             "create",
             "--head",
             "feature/002-vote",
             "--base",
             "feature/001-core",
             "--title",
             "feat(002-vote): autonomous build",
             "--body",
             "Stacked on `feature/001-core`."
           ]
  end
end
