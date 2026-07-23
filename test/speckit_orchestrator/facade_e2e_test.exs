defmodule SpeckitOrchestrator.FacadeE2ETest do
  # async: false — swaps global SDK + app env; runs the real stack end-to-end.
  use ExUnit.Case, async: false

  # Offline end-to-end: facade run/0 -> load_backlog -> Coordinator ->
  # default_runner -> Worktree -> FeatureRunner -> FeatureAgent -> phases via a
  # fake SDK. No CLI, no spend.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, opts) do
      # Simulate the CLI's file side effects — the artifact gate reads the tree.
      SpeckitOrchestrator.FakeArtifacts.write(prompt, opts)

      text =
        cond do
          String.contains?(prompt, "clarify reviewer") -> "Clarified."
          String.contains?(prompt, "/speckit.analyze") -> ~s({"summary":"ok","findings":[]})
          true -> "done"
        end

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
  end

  alias SpeckitOrchestrator.RepoIdentity

  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp add_origin!(repo), do: git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)

    prev =
      for k <- [:repo, :breakdown_dir, :worktree_root, :autonomous_root],
        do: {k, Application.get_env(:speckit_orchestrator, k)}

    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.put_env(:speckit_orchestrator, :test_fake_scenario, :happy)

    repo = Path.join(System.tmp_dir!(), "e2e_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "e2e_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, "specs/autonomous/breakdown/core"))

    File.write!(
      Path.join(repo, "specs/autonomous/breakdown/core/001-core.md"),
      "# 001\n\n## Prerequisites\n\nNone\n"
    )

    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    add_origin!(repo)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])

    Application.put_env(:speckit_orchestrator, :repo, repo)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "docs/breakdown")
    Application.put_env(:speckit_orchestrator, :worktree_root, root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      for {k, v} <- prev do
        if v, do: Application.put_env(:speckit_orchestrator, k, v),
          else: Application.delete_env(:speckit_orchestrator, k)
      end

      Application.delete_env(:speckit_orchestrator, :test_fake_scenario)
      File.rm_rf(repo)
      File.rm_rf(root)
    end)

    %{repo: repo, root: root}
  end

  test "run/0 drives a real one-feature backlog to :done end-to-end (offline)", %{repo: repo, root: root} do
    # no-arg run/0: owner defaults to the caller.
    {:ok, pid} = SpeckitOrchestrator.run()
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 30_000
    assert report.done == ["001"]

    {:ok, segment} = RepoIdentity.resolve(repo)
    # worktree removed on :done
    refute File.dir?(Path.join([root, "worktrees", segment, "001-core"]))
  end

  test "a feature whose worktree can't be created (missing scaffold) is failed" do
    # Point the run at a repo with a backlog but NO committed .specify/.claude
    # scaffold, so Worktree.create aborts and the default runner fails it.
    bare = Path.join(System.tmp_dir!(), "e2e_bare_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(bare, "specs/autonomous/breakdown/core"))

    File.write!(
      Path.join(bare, "specs/autonomous/breakdown/core/001-core.md"),
      "# 001\n\n## Prerequisites\n\nNone\n"
    )

    git!(bare, ["init", "-q", "-b", "main"])
    git!(bare, ["config", "user.email", "t@e.com"])
    git!(bare, ["config", "user.name", "T"])
    add_origin!(bare)
    git!(bare, ["add", "-A"])
    git!(bare, ["commit", "-q", "-m", "base"])
    Application.put_env(:speckit_orchestrator, :repo, bare)
    on_exit(fn -> File.rm_rf(bare) end)

    {:ok, pid} = SpeckitOrchestrator.run(owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 30_000
    assert report.failed == ["001"]
  end
end
