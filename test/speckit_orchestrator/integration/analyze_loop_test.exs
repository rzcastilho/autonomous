defmodule SpeckitOrchestrator.Integration.AnalyzeLoopTest do
  @moduledoc """
  LIVE, opt-in coverage for the analyze auto-remediation loop
  (`specs/017-analyze-auto-remediation`, quickstart.md "US1 Integration").

  Every test here drives the **real** `claude` CLI through the harness against a
  real Spec Kit repo, so each is `@tag :integration` — excluded by default and
  run only with:

      mise exec -- mix test test/speckit_orchestrator/integration/analyze_loop_test.exs \\
        --include integration

  The repo under test is named by `SPECKIT_FIXTURE_REPO` and must already carry
  a feature whose `specify → tasks` artifacts exist (the loop starts at
  `:analyze`, it does not build the feature); `SPECKIT_FIXTURE_FEATURE_ID` /
  `SPECKIT_FIXTURE_FEATURE_SLUG` select it, defaulting to `001` / `smoke`.

  A live model's analyze output is not deterministic, so these assertions are
  about the loop's **structure**, not about a particular verdict: whichever
  branch the run takes, the artifacts and the terminal shape must be one of the
  ones the contract enumerates. Whether the run converged or exhausted is
  reported, not asserted.
  """

  # async: false — drives a real CLI against a shared fixture repo.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Feature, FeatureRunner, Ledger, RunContext, Worktree}

  @analyze_step 5

  defp fixture_repo do
    System.get_env("SPECKIT_FIXTURE_REPO") ||
      flunk("set SPECKIT_FIXTURE_REPO to a Spec Kit repo with a feature built through tasks")
  end

  defp fixture_feature(repo) do
    id = System.get_env("SPECKIT_FIXTURE_FEATURE_ID") || "001"
    slug = System.get_env("SPECKIT_FIXTURE_FEATURE_SLUG") || "smoke"

    %Feature{id: id, slug: slug, path: Path.join(repo, "docs/breakdown/#{id}-#{slug}.md")}
  end

  defp worktree_for(repo, feature) do
    root = Path.join(System.tmp_dir!(), "analyze_loop_#{System.unique_integer([:positive])}")
    {:ok, wt} = Worktree.create(feature, repo: repo, worktree_root: root)
    on_exit(fn -> File.rm_rf(root) end)
    wt
  end

  defp logs(worktree), do: Path.join(worktree.path, ".speckit_logs")

  defp transcripts(worktree, glob),
    do: worktree |> logs() |> Path.join(glob) |> Path.wildcard() |> Enum.sort()

  @tag :integration
  @tag timeout: :infinity
  test "LIVE: an enabled loop runs analyze, remediates at-or-above findings, and re-analyzes" do
    repo = fixture_repo()
    feature = fixture_feature(repo)
    worktree = worktree_for(repo, feature)
    {:ok, ledger} = Ledger.start_link(budget: 25.0, name: nil)

    context = %RunContext{
      auto_remediation: true,
      auto_remediation_threshold: "high",
      auto_remediation_attempt_limit: 2
    }

    result =
      FeatureRunner.run(feature,
        worktree: worktree,
        ledger: ledger,
        notify: self(),
        start_phase: :analyze,
        run_context: context
      )

    # The final analyze run is always written under the plain label, at every
    # point in the loop (contracts/analyze_loop.md §4) — this is what
    # `Recovery.Evidence` and `TranscriptsLive` keep reading.
    final = Path.join(logs(worktree), "0#{@analyze_step}-analyze.md")
    assert File.exists?(final), "expected the final analyze transcript at #{final}"

    attempts = transcripts(worktree, "0#{@analyze_step}-remediation-a*.md")
    analyze_copies = transcripts(worktree, "0#{@analyze_step}-analyze-a*.md")

    # Attempt budget is a hard ceiling (SC-003) and each attempt is individually
    # recorded (FR-012).
    assert length(attempts) <= 2

    # k remediation attempts imply k+1 analyze runs, each with its own copy —
    # unless the loop never entered, in which case there are neither.
    if attempts == [] do
      assert analyze_copies == []
    else
      assert length(analyze_copies) == length(attempts) + 1

      for {path, k} <- Enum.with_index(attempts, 1) do
        assert Path.basename(path) == "0#{@analyze_step}-remediation-a#{k}.md"
        body = File.read!(path)
        assert body =~ "### instruction"
        assert body =~ "### step output"
      end
    end

    # Whatever the live model decided, the terminal must be one of the shapes
    # the contract enumerates — a converged advance, a gate diversion (bare or
    # decorated with exhausted auto-remediation), or a loop-specific stop.
    assert result.status in [:done, :escalated, :halted, :failed]

    case result.reason do
      {:high_findings, :auto_remediation_exhausted} -> assert result.status == :escalated
      {:critical_finding, :auto_remediation_exhausted} -> assert result.status == :halted
      :remediation_failed -> assert result.status == :failed
      _other -> :ok
    end

    # Decorated reasons are only reachable once an attempt was actually spent.
    if match?({_, :auto_remediation_exhausted}, result.reason), do: refute(attempts == [])

    IO.puts(
      "\nLIVE analyze loop: #{length(attempts)} remediation attempt(s), " <>
        "terminal #{result.status} #{inspect(result.reason)}"
    )
  end

  @tag :integration
  @tag timeout: :infinity
  test "LIVE: the loop disabled runs analyze exactly once and writes only the plain transcript" do
    repo = fixture_repo()
    feature = fixture_feature(repo)
    worktree = worktree_for(repo, feature)
    {:ok, ledger} = Ledger.start_link(budget: 25.0, name: nil)

    result =
      FeatureRunner.run(feature,
        worktree: worktree,
        ledger: ledger,
        notify: self(),
        start_phase: :analyze,
        run_context: %RunContext{auto_remediation: false}
      )

    # Pre-017 behaviour byte-for-byte (FR-010, SC-007a): one analyze run, one
    # transcript, an undecorated reason.
    assert File.exists?(Path.join(logs(worktree), "0#{@analyze_step}-analyze.md"))
    assert transcripts(worktree, "0#{@analyze_step}-remediation-a*.md") == []
    assert transcripts(worktree, "0#{@analyze_step}-analyze-a*.md") == []
    refute match?({_, :auto_remediation_exhausted}, result.reason)
  end
end
