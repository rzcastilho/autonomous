defmodule SpeckitOrchestrator.Recovery.ReportTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Recovery.Report

  test "format/1 renders the reconciled table with a CONFLICT row and footer" do
    report = %Report{
      features: [
        %{id: "001", slug: "core-ledger", recorded: :running, reconciled: :done, resume_phase: nil, corrected?: true},
        %{id: "002", slug: "core-ledger", recorded: :pending, reconciled: :pending, resume_phase: nil, corrected?: false},
        %{id: "003", slug: "core-ledger", recorded: :escalated, reconciled: :escalated, resume_phase: nil, corrected?: false},
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
end
