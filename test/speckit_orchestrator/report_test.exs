defmodule SpeckitOrchestrator.ReportTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Report

  test "format_status/1 renders a table with per-feature rows and totals" do
    snapshot = %{
      per_feature: %{
        "001" => %{status: :running, elapsed_ms: 1500},
        "002" => %{status: :done, elapsed_ms: nil}
      },
      totals: %{running: 1, done: 1},
      spend: 1.5,
      breaker_tripped: false,
      finished?: false
    }

    out = Report.format_status(snapshot)

    assert out =~ "FEATURE"
    assert out =~ "STATUS"
    assert out =~ "001"
    assert out =~ "running"
    assert out =~ "1.5s"
    assert out =~ "done"
    assert out =~ "running=1"
    assert out =~ "spend:  $1.50"
    assert out =~ "state:  running"
  end

  test "format_status/1 marks a tripped breaker and finished run" do
    snapshot = %{
      per_feature: %{"001" => %{status: :halted, elapsed_ms: 200}},
      totals: %{halted: 1},
      spend: 30.0,
      breaker_tripped: true,
      finished?: true
    }

    out = Report.format_status(snapshot)
    assert out =~ "[BREAKER TRIPPED]"
    assert out =~ "state:  finished"
    assert out =~ "200ms"
  end

  test "format_status/1 handles an empty run" do
    out = Report.format_status(%{per_feature: %{}, totals: %{}, spend: 0.0, breaker_tripped: false, finished?: false})
    assert out =~ "FEATURE"
    assert out =~ "(none)"
  end
end
