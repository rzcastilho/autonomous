defmodule SpeckitOrchestrator.Recovery.EvidenceTest do
  # async: false — mutates the global :transcript_root/:repo app env.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Feature, Recovery.Evidence, Recovery.Reconcile}

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

  defp feature(id \\ "001"), do: %Feature{id: id, slug: "core-ledger", path: "#{id}.md"}

  defp fake_git(result), do: fn _feature -> result end

  defp write_durable(root, id, filename, content) do
    dir = Path.join(root, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, filename), content)
  end

  defp pr_json, do: Jason.encode!(%{pr_title: "t", pr_body: "b"})
  defp checkpoint_json, do: Jason.encode!(%{"last_phase" => "plan", "status" => "in_progress"})
  defp converge_ready, do: "Tests green, committed.\n\n## CONVERGE: READY\n"

  setup do
    root = Path.join(System.tmp_dir!(), "ev_#{System.unique_integer([:positive])}")
    prev_transcript = Application.get_env(:speckit_orchestrator, :transcript_root)
    prev_repo = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev_transcript,
        do: Application.put_env(:speckit_orchestrator, :transcript_root, prev_transcript),
        else: Application.delete_env(:speckit_orchestrator, :transcript_root)

      if prev_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    %{root: root}
  end

  describe "collect/3 — all sources present" do
    test "populates every field from its durable source", %{root: root} do
      write_durable(root, "001", "pr.json", pr_json())
      write_durable(root, "001", "checkpoint.json", checkpoint_json())
      write_durable(root, "001", "07-converge.md", converge_ready())

      evidence =
        Evidence.collect(feature(), nil,
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

      assert evidence.checkpoint["last_phase"] == "plan"
    end
  end

  describe "collect/3 — each source absent individually" do
    test "absent pr.json degrades pr_record? to false, others unaffected, never raises", %{
      root: root
    } do
      write_durable(root, "001", "checkpoint.json", checkpoint_json())
      write_durable(root, "001", "07-converge.md", converge_ready())

      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.pr_record? == false
      assert evidence.checkpoint["last_phase"] == "plan"
      assert evidence.final_marker? == true
    end

    test "absent checkpoint.json degrades checkpoint to nil, others unaffected, never raises", %{
      root: root
    } do
      write_durable(root, "001", "pr.json", pr_json())
      write_durable(root, "001", "07-converge.md", converge_ready())

      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.checkpoint == nil
      assert evidence.pr_record? == true
      assert evidence.final_marker? == true
    end

    test "absent 07-converge.md degrades final_marker? to false, others unaffected, never raises",
         %{root: root} do
      write_durable(root, "001", "pr.json", pr_json())
      write_durable(root, "001", "checkpoint.json", checkpoint_json())

      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.final_marker? == false
      assert evidence.pr_record? == true
      assert evidence.checkpoint["last_phase"] == "plan"
    end

    test "no durable sources at all degrades every field to unknown, never raises", %{root: _root} do
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

  describe "collect/3 — corrupt pr.json" do
    test "truncated pr.json degrades pr_record? to false and falls back to git/transcript evidence",
         %{root: root} do
      write_durable(root, "001", "pr.json", "{\"pr_title\": \"t\", \"pr_bo")
      write_durable(root, "001", "07-converge.md", converge_ready())

      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert evidence.pr_record? == false
      assert evidence.final_marker? == true
      assert evidence.branch_committed? == true
    end

    # T025 (quickstart.md Scenario 5, SC-006): the collector's fallback must
    # keep the downstream decision table honest — a corrupt pr.json on an
    # otherwise-finished feature never crashes `Reconcile.status/3`, and
    # reaches a correct :done (non-PR done-signal still present) or a
    # {:conflict, _} (no other corroboration for the run's shape) — never a
    # silent wrong answer.
    test "truncated pr.json still lets Reconcile.status/3 reach :done (ad_hoc) or a conflict (breakdown), never raises",
         %{root: root} do
      write_durable(root, "001", "pr.json", "{\"pr_title\": \"t\", \"pr_bo")
      write_durable(root, "001", "07-converge.md", converge_ready())

      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: true, last_boundary_phase: :converge})
        )

      assert Reconcile.status(:running, evidence, :ad_hoc) == :done
      assert {:conflict, _reason} = Reconcile.status(:running, evidence, {:breakdown, "core-ledger"})
    end
  end

  describe "collect/3 — :remote seam" do
    test "untouched when pr_record? is true", %{root: root} do
      write_durable(root, "001", "pr.json", pr_json())
      test_pid = self()

      evidence =
        Evidence.collect(feature(), nil,
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

    test "invoked when pr_record? is false, returns its result", %{root: _root} do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> false end
        )

      assert evidence.pr_remote? == false
    end

    test "invoked when pr_record? is false, a raise maps to :unknown (offline-first, never fails collection)",
         %{root: _root} do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> raise "network unreachable" end
        )

      assert evidence.pr_remote? == :unknown
    end

    test "invoked when pr_record? is false, an unrecognized return value maps to :unknown", %{
      root: _root
    } do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> %{unexpected: "shape"} end
        )

      assert evidence.pr_remote? == :unknown
    end

    test "invoked when pr_record? is false, a throw maps to :unknown (never fails collection)", %{
      root: _root
    } do
      evidence =
        Evidence.collect(feature(), nil,
          git: fake_git(%{branch_committed?: false, last_boundary_phase: nil}),
          remote: fn _id -> throw(:network_down) end
        )

      assert evidence.pr_remote? == :unknown
    end
  end

  describe "collect/2 — default opts" do
    test "the default-arg 2-arity call uses the default :git/:remote seams without raising" do
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
end
