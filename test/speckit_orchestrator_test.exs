defmodule SpeckitOrchestratorTest do
  # async: false — starts a named Coordinator via the facade. StoreCase (not
  # plain ExUnit.Case) because `run/1`'s preflight refuses
  # `{:parked_run, …}` for a repository that already has one, and the store is
  # node-global: any earlier test in the suite that parked a run (several
  # console and store tests do) made this one fail on a repository it never
  # touched. Clearing the tables first is exactly what StoreCase exists for.
  use SpeckitOrchestrator.StoreCase, async: false
  import ExUnit.CaptureIO

  alias SpeckitOrchestrator.{Config, Feature, RepoIdentity, Store, Worktree}
  alias SpeckitOrchestrator.Store.Writer

  test "run/1 with an injected runner drives the backlog to completion; status/0 reflects it" do
    features = [
      %Feature{id: "001", number: 1, slug: "a", path: "a.md"},
      %Feature{id: "002", number: 2, slug: "b", path: "b.md"}
    ]

    fake = fn feature, notify -> notify.(feature.id, :done, nil) end

    {:ok, pid} = SpeckitOrchestrator.run(features: features, runner: fake, owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["001", "002"]
    assert SpeckitOrchestrator.status().finished?

    out = capture_io(fn -> SpeckitOrchestrator.print_status() end)
    assert out =~ "FEATURE"
    assert out =~ "001"
  end

  # ---- 029 US4 (FR-001): interactive-clarify preflight ----------------------

  test "run/1 refuses an out-of-range interactive-clarify setting before any store write" do
    features = [%Feature{id: "801", number: 801, slug: "a", path: "a.md"}]
    repo_id = RepoIdentity.partition(Config.repo())

    assert {:error, {:preflight, [{:invalid_answer_timeout, 30}]}} =
             SpeckitOrchestrator.run(features: features, clarify_answer_timeout_s: 30)

    assert {:error, {:preflight, [{:invalid_max_rounds, 6}]}} =
             SpeckitOrchestrator.run(features: features, clarify_max_rounds: 6)

    assert {:ok, []} = Store.runs(repo_id)
  end

  # ---- spec number allocation flow (022) -------------------------------------
  #
  # No `:runner`/`:executor` seam here — real `Worktree.create/2` runs, driven
  # by `default_executor/5`, so the allocation wiring itself executes. Clearing
  # `:jido_harness, :providers` makes `:specify` fail immediately (a harness
  # invocation error), which is enough to prove what the branch/worktree ended
  # up named without driving a whole fake pipeline to `:done`.

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_repo do
    repo =
      Path.join(System.tmp_dir!(), "speckit_alloc_repo_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Constitution\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    File.mkdir_p!(Path.join(repo, ".claude/hooks"))
    File.write!(Path.join(repo, ".claude/hooks/scope_guard.py"), "")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp with_broken_harness do
    original = Application.get_env(:jido_harness, :providers)
    Application.put_env(:jido_harness, :providers, %{})
    on_exit(fn -> Application.put_env(:jido_harness, :providers, original) end)
  end

  defp point_config_at(repo, root) do
    prev = for k <- [:repo, :worktree_root], do: {k, Application.get_env(:speckit_orchestrator, k)}
    Application.put_env(:speckit_orchestrator, :repo, repo)
    Application.put_env(:speckit_orchestrator, :worktree_root, root)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:speckit_orchestrator, k, v),
          else: Application.delete_env(:speckit_orchestrator, k)
      end
    end)
  end

  defp branch_exists?(repo, branch),
    do: match?({_, 0}, System.cmd("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]))

  test "fresh allocate: a colliding wave number gets its own spec number and branch" do
    repo = scaffolded_repo()
    root = Path.join(System.tmp_dir!(), "speckit_alloc_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    point_config_at(repo, root)
    with_broken_harness()

    # An earlier wave already built "001" against this target.
    File.mkdir_p!(Path.join(repo, "specs/001-existing"))
    File.write!(Path.join(repo, "specs/001-existing/spec.md"), "already here\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "earlier wave"])

    feature = %Feature{id: "001", number: 1, slug: "newthing", path: "001-newthing.md"}

    {:ok, pid} = SpeckitOrchestrator.run(features: [feature], owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 10_000
    assert report.failed == ["001"]

    refute branch_exists?(repo, "feature/001-newthing")
    assert branch_exists?(repo, "feature/002-newthing")

    repo_id = RepoIdentity.partition(repo)
    {:ok, [%{run_id: run_id} | _]} = Store.runs(repo_id)
    assert Store.spec_number({repo_id, run_id}, "001") == 2
  end

  test "a run with no store (run_key: nil) allocates in memory and still avoids the collision" do
    repo = scaffolded_repo()
    root = Path.join(System.tmp_dir!(), "speckit_alloc_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    point_config_at(repo, root)
    with_broken_harness()

    File.mkdir_p!(Path.join(repo, "specs/001-existing"))
    File.write!(Path.join(repo, "specs/001-existing/spec.md"), "already here\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "earlier wave"])

    feature = %Feature{id: "001", number: 1, slug: "newthing", path: "001-newthing.md"}

    {:ok, pid} = SpeckitOrchestrator.run(features: [feature], owner: self(), run_key: nil)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 10_000
    assert report.failed == ["001"]

    refute branch_exists?(repo, "feature/001-newthing")
    assert branch_exists?(repo, "feature/002-newthing")
  end

  test "reuse: a recorded spec number is reused with no existence check, even though its directory already exists" do
    repo = scaffolded_repo()
    root = Path.join(System.tmp_dir!(), "speckit_alloc_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    point_config_at(repo, root)
    with_broken_harness()

    # A directory already sitting where the allocated number's spec dir goes
    # would refuse a *fresh* allocation — reuse must not even look.
    File.mkdir_p!(Path.join(repo, "specs/001-existing"))
    File.write!(Path.join(repo, "specs/001-existing/spec.md"), "already here\n")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "earlier wave"])

    feature = %Feature{id: "003", number: 3, slug: "resumed", path: "003-resumed.md"}
    repo_id = RepoIdentity.partition(repo)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{
            feature_id: "003",
            slug: "resumed",
            path: "003-resumed.md",
            number: 3,
            group: :backlog,
            created_at: nil
          }
        ],
        settings: %{budget_usd: 100.0},
        scope: :ad_hoc,
        layout: %{}
      })

    run_key = {repo_id, run_id}
    :ok = Writer.record_spec_number(run_key, "003", 15)

    # Pre-create the worktree at the recorded spec dir, as if a prior phase
    # already ran there.
    {:ok, wt} =
      Worktree.create(%{feature | spec_number: 15}, repo: repo, worktree_root: root)

    File.write!(Path.join(wt.path, "checkpoint.txt"), "prior phase output\n")
    git!(wt.path, ["add", "-A"])
    git!(wt.path, ["-c", "user.name=t", "-c", "user.email=t@e.com", "commit", "-q", "-m", "prior"])

    {:ok, pid} =
      SpeckitOrchestrator.run(features: [feature], owner: self(), run_key: run_key)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 10_000
    assert report.failed == ["003"]

    # Reused 15, never refused, never reallocated to 2 (the fresh answer).
    assert Store.spec_number(run_key, "003") == 15
    assert branch_exists?(repo, "feature/015-resumed")
    refute branch_exists?(repo, "feature/002-resumed")
  end

  # ---- pending_questions/0 and answer/3 — iex parity (029 US3) ---------------
  #
  # These are the exact functions `EscalationsLive`'s "answer" event handler
  # calls with `via: :console` (escalations_live.ex) — an iex caller (the
  # default `via: :iex`) drives the identical path, so this only needs to
  # prove the facade functions themselves work end to end, not re-derive the
  # console test coverage.

  alias SpeckitOrchestrator.NeedsHuman.Question

  defp open_awaiting_run(feature_id, round_info) do
    repo_id = RepoIdentity.partition(Config.repo())

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{
            feature_id: feature_id,
            slug: "slug-#{feature_id}",
            path: "#{feature_id}.md",
            number: String.to_integer(feature_id),
            group: :backlog,
            created_at: nil
          }
        ],
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    run_key = {repo_id, run_id}
    {:ok, seq} = Writer.record_feature_awaiting(run_key, feature_id, round_info)
    {run_key, seq}
  end

  test "pending_questions/0 lists the feature, round and each question" do
    questions = [
      %Question{id: "Q1", text: "Prorate mid-month?", context: nil, options: [], recommended: "yes"},
      %Question{id: "Q2", text: "Which timezone?", context: nil, options: [], recommended: "UTC"}
    ]

    {_run_key, seq} =
      open_awaiting_run("601", %{
        round: 1,
        max_rounds: 3,
        questions_raw: "## NEEDS HUMAN\n\n### Q1: Prorate mid-month?\n",
        questions: {:numbered, questions},
        answer_timeout_s: 1_800
      })

    [pending] = SpeckitOrchestrator.pending_questions()

    assert pending.feature_id == "601"
    assert pending.round == 1
    assert pending.max_rounds == 3
    assert pending.seq == seq
    assert {:numbered, [q1, q2]} = pending.questions
    assert q1.id == "Q1"
    assert q2.id == "Q2"
    assert %DateTime{} = pending.started_at
    assert %DateTime{} = pending.deadline_at
  end

  test "pending_questions/0 returns [] when nothing is awaiting" do
    assert SpeckitOrchestrator.pending_questions() == []
  end

  test "answer/3 submitted from iex (default via) proceeds exactly as a console submission" do
    questions = [
      %Question{id: "Q1", text: "Prorate mid-month?", context: nil, options: [], recommended: nil}
    ]

    {run_key, seq} =
      open_awaiting_run("602", %{
        round: 1,
        max_rounds: 3,
        questions_raw: "## NEEDS HUMAN\n\n### Q1: Prorate mid-month?\n",
        questions: {:numbered, questions},
        answer_timeout_s: 1_800
      })

    assert :ok = SpeckitOrchestrator.answer("602", seq, %{"Q1" => "by day"})

    {repo_id, run_id} = run_key
    round_key = SpeckitOrchestrator.Store.Ids.ordinal_id(repo_id, run_id, "602", seq)
    {:ok, round} = SpeckitOrchestrator.Store.Query.clarify_round(round_key)

    assert round.outcome == :answered
    assert round.answered_via == :iex
    assert round.answers == %{"Q1" => {:typed, "by day"}}
    assert SpeckitOrchestrator.pending_questions() == []
  end
end
