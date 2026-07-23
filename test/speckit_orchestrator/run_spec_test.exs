defmodule SpeckitOrchestrator.RunSpecTest do
  # async: false — swaps the global :jido_claude sdk_module, :speckit_orchestrator
  # app env (repo/worktree_root), and the fixed-name Coordinator.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Coordinator, Ledger, RepoIdentity, SingleSpec}

  # Fake SDK, scenario-selected via app env (mirrors feature_runner_test.exs /
  # facade_e2e_test.exs) — no CLI, no spend, drives every phase deterministically.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, opts) do
      # Simulate the CLI's file side effects — the artifact gate reads the tree.
      SpeckitOrchestrator.FakeArtifacts.write(prompt, opts)
      text = response_text(prompt)

      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{type: :assistant, data: %{session_id: "s", message: %{"content" => text}}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
    end

    defp response_text(prompt) do
      scenario = Application.get_env(:speckit_orchestrator, :test_fake_scenario, :happy)

      cond do
        String.contains?(prompt, "clarify reviewer") ->
          case scenario do
            :escalate -> "Reviewed.\n\n## NEEDS HUMAN\nSomething is ambiguous."
            _ -> "Clarified: no ambiguity remains."
          end

        String.contains?(prompt, "/speckit.analyze") ->
          case scenario do
            :halt -> ~s({"summary":"violation","findings":[{"severity":"critical","title":"bad"}]})
            _ -> ~s({"summary":"clean","findings":[]})
          end

        true ->
          "Phase completed."
      end
    end
  end

  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # Base repo with the committed scaffold single-spec worktrees need — same
  # shape as facade_e2e_test.exs / worktree_test.exs's helpers.
  defp base_repo do
    repo = Path.join(System.tmp_dir!(), "rs_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "rs_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  # Point the real single-feature run at a throwaway repo/autonomous_root,
  # exactly as a caller would via config — run/1 and run_spec/2 never take
  # these as per-call opts (matching the codebase-wide convention: only the
  # pure taken-id scan honors opts[:repo]/[:ad_hoc_dir]). :worktree_root is
  # the pre-012 legacy default (unused once a real %Layout{} resolves), kept
  # isolated too so nothing falls back to it by accident.
  defp point_config_at(repo, root) do
    prev =
      for k <- [:repo, :worktree_root, :autonomous_root],
        do: {k, Application.get_env(:speckit_orchestrator, k)}

    Application.put_env(:speckit_orchestrator, :repo, repo)
    Application.put_env(:speckit_orchestrator, :worktree_root, root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:speckit_orchestrator, k, v), else: Application.delete_env(:speckit_orchestrator, k)
      end
    end)
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :happy)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:speckit_orchestrator, :test_fake_scenario)
    end)

    :ok
  end

  # ---- validation + wiring (US1) -------------------------------------------

  describe "run_spec/2 validation and wiring" do
    test "rejects a nil description with no side effect" do
      assert SpeckitOrchestrator.run_spec(nil) == {:error, :empty_description}
    end

    test "rejects an empty description" do
      assert SpeckitOrchestrator.run_spec("") == {:error, :empty_description}
    end

    test "rejects a whitespace-only description" do
      assert SpeckitOrchestrator.run_spec("   \n\t ") == {:error, :empty_description}
    end

    test "a valid description runs as a wave of one via an injected :runner" do
      me = self()
      runner = fn feature, notify -> send(me, {:started, feature.id, feature.slug}); notify.(feature.id, :done, nil) end

      {:ok, pid} =
        SpeckitOrchestrator.run_spec("Add a health check endpoint",
          repo: "/no/such/repo/#{System.unique_integer([:positive])}",
          runner: runner,
          owner: me
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:started, "001", "add-a-health-check-endpoint"}, 2_000
      assert_receive {:run_complete, report}, 2_000
      assert report.done == ["001"]
    end

    test "auto-assigned id skips past existing ad-hoc ids and feature branches" do
      repo = base_repo()
      File.mkdir_p!(Path.join(repo, "specs/autonomous/ad-hoc"))
      File.write!(
        Path.join(repo, "specs/autonomous/ad-hoc/001-existing.md"),
        "# 001\n\n## Prerequisites\n\nNone\n"
      )
      git!(repo, ["branch", "feature/002-also-existing"])

      me = self()
      runner = fn feature, notify -> send(me, {:id, feature.id}); notify.(feature.id, :done, nil) end

      {:ok, pid} = SpeckitOrchestrator.run_spec("A third feature", repo: repo, runner: runner, owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:id, "003"}, 2_000
      assert_receive {:run_complete, _report}, 2_000
    end
  end

  # ---- seed-writing runner, real worktree + fake CLI (US1, US2 containment/transcripts) ----

  describe "seed-writing runner (real worktree)" do
    test "happy path: seeds, commits onto the branch, removes the worktree, writes durable transcripts" do
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, pid} = SpeckitOrchestrator.run_spec("Add a health check endpoint", owner: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.done == ["001"]

      slug = SingleSpec.slug("Add a health check endpoint")
      {:ok, segment} = RepoIdentity.resolve(repo)
      worktree_path = Path.join([root, "worktrees", segment, "001-#{slug}"])
      seed_rel = "specs/autonomous/ad-hoc/001-#{slug}.md"

      # worktree removed on :done
      refute File.dir?(worktree_path)

      # containment: the seed never lands in the base repo's checked-out tree...
      refute File.regular?(Path.join(repo, seed_rel))

      # ...only on the feature branch, committed with the description in it
      {show, 0} = git!(repo, ["show", "feature/001-#{slug}:#{seed_rel}"])
      assert show =~ "Add a health check endpoint"
      assert show =~ "## Prerequisites"
      assert show =~ "None"

      # durable transcripts survive teardown, keyed by feature id, under the
      # run's Layout-resolved (segment/ad-hoc-scoped) transcript root.
      transcript_dir = Path.join([root, "transcripts", segment, "ad-hoc", "001"])
      assert File.dir?(transcript_dir)
      assert File.exists?(Path.join(transcript_dir, "01-specify.md"))
    end

    test "seed-write failure fails the feature and keeps the worktree (never runs the pipeline)" do
      repo = base_repo()
      # Shadow the seed's parent directory with a plain file so mkdir_p for
      # specs/autonomous/ad-hoc fails inside the worktree — a real, unmocked
      # failure.
      File.write!(Path.join(repo, "specs"), "not a directory")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "shadow specs"])
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, pid} = SpeckitOrchestrator.run_spec("Trigger seed failure", owner: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 10_000
      assert report.failed == ["001"]

      slug = SingleSpec.slug("Trigger seed failure")
      {:ok, segment} = RepoIdentity.resolve(repo)
      # the worktree exists but was never touched by FeatureRunner (kept, not removed)
      assert File.dir?(Path.join([root, "worktrees", segment, "001-#{slug}"]))
    end
  end

  # ---- guarantees preserved (US2) ------------------------------------------

  describe "guarantees preserved" do
    test "clarify escalation: the feature escalates and its worktree is kept" do
      Application.put_env(:speckit_orchestrator, :test_fake_scenario, :escalate)
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, pid} = SpeckitOrchestrator.run_spec("An ambiguous feature", owner: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.escalated == ["001"]

      slug = SingleSpec.slug("An ambiguous feature")
      {:ok, segment} = RepoIdentity.resolve(repo)
      assert File.dir?(Path.join([root, "worktrees", segment, "001-#{slug}"]))
    end

    test "analyze halt: the feature halts and its worktree is kept" do
      Application.put_env(:speckit_orchestrator, :test_fake_scenario, :halt)
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, pid} = SpeckitOrchestrator.run_spec("A non-compliant feature", owner: self())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == ["001"]

      slug = SingleSpec.slug("A non-compliant feature")
      {:ok, segment} = RepoIdentity.resolve(repo)
      assert File.dir?(Path.join([root, "worktrees", segment, "001-#{slug}"]))
    end

    test "breaker drain-not-kill: a single-spec feature releases no new work once tripped" do
      {:ok, ledger} = Ledger.start_link(budget: 1.0, name: nil)
      Ledger.record(ledger, nil, 1.0)
      assert Ledger.breaker_tripped?(ledger)

      {:ok, feature} = SingleSpec.build("Anything at all", [])
      me = self()
      runner = fn f, _notify -> send(me, {:started, f.id}) end

      {:ok, pid} =
        Coordinator.start_link(features: [feature], ledger: ledger, runner: runner, owner: me, name: nil)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 2_000
      refute_received {:started, _}
      assert report.not_started == [feature.id]
      assert report.spend == 1.0
      assert report.breaker_tripped
    end
  end

  # ---- optional PR workflow (US3) ------------------------------------------

  describe "optional PR workflow" do
    test "run_spec(pr_workflow: true) stacks the single feature and opens one PR" do
      me = self()

      executor = fn feature, base, notify ->
        send(me, {:built, feature.id, base})
        notify.(feature.id, :done, nil)
        :ok
      end

      publisher = fn feature, base ->
        send(me, {:pr, feature.id, base})
        {:ok, "https://example/pr/#{feature.id}"}
      end

      {:ok, pid} =
        SpeckitOrchestrator.run_spec("Ship this feature",
          pr_workflow: true,
          repo: "/no/such/repo/#{System.unique_integer([:positive])}",
          executor: executor,
          publisher: publisher,
          owner: me
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:built, "001", "main"}, 2_000
      assert_receive {:pr, "001", "main"}, 2_000
      assert_receive {:run_complete, report}, 2_000
      assert report.done == ["001"]
    end

    test "run_spec(pr_workflow: true) refuses to start when the target preflight fails" do
      bare = Path.join(System.tmp_dir!(), "rs_bare_#{System.unique_integer([:positive])}")
      File.mkdir_p!(bare)
      prev = Application.get_env(:speckit_orchestrator, :repo)
      Application.put_env(:speckit_orchestrator, :repo, bare)

      on_exit(fn ->
        File.rm_rf(bare)
        if prev, do: Application.put_env(:speckit_orchestrator, :repo, prev), else: Application.delete_env(:speckit_orchestrator, :repo)
      end)

      assert {:error, {:preflight, _problems}} =
               SpeckitOrchestrator.run_spec("Ship this feature", pr_workflow: true)
    end
  end
end
