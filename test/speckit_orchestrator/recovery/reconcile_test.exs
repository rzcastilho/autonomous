defmodule SpeckitOrchestrator.Recovery.ReconcileTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Pipeline
  alias SpeckitOrchestrator.Recovery.{Evidence, Reconcile}

  defp evidence(overrides \\ %{}) do
    struct(
      %Evidence{
        feature_id: "001",
        branch_committed?: false,
        last_boundary_phase: nil,
        pr_record?: false,
        pr_remote?: :unknown,
        checkpoint: nil,
        final_marker?: false
      },
      overrides
    )
  end

  # ---- US1 (T006): clause 4 — non-terminal done-signal ----------------------

  describe "status/3 clause 4 — non-terminal done-signal" do
    test "recorded :running, breakdown/PR-workflow done-signal -> :done" do
      ev = evidence(%{pr_record?: true, branch_committed?: true})
      assert Reconcile.status(:running, ev, {:breakdown, "core-ledger"}) == :done
    end

    test "recorded :pending, breakdown/PR-workflow done-signal -> :done" do
      ev = evidence(%{pr_record?: true, branch_committed?: true})
      assert Reconcile.status(:pending, ev, {:breakdown, "core-ledger"}) == :done
    end

    test "recorded :running, ad_hoc non-PR-workflow done-signal -> :done" do
      ev = evidence(%{final_marker?: true, branch_committed?: true})
      assert Reconcile.status(:running, ev, :ad_hoc) == :done
    end

    test "recorded :pending, ad_hoc non-PR-workflow done-signal -> :done" do
      ev = evidence(%{final_marker?: true, branch_committed?: true})
      assert Reconcile.status(:pending, ev, :ad_hoc) == :done
    end
  end

  describe "done_signal?/2" do
    test "PR-workflow ({:breakdown, _}) ignores final_marker? entirely" do
      ev = evidence(%{pr_record?: true, branch_committed?: true, final_marker?: false})
      assert Reconcile.done_signal?(ev, {:breakdown, "core-ledger"}) == true

      ev2 = evidence(%{pr_record?: false, branch_committed?: true, final_marker?: true})
      assert Reconcile.done_signal?(ev2, {:breakdown, "core-ledger"}) == false
    end

    test "non-PR-workflow (:ad_hoc) ignores pr_record? entirely" do
      ev = evidence(%{final_marker?: true, branch_committed?: true, pr_record?: false})
      assert Reconcile.done_signal?(ev, :ad_hoc) == true

      ev2 = evidence(%{final_marker?: false, branch_committed?: true, pr_record?: true})
      assert Reconcile.done_signal?(ev2, :ad_hoc) == false
    end

    test "pr_remote?: :unknown never flips a local pr_record?/branch_committed? true to false" do
      ev = evidence(%{pr_record?: true, branch_committed?: true, pr_remote?: :unknown})
      assert Reconcile.done_signal?(ev, {:breakdown, "core-ledger"}) == true
    end

    test "pr_remote?: false (unreachable/absent) still never flips a local true to false" do
      ev = evidence(%{pr_record?: true, branch_committed?: true, pr_remote?: false})
      assert Reconcile.done_signal?(ev, {:breakdown, "core-ledger"}) == true
    end

    test "requires branch_committed? even with a local pr_record?" do
      ev = evidence(%{pr_record?: true, branch_committed?: false})
      assert Reconcile.done_signal?(ev, {:breakdown, "core-ledger"}) == false
    end
  end

  # ---- US2 (T013): clause 5 — mid-run resume ---------------------------------

  describe "status/3 clause 5 — mid-run resume" do
    test "recorded :running, not a done-signal, branch has a boundary commit -> {:resume, phase_after}" do
      ev = evidence(%{branch_committed?: true, last_boundary_phase: :plan})
      assert Reconcile.status(:running, ev, {:breakdown, "core-ledger"}) == {:resume, :tasks}
    end

    test "clause 4 (done-signal) takes precedence over clause 5 (resume) when both could apply" do
      ev =
        evidence(%{
          pr_record?: true,
          branch_committed?: true,
          last_boundary_phase: :implement
        })

      assert Reconcile.status(:running, ev, {:breakdown, "core-ledger"}) == :done
    end
  end

  describe "phase_after/1" do
    test "returns the Pipeline phase following each non-terminal boundary" do
      assert Reconcile.phase_after(:specify) == :clarify
      assert Reconcile.phase_after(:clarify) == :plan
      assert Reconcile.phase_after(:plan) == :tasks
      assert Reconcile.phase_after(:tasks) == :analyze
      assert Reconcile.phase_after(:analyze) == :implement
      assert Reconcile.phase_after(:implement) == :converge
    end

    test "covers every non-terminal Pipeline phase (table sweep)" do
      for phase <- Pipeline.phases() -- [:converge] do
        assert Reconcile.phase_after(phase) == elem(Pipeline.next(phase, :ok, %{}), 1)
      end
    end
  end

  # ---- US2 (T013): clause 6 — never-started pending --------------------------

  describe "status/3 clause 6 — never-started pending" do
    test "recorded :pending, no branch and no artifacts -> :pending" do
      ev = evidence()
      assert Reconcile.status(:pending, ev, {:breakdown, "core-ledger"}) == :pending
      assert Reconcile.status(:pending, ev, :ad_hoc) == :pending
    end

    test "recorded :running, no branch and no artifacts -> :pending (crashed before the first boundary commit, nothing to resume)" do
      ev = evidence()
      assert Reconcile.status(:running, ev, {:breakdown, "core-ledger"}) == :pending
      assert Reconcile.status(:running, ev, :ad_hoc) == :pending
    end
  end

  # ---- US3 (T017): clause 1 — gate passthrough ------------------------------

  describe "status/3 clause 1 — human gates are inviolable" do
    test "escalated/halted pass through unchanged regardless of evidence" do
      ev = evidence(%{branch_committed?: true, pr_record?: true})
      assert Reconcile.status(:escalated, ev, :ad_hoc) == :escalated
      assert Reconcile.status(:halted, ev, :ad_hoc) == :halted
    end

    test "escalated/halted pass through unchanged with no evidence at all" do
      ev = evidence()
      assert Reconcile.status(:escalated, ev, {:breakdown, "core-ledger"}) == :escalated
      assert Reconcile.status(:halted, ev, {:breakdown, "core-ledger"}) == :halted
    end

    test "gate safety sweep: no evidence/shape combination advances a gate" do
      shapes = [{:breakdown, "core-ledger"}, :ad_hoc]
      bool_or_unknown = [true, false, :unknown]
      phases = [nil | Pipeline.phases()]

      for gate <- [:escalated, :halted],
          shape <- shapes,
          branch? <- [true, false],
          phase <- phases,
          pr? <- [true, false],
          remote <- bool_or_unknown,
          final? <- [true, false] do
        ev =
          evidence(%{
            branch_committed?: branch?,
            last_boundary_phase: phase,
            pr_record?: pr?,
            pr_remote?: remote,
            final_marker?: final?
          })

        assert Reconcile.status(gate, ev, shape) == gate
      end
    end
  end

  # ---- US3 (T017): clause 2 — failed passthrough -----------------------------

  describe "status/3 clause 2 — failed stays failed" do
    test "failed passes through unchanged regardless of evidence" do
      ev = evidence(%{branch_committed?: true, pr_record?: true, final_marker?: true})
      assert Reconcile.status(:failed, ev, :ad_hoc) == :failed
      assert Reconcile.status(:failed, evidence(), {:breakdown, "core-ledger"}) == :failed
    end
  end

  # ---- US3 (T017): clause 3 — done requires corroboration -------------------

  describe "status/3 clause 3 — done requires corroboration" do
    test "recorded :done, breakdown/PR-workflow corroborated (branch + PR) -> :done" do
      ev = evidence(%{pr_record?: true, branch_committed?: true})
      assert Reconcile.status(:done, ev, {:breakdown, "core-ledger"}) == :done
    end

    test "recorded :done, ad_hoc corroborated (branch + final marker) -> :done" do
      ev = evidence(%{final_marker?: true, branch_committed?: true})
      assert Reconcile.status(:done, ev, :ad_hoc) == :done
    end

    test "recorded :done, no branch/no PR -> {:conflict, :done_without_artifacts}" do
      ev = evidence()
      assert Reconcile.status(:done, ev, {:breakdown, "core-ledger"}) ==
               {:conflict, :done_without_artifacts}
    end

    test "recorded :done, breakdown workflow with branch but no PR record -> conflict" do
      ev = evidence(%{branch_committed?: true, pr_record?: false})
      assert Reconcile.status(:done, ev, {:breakdown, "core-ledger"}) ==
               {:conflict, :done_without_artifacts}
    end

    test "recorded :done, ad_hoc with branch but no final marker -> conflict" do
      ev = evidence(%{branch_committed?: true, final_marker?: false})
      assert Reconcile.status(:done, ev, :ad_hoc) == {:conflict, :done_without_artifacts}
    end
  end

  # ---- US3 (T017): clause 6 confirmation + clause 7 — contradictions --------

  describe "status/3 clause 6 — pending-never-started confirmation" do
    test "recorded :pending with zero corroborating evidence of any kind -> :pending" do
      ev = evidence()
      assert Reconcile.status(:pending, ev, {:breakdown, "core-ledger"}) == :pending
      assert Reconcile.status(:pending, ev, :ad_hoc) == :pending
    end
  end

  describe "status/3 clause 7 — contradictions" do
    test "pr_record? without branch_committed? -> {:conflict, :pr_without_branch}" do
      ev = evidence(%{pr_record?: true, branch_committed?: false})
      assert Reconcile.status(:running, ev, {:breakdown, "core-ledger"}) ==
               {:conflict, :pr_without_branch}

      assert Reconcile.status(:pending, ev, {:breakdown, "core-ledger"}) ==
               {:conflict, :pr_without_branch}
    end

    test "recorded :pending with unexplained branch progress but no done-signal -> conflict" do
      ev = evidence(%{branch_committed?: true, last_boundary_phase: :plan})
      assert Reconcile.status(:pending, ev, {:breakdown, "core-ledger"}) ==
               {:conflict, :ambiguous_evidence}
    end

    test "never a silent guess: residual ambiguity always resolves to a conflict, not a fabricated result" do
      ev = evidence(%{checkpoint: %{last_phase: :plan, status: :in_progress}})
      assert {:conflict, _reason} = Reconcile.status(:pending, ev, :ad_hoc)
    end
  end

  # ---- US3 (T017): purity ----------------------------------------------------

  describe "status/3 purity" do
    test "identical inputs produce identical outputs, no I/O, no process state" do
      cases = [
        {:escalated, evidence(), :ad_hoc},
        {:halted, evidence(%{branch_committed?: true}), {:breakdown, "core-ledger"}},
        {:failed, evidence(), :ad_hoc},
        {:done, evidence(%{pr_record?: true, branch_committed?: true}), {:breakdown, "core-ledger"}},
        {:done, evidence(), {:breakdown, "core-ledger"}},
        {:running, evidence(%{pr_record?: true, branch_committed?: true}), {:breakdown, "core-ledger"}},
        {:running, evidence(%{branch_committed?: true, last_boundary_phase: :plan}), :ad_hoc},
        {:pending, evidence(), :ad_hoc},
        {:pending, evidence(%{pr_record?: true}), {:breakdown, "core-ledger"}}
      ]

      for {recorded, ev, shape} <- cases do
        results = for _ <- 1..5, do: Reconcile.status(recorded, ev, shape)
        assert Enum.uniq(results) == [Enum.at(results, 0)]
      end
    end
  end
end
