defmodule SpeckitOrchestrator.ResumeTest do
  # async: false — real-worktree tests point :repo/:worktree_root at throwaway
  # dirs and swap the :jido_claude sdk_module (mirrors run_spec_test.exs /
  # feature_runner_test.exs); every test uses a unique feature id so runs never
  # collide on the shared (fixed, per-suite) :transcript_root checkpoint path.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Checkpoint, Config, Feature, Worktree}

  # Fake SDK — only the branches these tests exercise (analyze -> critical
  # finding). Mirrors feature_runner_test.exs's FakeSDK, trimmed to this
  # feature's scope.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _options) do
      text =
        if String.contains?(prompt, "/speckit.analyze") do
          # Mirror whether the built prompt carries the appended resume-guidance
          # line (PhaseRequest.append_resume_prompt/2) into the JSON `summary`
          # so tests can assert on it via the durable transcript, without a
          # separate capture channel. analyze is the only phase these tests use
          # for a real FakeSDK run — it has no artifact-gate requirement, unlike
          # :plan/:tasks/:implement.
          note =
            if String.contains?(prompt, "Operator guidance (resume):"),
              do: "guidance-present",
              else: "guidance-absent"

          ~s({"summary":"#{note}","findings":[{"severity":"critical","title":"bad"}]})
        else
          "Phase completed."
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

  defp unique_id, do: "r#{System.unique_integer([:positive, :monotonic])}"

  defp feature(id), do: %Feature{id: id, slug: "resume-facade", path: "#{id}-resume-facade.md"}

  # `identity` is an optional keyword list (`slug:`, `path:`) merged into the
  # write map — omitted, this produces an old-shape checkpoint carrying no
  # identity (FR-001..004 fixtures reuse this for both shapes).
  defp write_checkpoint(id, last_phase, status \\ :halted, identity \\ []) do
    base = %{
      feature_id: id,
      last_phase: last_phase,
      status: status,
      reason: "test fixture",
      session_id: "s1"
    }

    :ok = Checkpoint.write(Enum.into(identity, base))

    on_exit(fn -> File.rm_rf(Path.join(Config.transcript_root(), id)) end)
  end

  defp capturing_runner(test_pid) do
    fn feat, notify ->
      send(test_pid, {:runner_called, feat})
      notify.(feat.id, :done, nil)
      :ok
    end
  end

  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp base_repo do
    repo = Path.join(System.tmp_dir!(), "resume_repo_#{System.unique_integer([:positive])}")
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
    root = Path.join(System.tmp_dir!(), "resume_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  # Points the resume wrapper's opt-less Worktree.locate/create calls (mirrors
  # default_runner/2) at a throwaway repo/worktree_root — run/1-family
  # functions never take :repo/:worktree_root as per-call opts.
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

  # ---- distinct failures, no run started (hermetic) ------------------------

  describe "resume/2 — distinct failures, no run started" do
    test "no checkpoint" do
      id = unique_id()
      me = self()

      assert {:error, :no_checkpoint} =
               SpeckitOrchestrator.resume(id, features: [feature(id)], runner: capturing_runner(me))

      refute_received {:runner_called, _}
    end

    test "no checkpoint on disk still returns {:error, :no_checkpoint}, unchanged" do
      me = self()

      assert {:error, :no_checkpoint} =
               SpeckitOrchestrator.resume("does-not-exist", features: [], runner: capturing_runner(me))

      refute_received {:runner_called, _}
    end

    test "corrupt checkpoint" do
      id = unique_id()
      dir = Path.join(Config.transcript_root(), id)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "checkpoint.json"), "not valid json{")
      on_exit(fn -> File.rm_rf(dir) end)
      me = self()

      assert {:error, :corrupt_checkpoint} =
               SpeckitOrchestrator.resume(id, features: [feature(id)], runner: capturing_runner(me))

      refute_received {:runner_called, _}
    end
  end

  # ---- identity recovery from checkpoint alone (US1, FR-001..004) ---------

  describe "resume/2 — identity recovery from checkpoint alone" do
    test "reconstructs the feature from checkpoint identity when :features is empty and no explicit feature is supplied" do
      id = unique_id()
      write_checkpoint(id, :analyze, :halted, slug: "widget", path: "#{id}-widget.md")
      me = self()

      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:runner_called, feat}
      assert feat.id == id
      assert feat.slug == "widget"
      assert feat.path == "#{id}-widget.md"
    end

    test "explicit/backlog feature wins over checkpoint identity when both exist for the same id" do
      id = unique_id()
      write_checkpoint(id, :analyze, :halted, slug: "wrong-slug", path: "wrong.md")
      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id, features: [feature(id)], runner: capturing_runner(me))

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:runner_called, feat}
      assert feat.slug == "resume-facade"
      assert feat.path != "wrong.md"
    end

    test "neither explicit/backlog feature nor checkpoint identity resolves — {:error, {:unknown_feature, id}}, no run started" do
      id = unique_id()
      # old-shape checkpoint: no slug/path carried
      write_checkpoint(id, :analyze)
      me = self()

      assert {:error, {:unknown_feature, ^id}} =
               SpeckitOrchestrator.resume(id, features: [], runner: capturing_runner(me))

      refute_received {:runner_called, _}
    end

    test "tolerates a missing/unloadable backlog when checkpoint identity is present" do
      id = unique_id()
      write_checkpoint(id, :analyze, :halted, slug: "widget", path: "#{id}-widget.md")

      prev_repo = Application.get_env(:speckit_orchestrator, :repo)
      Application.put_env(:speckit_orchestrator, :repo, "/nonexistent/repo-#{id}")

      on_exit(fn ->
        if prev_repo,
          do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
          else: Application.delete_env(:speckit_orchestrator, :repo)
      end)

      me = self()

      # No :features opt at all — forces the best-effort load_backlog/0 path,
      # which raises against a nonexistent repo; must not crash resume/2.
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, runner: capturing_runner(me))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:runner_called, feat}
      assert feat.slug == "widget"
    end
  end

  # ---- real restart: worktree reuse + fake SDK ------------------------------

  describe "resume/2 — restarts at the checkpointed phase" do
    test "restarts at the checkpointed phase, not Pipeline.first()" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      write_checkpoint(id, :analyze)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      refute File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
      refute File.exists?(Path.join(wt.path, ".speckit_logs/02-clarify.md"))
      refute File.exists?(Path.join(wt.path, ".speckit_logs/03-plan.md"))
      refute File.exists?(Path.join(wt.path, ".speckit_logs/04-tasks.md"))
      assert File.exists?(Path.join(wt.path, ".speckit_logs/05-analyze.md"))
    end
  end

  # ---- operator guidance passthrough (US2) ---------------------------------

  describe "resume/2 — operator guidance passthrough" do
    test "delivers the :prompt guidance note to the resumed phase unchanged" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      write_checkpoint(id, :analyze)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 owner: me,
                 prompt: "fixed float"
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      analyze_log = File.read!(Path.join(wt.path, ".speckit_logs/05-analyze.md"))
      assert analyze_log =~ "guidance-present"
    end

    test "delivers :prompt with identity recovered from checkpoint alone (no explicit feature)" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      write_checkpoint(id, :analyze, :halted, slug: "resume-facade", path: "#{id}-resume-facade.md")

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id, features: [], owner: me, prompt: "fixed float")

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      analyze_log = File.read!(Path.join(wt.path, ".speckit_logs/05-analyze.md"))
      assert analyze_log =~ "guidance-present"
    end

    test "with no :prompt runs the resumed phase with resume_prompt: nil — no error, no placeholder" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      write_checkpoint(id, :analyze)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      analyze_log = File.read!(Path.join(wt.path, ".speckit_logs/05-analyze.md"))
      assert analyze_log =~ "guidance-absent"
    end
  end

  # ---- :from phase override (US3) ------------------------------------------

  describe "resume/2 — :from phase override" do
    test "valid :from overrides the checkpointed phase" do
      # Checkpoint points at :converge (no artifact-gate requirement, like
      # :analyze — FakeSDK writes no real files); :from overrides it back to
      # :analyze. If the override were ignored, the run would start at
      # :converge and complete with FakeSDK's generic "Phase completed." text
      # (no not_ready? signal) straight to :done. Landing on :halted instead
      # proves the run actually started at :analyze, not the checkpoint.
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      write_checkpoint(id, :converge)

      me = self()

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me, from: :analyze)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      refute File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
      refute File.exists?(Path.join(wt.path, ".speckit_logs/04-tasks.md"))
      assert File.exists?(Path.join(wt.path, ".speckit_logs/05-analyze.md"))
      refute File.exists?(Path.join(wt.path, ".speckit_logs/07-converge.md"))
    end

    test "invalid :from is rejected with {:error, {:unknown_phase, phase}} and starts no run" do
      id = unique_id()
      write_checkpoint(id, :analyze)
      me = self()

      assert {:error, {:unknown_phase, :nope}} =
               SpeckitOrchestrator.resume(id,
                 features: [feature(id)],
                 runner: capturing_runner(me),
                 from: :nope
               )

      refute_received {:runner_called, _}
    end
  end

  # ---- integration: real branch-gone / branch-reuse edge cases -------------

  describe "resume/2 — worktree recreation (integration)" do
    @tag :integration
    test "recreates the worktree from the existing branch when previously freed" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: root)
      File.write!(Path.join(wt.path, "fixed.txt"), "operator fix")
      git!(wt.path, ["add", "-A"])
      git!(wt.path, ["commit", "-q", "-m", "operator fix"])

      # simulate resolve/1 freeing the worktree; the branch survives
      assert :ok = Worktree.remove(wt)
      refute File.dir?(wt.path)

      write_checkpoint(id, :analyze)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.halted == [id]

      assert File.read!(Path.join(wt.path, "fixed.txt")) == "operator fix"
      refute File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
      assert File.exists?(Path.join(wt.path, ".speckit_logs/05-analyze.md"))
    end

    @tag :integration
    test "propagates {:worktree, reason} via a :failed notification when the branch is gone" do
      id = unique_id()
      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      write_checkpoint(id, :analyze)

      me = self()
      assert {:ok, pid} = SpeckitOrchestrator.resume(id, features: [feature(id)], owner: me)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 5_000
      assert report.failed == [id]

      {out, 0} = System.cmd("git", ["-C", repo, "branch", "--list", "feature/#{id}-resume-facade"])
      assert out == ""
    end
  end
end
