defmodule SpeckitOrchestrator.ResumeCrashTest do
  # async: false — real-worktree test points :repo/:worktree_root at throwaway
  # dirs and swaps the :jido_claude sdk_module (mirrors resume_test.exs), plus
  # the shared store (StoreCase clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Feature, RepoIdentity, RunContext, Worktree}

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
  defp feature(id),
    do: %Feature{
      id: id,
      number: System.unique_integer([:positive, :monotonic]),
      slug: "resume-crash",
      path: "#{id}-resume-crash.md"
    }

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
    # The 012 facade preflight resolves repository identity from `origin`.
    git!(repo, ["remote", "add", "origin", "git@example.com:test/#{Path.basename(repo)}.git"])
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

  # ---- store fixtures (018) --------------------------------------------------

  defp minimal_attempt(feature_id, phase) do
    now = DateTime.utc_now()

    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: 1,
      step: 1,
      label: Atom.to_string(phase),
      started_at: now,
      ended_at: now,
      duration_ms: 0,
      outcome: :ok,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # A diverted (in_progress) checkpoint records the phase to resume at
  # directly (`FeatureRunner.checkpoint_for/3`'s `{:cont, next}` clause) —
  # the store equivalent of the pre-018 file checkpoint's `last_phase: :plan,
  # status: :in_progress`. `layout` is the SAME `%Layout{}` the manual
  # worktree below is created under, so `resume/2`'s store-derived
  # `run.layout` locates that exact worktree, not a different
  # `autonomous_root`-relative path.
  defp seed_checkpoint(repo, layout, id) do
    repo_id = RepoIdentity.partition(repo)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{
            feature_id: id,
            slug: "resume-crash",
            path: "#{id}-resume-crash.md",
            number: 1,
            group: :backlog,
            created_at: nil
          }
        ],
        settings:
          RunContext.to_map(%RunContext{
            budget_usd: 100.0
          }),
        scope: :ad_hoc,
        layout: layout
      })

    run_key = {repo_id, run_id}

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(id, :plan),
        checkpoint: %{
          phase: :tasks,
          last_completed_phase: :plan,
          status: :in_progress,
          reason: nil,
          session_id: "s1"
        }
      })

    run_key
  end

  # Overrides `:autonomous_root` (not `:worktree_root` directly) — the store
  # dispatch path always carries a real `%Layout{}` now (018), and
  # `Layout.build/3` derives `worktree_root` from `Config.autonomous_root/0`,
  # so both the test's manually-created worktree and `resume/2`'s own
  # `Worktree.locate/2` call must agree via the SAME layout instance.
  defp point_config_at(repo, root) do
    prev =
      for k <- [:repo, :autonomous_root], do: {k, Application.get_env(:speckit_orchestrator, k)}

    Application.put_env(:speckit_orchestrator, :repo, repo)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

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

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = SpeckitOrchestrator.Layout.build(repo, segment, :ad_hoc)

    {:ok, wt} = Worktree.create(feature(id), repo: repo, worktree_root: layout.worktree_root)

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
    run_key = seed_checkpoint(repo, layout, id)

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
    # itself and not from Pipeline.first() — checked via the store's recorded
    # phase attempts (018), since durable transcripts no longer live on disk.
    {:ok, detail} = Store.run(run_key)
    phases = detail.features |> hd() |> Map.fetch!(:phase_attempts) |> Enum.map(& &1.phase)
    refute :specify in phases
    assert :tasks in phases
    assert :analyze in phases
  end
end
