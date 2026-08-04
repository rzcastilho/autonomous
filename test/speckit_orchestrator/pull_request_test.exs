defmodule SpeckitOrchestrator.PullRequestTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{PullRequest, Remediation}

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

  # ---- feature 021: pr_text/2 appends Remediation.pr_note/1 -----------------
  #
  # `SpeckitOrchestrator.pr_text/2` is private and Store-backed (exercised
  # end-to-end by feature_runner_test.exs's stacked-PR tests); what's tested
  # here is the append contract both its branches share (contracts/
  # advanced-record.md §5.2): unconditional `<> Remediation.pr_note(record)`,
  # which is `<> ""` — i.e. byte-identical — when the feature wasn't marked.

  @claude_authored_body "## Summary\n- built the ledger"
  @template_fallback_body "Autonomous build of feature 001 (core-ledger) by " <>
                            "speckit_orchestrator.\n\nStacked on `main`."

  @record %{
    policy: "proceed",
    attempts_used: 2,
    attempt_limit: 2,
    threshold: "high",
    max_severity: "high",
    findings: [%{"severity" => "high", "title" => "tasks.md has no task for FR-004"}],
    advanced_at: ~U[2026-07-31 12:00:00Z]
  }

  test "pr_note(nil) leaves either branch's PR body byte-identical to today" do
    assert @claude_authored_body <> Remediation.pr_note(nil) == @claude_authored_body
    assert @template_fallback_body <> Remediation.pr_note(nil) == @template_fallback_body
  end

  test "the findings section renders on the Claude-authored branch" do
    body = @claude_authored_body <> Remediation.pr_note(@record)

    assert body =~ @claude_authored_body
    assert body =~ "Advanced with unresolved analyze findings"
    assert body =~ "tasks.md has no task for FR-004"
  end

  test "the findings section renders on the template-fallback branch" do
    body = @template_fallback_body <> Remediation.pr_note(@record)

    assert body =~ @template_fallback_body
    assert body =~ "Advanced with unresolved analyze findings"
    assert body =~ "tasks.md has no task for FR-004"
  end
end
