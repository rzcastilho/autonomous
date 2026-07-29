defmodule SpeckitOrchestrator.Recovery.EvidenceTest do
  # async: false — mutates the global :repo app env, plus the shared store
  # (StoreCase clears tables per test) for the final-marker transcript
  # signal.
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Feature, Recovery.Evidence, Recovery.Reconcile}

  @repo_id "o:evidence-test"

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp base_repo do
    dir = Path.join(System.tmp_dir!(), "ev_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "t@example.com"])
    git!(dir, ["config", "user.name", "Tester"])
    File.write!(Path.join(dir, "README.md"), "base\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp commit(repo, message) do
    File.write!(Path.join(repo, "f_#{System.unique_integer([:positive])}.txt"), message)
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", message])
  end

  defp feature(id \\ "001"),
    do: %Feature{id: id, number: String.to_integer(id), slug: "core-ledger", path: "#{id}.md"}

  defp fake_git(result), do: fn _feature -> result end

  defp converge_ready, do: "Tests green, committed.\n\n## CONVERGE: READY\n"

  setup do
    prev_repo = Application.get_env(:speckit_orchestrator, :repo)

    on_exit(fn ->
      if prev_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    :ok
  end

  # ---- store fixtures (018) --------------------------------------------------

  defp open_run(feature_id \\ "001") do
    {:ok, run_id} =
      Writer.open_run(@repo_id, %{
        features: [
          %{
            feature_id: feature_id,
            slug: "core-ledger",
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

    {@repo_id, run_id}
  end

  defp checkpoint_record(phase \\ :plan) do
    %{
      phase: phase,
      last_completed_phase: phase,
      status: :in_progress,
      reason: nil,
      session_id: nil,
      implement_chunk: nil,
      analyze_remediation: nil,
      updated_at: DateTime.utc_now()
    }
  end

  defp pr_description, do: %{pr_title: "t", pr_body: "b"}

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
      session_id: nil,
      error: nil
    }
  end

  # Writes a real `:converge` phase attempt + transcript through the store
  # and returns the `phase_attempts` entry `Evidence.collect/3`'s
  # `final_marker?/1` reads (`Store.transcript/1` is a real store call, not
  # mockable — the fixture must be real).
  defp converge_phase_attempt(run_key, feature_id, body) do
    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: minimal_attempt(feature_id, :converge),
        transcript: body
      })

    {repo_id, run_id} = run_key

    %{
      phase: :converge,
      ordinal: 1,
      attempt_id: Ids.attempt_id(repo_id, run_id, feature_id, :converge, 1)
    }
  end

  describe "collect/3 — all sources present" do
    test "populates every field from its durable source" do
      run_key = open_run()
      attempt = converge_phase_attempt(run_key, "001", converge_ready())

      feature_record = %{
        checkpoint: checkpoint_record(),
        pr_description: pr_description(),
        phase_attempts: [attempt]
      }

      evidence =
        Evidence.collect(feature(), feature_record,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert %Evidence{
               feature_id: "001",
               branch_committed?: true,
               last_boundary_phase: :converge,
               pr_record?: true,
               pr_remote?: :unknown,
               final_marker?: true
             } = evidence

      assert evidence.checkpoint.phase == :plan
    end
  end

  describe "collect/3 — each source absent individually" do
    test "absent pr_description degrades pr_record? to false, others unaffected, never raises" do
      run_key = open_run()
      attempt = converge_phase_attempt(run_key, "001", converge_ready())
      feature_record = %{checkpoint: checkpoint_record(), phase_attempts: [attempt]}

      evidence =
        Evidence.collect(feature(), feature_record,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.pr_record? == false
      assert evidence.checkpoint.phase == :plan
      assert evidence.final_marker? == true
    end

    test "absent checkpoint degrades checkpoint to nil, others unaffected, never raises" do
      run_key = open_run()
      attempt = converge_phase_attempt(run_key, "001", converge_ready())
      feature_record = %{pr_description: pr_description(), phase_attempts: [attempt]}

      evidence =
        Evidence.collect(feature(), feature_record,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.checkpoint == nil
      assert evidence.pr_record? == true
      assert evidence.final_marker? == true
    end

    test "absent converge phase attempt degrades final_marker? to false, others unaffected, never raises" do
      feature_record = %{
        checkpoint: checkpoint_record(),
        pr_description: pr_description(),
        phase_attempts: []
      }

      evidence =
        Evidence.collect(feature(), feature_record,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.final_marker? == false
      assert evidence.pr_record? == true
      assert evidence.checkpoint.phase == :plan
    end

    test "no durable sources at all (nil feature_record) degrades every field to unknown, never raises" do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil})
        )

      assert evidence.pr_record? == false
      assert evidence.checkpoint == nil
      assert evidence.final_marker? == false
      assert evidence.branch_committed? == false
      assert evidence.last_boundary_phase == nil
      assert evidence.pr_remote? == :unknown
    end
  end

  describe "collect/3 — damaged transcript" do
    # 018: a corrupt on-disk file has no store equivalent (Mnesia terms don't
    # parse-fail the way JSON does) — the analogous degradation is a
    # `phase_attempts` entry whose transcript the store can't retrieve
    # (absent/damaged), which `final_marker?/1` must treat as `false` rather
    # than raise, same fail-safe shape as the pre-018 corrupt-file case.
    test "a converge attempt with no matching transcript row degrades final_marker? to false and falls back to git evidence" do
      feature_record = %{
        pr_description: nil,
        phase_attempts: [
          %{
            phase: :converge,
            ordinal: 1,
            attempt_id: {"o:missing", "r000001", "001", :converge, 1}
          }
        ]
      }

      evidence =
        Evidence.collect(feature(), feature_record,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.pr_record? == false
      assert evidence.final_marker? == false
      assert evidence.branch_committed? == true
    end

    # T025 (quickstart.md Scenario 5, SC-006): a missing/damaged signal on an
    # otherwise-finished feature never crashes `Reconcile.status/3`, and
    # reaches a correct :done (non-PR done-signal still present) or a
    # {:conflict, _} (no other corroboration for the run's shape) — never a
    # silent wrong answer.
    test "a missing pr_description still lets Reconcile.status/3 reach :done (ad_hoc) or a conflict (breakdown), never raises" do
      run_key = open_run()
      attempt = converge_phase_attempt(run_key, "001", converge_ready())
      feature_record = %{pr_description: nil, phase_attempts: [attempt]}

      evidence =
        Evidence.collect(feature(), feature_record,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert Reconcile.status(:running, evidence, :ad_hoc) == :done

      assert {:conflict, _reason} =
               Reconcile.status(:running, evidence, {:breakdown, "core-ledger"})
    end
  end

  describe "collect/3 — :remote seam" do
    test "untouched when pr_record? is true" do
      test_pid = self()
      feature_record = %{pr_description: pr_description()}

      evidence =
        Evidence.collect(feature(), feature_record,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: nil}),
          remote: fn id ->
            send(test_pid, {:remote_called, id})
            true
          end
        )

      assert evidence.pr_record? == true
      assert evidence.pr_remote? == :unknown
      refute_received {:remote_called, _}
    end

    test "invoked when pr_record? is false, returns its result" do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> false end
        )

      assert evidence.pr_remote? == false
    end

    test "invoked when pr_record? is false, a raise maps to :unknown (offline-first, never fails collection)" do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> raise "network unreachable" end
        )

      assert evidence.pr_remote? == :unknown
    end

    test "invoked when pr_record? is false, an unrecognized return value maps to :unknown" do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> %{unexpected: "shape"} end
        )

      assert evidence.pr_remote? == :unknown
    end

    test "invoked when pr_record? is false, a throw maps to :unknown (never fails collection)" do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> throw(:network_down) end
        )

      assert evidence.pr_remote? == :unknown
    end
  end

  describe "collect/3 — default opts" do
    test "the default-arg call uses the default :git/:remote seams without raising" do
      repo = base_repo()
      Application.put_env(:speckit_orchestrator, :repo, repo)

      evidence = Evidence.collect(feature("999"), nil)

      assert evidence.branch_committed? == false
      assert evidence.pr_remote? == :unknown
    end
  end

  describe "default :git seam — boundary-commit parse" do
    test "parses the newest boundary-commit subject, ignoring non-boundary subjects" do
      repo = base_repo()
      Application.put_env(:speckit_orchestrator, :repo, repo)

      git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
      commit(repo, "speckit: 001 checkpoint after specify")
      commit(repo, "speckit: 001 checkpoint after clarify")
      commit(repo, "speckit: feature 001 pipeline artifacts (done)")
      commit(repo, "speckit: 001 checkpoint after plan")

      evidence = Evidence.collect(feature(), nil, [])

      assert evidence.branch_committed? == true
      assert evidence.last_boundary_phase == :plan
    end

    test "no matching branch degrades to branch_committed?: false, last_boundary_phase: nil" do
      repo = base_repo()
      Application.put_env(:speckit_orchestrator, :repo, repo)

      evidence = Evidence.collect(feature("999"), nil, [])

      assert evidence.branch_committed? == false
      assert evidence.last_boundary_phase == nil
    end
  end

  describe "default :git seam — task-phase commits (015 chunking) are not phase boundaries" do
    test "a task-phase commit subject does not match the boundary regex directly" do
      assert Regex.named_captures(
               ~r/^speckit: (?<id>\S+) checkpoint after (?<phase>\w+)$/,
               "speckit: 001 implement task-phase 1/3 Setup"
             ) == nil
    end

    test "a branch carrying both task-phase commits and the tasks boundary still reports :tasks" do
      repo = base_repo()
      Application.put_env(:speckit_orchestrator, :repo, repo)

      git!(repo, ["checkout", "-q", "-b", "feature/001-core-ledger"])
      commit(repo, "speckit: 001 checkpoint after specify")
      commit(repo, "speckit: 001 checkpoint after tasks")
      # Chunked implement's per-task-phase boundary commits (FR-023a) — newer
      # than the "checkpoint after tasks" commit, but must not be mistaken for
      # a later phase boundary (research R5): a match here would make crash
      # recovery believe implement had completed and resume at converge over
      # a half-built tree.
      commit(repo, "speckit: 001 implement task-phase 1/3 Setup")
      commit(repo, "speckit: 001 implement task-phase 2/3 Core")
      commit(repo, "speckit: 001 implement task-phase 3/3 Polish")

      evidence = Evidence.collect(feature(), nil, [])

      assert evidence.branch_committed? == true
      assert evidence.last_boundary_phase == :tasks
    end
  end
end
