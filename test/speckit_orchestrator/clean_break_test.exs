defmodule SpeckitOrchestrator.CleanBreakTest do
  @moduledoc """
  FR-037 clean break (018, quickstart.md §10): `RunManifest`, `Checkpoint`,
  `Transcripts`, and `Describe`'s PR-file pair no longer exist, and a real run
  creates no file under any of the five pre-018 paths — everything durable now
  lives in the store alone.
  """

  # async: false — swaps the global :jido_claude sdk_module + :speckit_orchestrator
  # app env (repo/worktree_root/autonomous_root), mirrors run_spec_test.exs.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Describe, RepoIdentity, SingleSpec}

  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, opts) do
      SpeckitOrchestrator.FakeArtifacts.write(prompt, opts)
      text = response_text(prompt)

      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :assistant,
          data: %{session_id: "s", message: %{"content" => text}},
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
    end

    # Escalates at clarify — the worktree is kept (not removed), so the
    # `.speckit_logs/` absence check below inspects a real, surviving tree
    # rather than a directory that's trivially gone along with the worktree.
    defp response_text(prompt) do
      if String.contains?(prompt, "clarify reviewer") do
        "Reviewed.\n\n## NEEDS HUMAN\nSomething is ambiguous."
      else
        "Phase completed."
      end
    end
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp base_repo do
    repo = Path.join(System.tmp_dir!(), "cb_repo_#{System.unique_integer([:positive])}")
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
    File.mkdir_p!(Path.join(repo, ".claude/hooks"))
    File.write!(Path.join(repo, ".claude/hooks/scope_guard.py"), "")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "cb_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp point_config_at(repo, root) do
    prev =
      for k <- [:repo, :worktree_root, :autonomous_root],
          do: {k, Application.get_env(:speckit_orchestrator, k)}

    Application.put_env(:speckit_orchestrator, :repo, repo)
    Application.put_env(:speckit_orchestrator, :worktree_root, root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:speckit_orchestrator, k, v),
          else: Application.delete_env(:speckit_orchestrator, k)
      end
    end)
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)
    end)

    :ok
  end

  # ---- the modules themselves are gone (FR-037) ------------------------------

  test "RunManifest no longer exists" do
    refute Code.ensure_loaded?(SpeckitOrchestrator.RunManifest)
  end

  test "Checkpoint no longer exists" do
    refute Code.ensure_loaded?(SpeckitOrchestrator.Checkpoint)
  end

  test "Transcripts no longer exists" do
    refute Code.ensure_loaded?(SpeckitOrchestrator.Transcripts)
  end

  test "Describe.write_pr/3 no longer exists" do
    refute function_exported?(Describe, :write_pr, 3)
  end

  test "Describe.read_pr/2 no longer exists" do
    refute function_exported?(Describe, :read_pr, 2)
  end

  # ---- a real run creates none of the five pre-018 paths (quickstart.md §10) -

  test "a run that diverts creates no file under any pre-018 state path" do
    repo = base_repo()
    root = tmp_root()
    point_config_at(repo, root)

    {:ok, pid} = SpeckitOrchestrator.run_spec("Add a health check endpoint", owner: self())
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 30_000
    assert report.escalated == ["001"]

    slug = SingleSpec.slug("Add a health check endpoint")
    {:ok, segment} = RepoIdentity.resolve(repo)
    worktree_path = Path.join([root, "worktrees", segment, "001-#{slug}"])

    # the diverted worktree survives (kept for post-mortem) — a real tree to
    # assert `.speckit_logs/` is absent from, not one removed along with it.
    assert File.dir?(worktree_path)
    refute File.dir?(Path.join(worktree_path, ".speckit_logs"))

    # <autonomous_root>/transcripts/<segment>/run.json and
    # <transcript_root>/<feature_id>/{checkpoint.json,NN-<phase>.md,pr.json}
    # all lived somewhere under <autonomous_root>/transcripts/<segment> —
    # nothing writes there anymore, so the whole subtree is either absent or
    # empty.
    transcripts_dir = Path.join([root, "transcripts", segment])

    assert transcripts_dir
           |> Path.join("**")
           |> Path.wildcard()
           |> Enum.reject(&File.dir?/1) == [],
           "expected no files under #{transcripts_dir}"
  end
end
