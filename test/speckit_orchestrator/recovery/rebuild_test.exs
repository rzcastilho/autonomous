defmodule SpeckitOrchestrator.Recovery.RebuildTest do
  # async: true — pure/hermetic (research.md D10 layer 1): no global app env,
  # no real git; :git/:remote are always injected, and each test builds its
  # own isolated %Layout{} tmp dir so Checkpoint/Describe reads never collide
  # across tests.
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Feature, Layout}
  alias SpeckitOrchestrator.Recovery.Rebuild

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "core-ledger", path: "#{id}.md", prereqs: prereqs}

  defp record_feature(id, prereqs \\ []),
    do: %{"id" => id, "slug" => "core-ledger", "path" => "#{id}.md", "prereqs" => prereqs}

  defp isolated_layout do
    dir = Path.join(System.tmp_dir!(), "rb_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %Layout{worktree_root: dir, transcript_root: dir, in_repo_rel: "ad-hoc"}
  end

  defp write_converge_marker(layout, id) do
    path = Path.join([layout.transcript_root, id, "07-converge.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "Tests green.\n\n## CONVERGE: READY\n")
  end

  # No evidence of any kind, for any feature — a hermetic default matching
  # `Evidence.default_git/1`'s "no branch" shape without touching git.
  defp no_evidence(_feature), do: %{branch_committed?: false, last_boundary_phase: nil}

  # ---- union rule + status mapping table (T027) ------------------------------

  test "propose/3: union order, both-present-clean, and absent_from_record" do
    layout = isolated_layout()
    write_converge_marker(layout, "001")

    git = fn
      %{id: "001"} -> %{branch_committed?: true, last_boundary_phase: :converge}
      _ -> no_evidence(nil)
    end

    backlog = [feat("001"), feat("002", ["001"]), feat("003", ["002"])]

    record = %{
      "features" => [record_feature("001")],
      "statuses" => %{"001" => "done"},
      "spend" => 0
    }

    assert {:ok, proposal} = Rebuild.propose(record, backlog, layout: layout, git: git)

    assert Enum.map(proposal.features, & &1.id) == ["001", "002", "003"]
    assert proposal.statuses == %{"001" => :done, "002" => :pending, "003" => :pending}
    refute Map.has_key?(proposal.resume_phases, "001")

    assert Enum.sort(for(d <- proposal.discrepancies, do: {d.kind, d.id})) == [
             {:absent_from_record, "002"},
             {:absent_from_record, "003"}
           ]

    assert proposal.source == %{
             record_ids: ["001"],
             backlog_ids: ["001", "002", "003"],
             backlog_root: nil
           }

    row_001 = Enum.find(proposal.report.features, &(&1.id == "001"))
    assert row_001.reconciled == :done
    assert row_001.corrected? == false
  end

  test "propose/3: both-present conflict reconciles to :blocked and reports :unreconcilable" do
    layout = isolated_layout()
    # No corroborating evidence at all for "001" despite a recorded :done.

    backlog = [feat("001")]

    record = %{
      "features" => [record_feature("001")],
      "statuses" => %{"001" => "done"},
      "spend" => 0
    }

    assert {:ok, proposal} = Rebuild.propose(record, backlog, layout: layout, git: &no_evidence/1)

    assert proposal.statuses["001"] == :blocked

    assert [%{kind: :unreconcilable, id: "001", detail: :done_without_artifacts}] =
             proposal.discrepancies

    assert %{id: "001", reason: :done_without_artifacts} in proposal.report.conflicts
  end

  test "propose/3: record-only feature (absent_from_backlog) is kept verbatim, unreconciled" do
    layout = isolated_layout()
    write_converge_marker(layout, "001")

    git = fn
      %{id: "001"} -> %{branch_committed?: true, last_boundary_phase: :converge}
      _ -> no_evidence(nil)
    end

    backlog = [feat("001")]

    record = %{
      "features" => [record_feature("001"), record_feature("002")],
      "statuses" => %{"001" => "done", "002" => "running"},
      "spend" => 0
    }

    assert {:ok, proposal} = Rebuild.propose(record, backlog, layout: layout, git: git)

    assert Enum.map(proposal.features, & &1.id) == ["001", "002"]
    assert proposal.statuses["002"] == :running
    refute Map.has_key?(proposal.resume_phases, "002")
    assert [%{kind: :absent_from_backlog, id: "002", detail: :running}] = proposal.discrepancies

    row_002 = Enum.find(proposal.report.features, &(&1.id == "002"))
    assert row_002.recorded == :running
    assert row_002.reconciled == :running
    assert row_002.corrected? == false
  end

  test "propose/3: a prereq missing from the union refuses without collecting evidence" do
    layout = isolated_layout()

    # Backlog names 001 with a prereq the record never mentions and the
    # backlog never defines — evidence must never be collected once this is
    # found (asserted via a :git seam that raises if invoked).
    exploding_git = fn _ -> raise "evidence must not be collected for a refused proposal" end

    backlog = [feat("001", ["999"])]

    record = %{
      "features" => [record_feature("001", ["999"])],
      "statuses" => %{"001" => "pending"},
      "spend" => 0
    }

    assert {:error, {:inconsistent, discrepancies}} =
             Rebuild.propose(record, backlog, layout: layout, git: exploding_git)

    assert discrepancies == [%{kind: :prereq_missing, id: "001", detail: "999"}]
  end
end
