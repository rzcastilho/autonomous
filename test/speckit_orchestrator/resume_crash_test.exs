defmodule SpeckitOrchestrator.ResumeCrashTest do
  # async: false — real-worktree test points :repo/:worktree_root at throwaway
  # dirs and swaps the :jido_claude sdk_module (mirrors resume_test.exs).
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Checkpoint, Config, Feature, Worktree}

  # Fake SDK — analyze reports a critical finding so the resumed run halts
  # quickly at a stable, inspectable terminal.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, options) do
      SpeckitOrchestrator.FakeArtifacts.write(prompt, options)

      text =
        if String.contains?(prompt, "/speckit.analyze") do
          ~s({"summary":"crash resume","findings":[{"severity":"critical","title":"bad"}]})
        else
          "Phase completed."
        end

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

  defp unique_id, do: "rc#{System.unique_integer([:positive, :monotonic])}"
  defp feature(id), do: %Feature{id: id, slug: "resume-crash", path: "#{id}-resume-crash.md"}

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp base_repo do
    repo = Path.join(System.tmp_dir!(), "rc_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "rc_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp point_config_at(repo, root) do
    prev =
      for k <- [:repo, :worktree_root], do: {k, Application.get_env(:speckit_orchestrator, k)}

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

  @tag :integration
  test "resume restores the worktree before re-running the interrupted phase, discarding a crash's uncommitted partial output" do
    id = unique_id()
    repo = base_repo()
    root = tmp_root()
    point_config_at(repo, root)

    {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)

    # Simulate specify..plan having completed cleanly, each with a phase-boundary
    # commit — mirrors what FeatureRunner.loop/7's per-phase write leaves behind.
    spec_dir = Path.join(wt.path, "specs/#{id}-resume-crash")
    File.mkdir_p!(spec_dir)
    File.write!(Path.join(spec_dir, "spec.md"), "# Spec\ncontent\n")
    git!(wt.path, ["add", "-A"])
    git!(wt.path, ["commit", "-q", "-m", "speckit: #{id} checkpoint after specify"])

    File.write!(Path.join(spec_dir, "plan.md"), "# Plan\ncontent\n")
    git!(wt.path, ["add", "-A"])
    git!(wt.path, ["commit", "-q", "-m", "speckit: #{id} checkpoint after plan"])

    # Checkpoint pointing at the last completed phase, status in_progress —
    # exactly what the per-phase write leaves behind after :plan.
    :ok =
      Checkpoint.write(%{
        feature_id: id,
        last_phase: :plan,
        status: :in_progress,
        reason: nil,
        session_id: "s1",
        slug: "resume-crash",
        path: "#{id}-resume-crash.md"
      })

    on_exit(fn -> File.rm_rf(Path.join(Config.transcript_root(), id)) end)

    # The crash left an uncommitted partial file from the interrupted :tasks phase.
    File.write!(Path.join(spec_dir, "tasks.md"), "# Tasks\npartial and incomplete")

    me = self()

    assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:run_complete, report}, 30_000
    assert report.halted == [id]

    # specify/plan artifacts are byte-unchanged (not regenerated).
    assert File.read!(Path.join(spec_dir, "spec.md")) == "# Spec\ncontent\n"
    assert File.read!(Path.join(spec_dir, "plan.md")) == "# Plan\ncontent\n"

    # the crash's uncommitted partial output is gone.
    refute File.exists?(Path.join(spec_dir, "tasks.md"))

    # resumed at tasks (the phase after the last completed plan), not at plan
    # itself and not from Pipeline.first().
    refute File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
    refute File.exists?(Path.join(wt.path, ".speckit_logs/03-plan.md"))
    assert File.exists?(Path.join(wt.path, ".speckit_logs/04-tasks.md"))
    assert File.exists?(Path.join(wt.path, ".speckit_logs/05-analyze.md"))
  end
end
