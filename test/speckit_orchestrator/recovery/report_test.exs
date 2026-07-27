defmodule SpeckitOrchestrator.Recovery.ReportTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Recovery.Report

  test "format/1 renders the reconciled table with a CONFLICT row and footer" do
    report = %Report{
      features: [
        %{
          id: "001",
          slug: "core-ledger",
          recorded: :running,
          reconciled: :done,
          resume_phase: nil,
          corrected?: true
        },
        %{
          id: "002",
          slug: "core-ledger",
          recorded: :pending,
          reconciled: :pending,
          resume_phase: nil,
          corrected?: false
        },
        %{
          id: "003",
          slug: "core-ledger",
          recorded: :escalated,
          reconciled: :escalated,
          resume_phase: nil,
          corrected?: false
        },
        %{
          id: "006",
          slug: "core-ledger",
          recorded: :done,
          reconciled: {:conflict, :done_without_artifacts},
          resume_phase: nil,
          corrected?: true
        }
      ],
      conflicts: [%{id: "006", reason: :done_without_artifacts}],
      next_runnable: ["002"],
      spend: 42.5,
      run_shape: {:breakdown, "core-ledger"}
    }

    out = Report.format(report)

    assert out =~ "Feature"
    assert out =~ "Recorded"
    assert out =~ "Reconciled"
    assert out =~ "Note"
    assert out =~ "001"
    assert out =~ "done"
    assert out =~ "next runnable"
    assert out =~ "held (human gate)"
    assert out =~ "CONFLICT — done_without_artifacts; human resolve"
    assert out =~ "Spend: $42.50 (preserved)"
    assert out =~ ~s(Next runnable: ["002"])
  end

  test "format/1 (016 US3) renders absent_from_record / absent_from_backlog discrepancy notes and footer" do
    report = %Report{
      features: [
        # backlog-only (absent_from_record): no recorded status at all.
        %{
          id: "002",
          slug: "core-ledger",
          recorded: nil,
          reconciled: :pending,
          resume_phase: nil,
          corrected?: true
        },
        # record-only (absent_from_backlog): kept verbatim, unreconciled —
        # `reconciled_label/1`'s raw-atom fallback (`:running` is not a
        # `Reconcile.result/0` shape).
        %{
          id: "004",
          slug: "core-ledger",
          recorded: :running,
          reconciled: :running,
          resume_phase: nil,
          corrected?: false
        }
      ],
      conflicts: [],
      next_runnable: ["002"],
      spend: 10.0,
      run_shape: :ad_hoc,
      discrepancies: [
        %{kind: :absent_from_record, id: "002", detail: :pending},
        %{kind: :absent_from_backlog, id: "004", detail: :running}
      ]
    }

    out = Report.format(report)

    assert out =~ "—"
    assert out =~ "running"
    # Discrepancy note wins over "next runnable" for 002 (both true here).
    assert out =~ "restored from backlog (absent from record)"
    assert out =~ "restored from record (absent from backlog)"
    assert out =~ "Discrepancies: 002 absent_from_record, 004 absent_from_backlog"
  end

  test "format/1 covers every reconciled_label/1 clause, an integer spend, and a blank note" do
    report = %Report{
      features: [
        %{
          id: "004",
          slug: "core-ledger",
          recorded: :halted,
          reconciled: :halted,
          resume_phase: nil,
          corrected?: false
        },
        %{
          id: "005",
          slug: "core-ledger",
          recorded: :failed,
          reconciled: :failed,
          resume_phase: nil,
          corrected?: false
        },
        %{
          id: "001",
          slug: "core-ledger",
          recorded: :running,
          reconciled: {:resume, :tasks},
          resume_phase: :tasks,
          corrected?: false
        },
        # Not a conflict, not held, no discrepancy, not next runnable, not
        # corrected — the final blank-note fallback.
        %{
          id: "007",
          slug: "core-ledger",
          recorded: :pending,
          reconciled: :pending,
          resume_phase: nil,
          corrected?: false
        }
      ],
      conflicts: [],
      next_runnable: [],
      spend: 10,
      run_shape: :ad_hoc
    }

    out = Report.format(report)

    assert out =~ "failed"
    assert out =~ "running (resume: tasks)"
    assert out =~ "Spend: $10 (preserved)"

    # "007" matches no cond clause (not conflicted, held, discrepant, next
    # runnable, or corrected) — its row's Note column is blank.
    row_007_line = out |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "007"))
    refute row_007_line =~ ~r/held|CONFLICT|next runnable|corrected|restored/
  end
end
