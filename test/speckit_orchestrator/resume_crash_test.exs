defmodule SpeckitOrchestrator.ResumeCrashTest do
  # async: false — real-worktree test points :repo/:worktree_root at throwaway
  # dirs and swaps the :jido_claude sdk_module (mirrors resume_test.exs), plus
  # the shared store (StoreCase clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Feature, Layout, RepoIdentity, RunContext, Worktree}

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

  # ---- 025 US1: mid-implement crash re-enters ChunkRunner at position -------

  # Checks off the scoped task-phase's own task and writes a real source file
  # (mirrors `chunk_runner_test.exs`'s FakeSDK) so the artifact gate sees
  # genuine implementation changes. Dispatching an already-complete task-phase
  # (1 or 2, pre-marked done below) is a hard bug — reported as a terminal,
  # non-transient session error rather than silently succeeding, which is
  # what would happen if the chunk loop restarted from task-phase 1 instead
  # of resuming at the checkpointed position.
  defmodule ChunkCrashFakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _options) when is_binary(prompt) do
      case Regex.run(~r/Implement ONLY the tasks in "Phase (\d+):/, prompt) do
        [_, n] when n in ["1", "2"] ->
          error_messages("illegal redispatch of already-complete task-phase #{n}")

        [_, n] ->
          check_off_and_succeed(n)

        nil ->
          success_messages()
      end
    end

    defp check_off_and_succeed(n) do
      case Application.get_env(:speckit_orchestrator, :chunk_crash_cwd) do
        nil -> :ok
        cwd -> check_off(cwd, n)
      end

      success_messages()
    end

    defp check_off(cwd, n) do
      path =
        Path.join(
          cwd,
          "specs/#{Application.get_env(:speckit_orchestrator, :chunk_crash_spec_dir)}/tasks.md"
        )

      content =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.map(fn line ->
          if String.contains?(line, "T00#{n} "),
            do: String.replace(line, "[ ]", "[X]"),
            else: line
        end)
        |> Enum.join("\n")

      File.write!(path, content)

      impl_path = Path.join(cwd, "lib/fake_phase_#{n}.ex")
      File.mkdir_p!(Path.dirname(impl_path))
      File.write!(impl_path, "defmodule FakePhase#{n} do\nend\n")
    end

    defp success_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s",
            result: "done",
            num_turns: 3,
            is_error: false,
            total_cost_usd: 0.1,
            usage: %{input_tokens: 0, output_tokens: 0}
          },
          raw: %{}
        }
      ]
    end

    defp error_messages(reason) do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error,
          data: %{session_id: "s", error: reason, is_error: true, total_cost_usd: 0.05},
          raw: %{}
        }
      ]
    end
  end

  describe "resume/2 — mid-implement crash re-enters ChunkRunner at the checkpointed position" do
    setup do
      prev_sdk = Application.get_env(:jido_claude, :sdk_module)
      Application.put_env(:jido_claude, :sdk_module, ChunkCrashFakeSDK)

      on_exit(fn ->
        if prev_sdk,
          do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
          else: Application.delete_env(:jido_claude, :sdk_module)

        Application.delete_env(:speckit_orchestrator, :chunk_crash_cwd)
        Application.delete_env(:speckit_orchestrator, :chunk_crash_spec_dir)
      end)

      :ok
    end

    # contracts/reconcile-checkpoint-first.md §4 worked case 1 (the defect),
    # exercised through the actual chunk loop: a checkpoint naming
    # `:implement` (task-phase 3) beside a trail whose newest boundary commit
    # is `:tasks` — two phases behind. `resume/2` always dispatched at the
    # checkpoint's own phase (untouched by 025), so this proves the OTHER
    # half of FR-007/SC-006: the resumed `ChunkRunner` loop itself re-enters
    # at the recorded task-phase, `{:skip, _}`ing 1-2 (already complete)
    # rather than redispatching them.
    test "resumes at the recorded task-phase, redispatching neither of the two already-complete ones" do
      # A numeric id, like every real feature id — `Feature.spec_id/1` derives
      # the worktree path/branch from `spec_number`, which must be pre-set
      # (mirrors production's `run_fresh/6` invariant, feature 022) so the
      # worktree this fixture creates and the one `resume/2` locates agree.
      n = System.unique_integer([:positive, :monotonic])
      id = "#{n}"
      feature = %{feature(id) | number: n, spec_number: n}

      repo = base_repo()
      root = tmp_root()
      point_config_at(repo, root)

      spec_dir = "#{Feature.spec_id(feature)}-resume-crash"
      spec_path = Path.join(repo, "specs/#{spec_dir}")
      File.mkdir_p!(spec_path)

      body =
        Enum.map_join([{"1", "Setup"}, {"2", "Core"}, {"3", "Widgets"}], "\n", fn {n, title} ->
          mark = if n in ["1", "2"], do: "X", else: " "
          "## Phase #{n}: #{title}\n\n- [#{mark}] T00#{n} #{title} task\n"
        end)

      File.write!(Path.join(spec_path, "tasks.md"), "# Tasks\n\n" <> body)
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "seed tasks"])

      {:ok, wt} = Worktree.create(feature, repo: repo, worktree_root: root)

      # The trail: a single boundary commit proving only :tasks completed —
      # two phases behind the checkpoint's :analyze completed-through.
      git!(wt.path, [
        "commit",
        "--allow-empty",
        "-q",
        "-m",
        "speckit: #{id} checkpoint after tasks"
      ])

      Application.put_env(:speckit_orchestrator, :chunk_crash_cwd, wt.path)
      Application.put_env(:speckit_orchestrator, :chunk_crash_spec_dir, spec_dir)

      {:ok, segment} = RepoIdentity.resolve(repo)
      {:ok, layout} = Layout.build(repo, segment, :ad_hoc)
      layout = %{layout | worktree_root: root}

      {:ok, run_id} =
        Writer.open_run(RepoIdentity.partition(repo), %{
          features: [
            %{
              feature_id: id,
              slug: feature.slug,
              path: feature.path,
              number: feature.number,
              group: :backlog,
              created_at: nil
            }
          ],
          settings: RunContext.to_map(%RunContext{budget_usd: 100.0}),
          scope: :ad_hoc,
          layout: layout
        })

      run_key = {RepoIdentity.partition(repo), run_id}
      :ok = Writer.record_spec_number(run_key, id, n)

      :ok =
        Writer.record_checkpoint(run_key, id, %{
          phase: :implement,
          last_completed_phase: :analyze,
          status: :in_progress,
          reason: nil,
          session_id: "s1",
          implement_chunk: %{
            ordinal: 3,
            number: "3",
            title: "Widgets",
            total: 3,
            sessions_used: 0,
            ceiling: 14,
            scope: :task_phase
          }
        })

      me = self()
      fake_publisher = fn f, _base -> {:ok, "https://example/pr/#{f.id}"} end

      assert {:ok, pid} =
               SpeckitOrchestrator.resume(id,
                 features: [feature],
                 owner: me,
                 publisher: fake_publisher
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:run_complete, report}, 30_000
      assert report.done == [id]

      {:ok, detail} = Store.run(run_key)
      phases_seen = detail.features |> hd() |> Map.fetch!(:phase_attempts) |> Enum.map(& &1.phase)
      refute :analyze in phases_seen
      assert :implement_chunk in phases_seen
    end
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
