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

  test "format_status/1 shows number and spec_number under distinct labels" do
    snapshot = %{
      per_feature: %{
        "002" => %{status: :done, elapsed_ms: 100, spec_number: 15},
        "001" => %{status: :running, elapsed_ms: 200, spec_number: nil}
      },
      totals: %{running: 1, done: 1},
      spend: 0.0,
      breaker_tripped: false,
      finished?: false
    }

    out = Report.format_status(snapshot)

    assert out =~ "SPEC"
    assert out =~ "015"
    assert out =~ "not allocated"
  end

  describe "format_reason/1 (029)" do
    test "renders every {:needs_human, sub} variant distinctly" do
      assert Report.format_reason({:needs_human, :rounds_exhausted}) =~ "rounds exhausted"
      assert Report.format_reason({:needs_human, :answer_timeout}) =~ "answer timeout"
      assert Report.format_reason({:needs_human, :breaker}) =~ "breaker"
      assert Report.format_reason({:needs_human, :drained}) =~ "drained"
      assert Report.format_reason({:needs_human, :restart}) =~ "restart"
    end

    test "plain :needs_human (mode off) renders byte-identical to before" do
      assert Report.format_reason(:needs_human) == inspect(:needs_human)
    end

    test "an unrelated reason still falls through to inspect/1" do
      assert Report.format_reason({:empty_checkpoint, :plan}) == "plan committed no change"
      assert Report.format_reason(:some_other_reason) == inspect(:some_other_reason)
    end
  end

  test "format_status/1 handles an empty run" do
    out =
      Report.format_status(%{
        per_feature: %{},
        totals: %{},
        spend: 0.0,
        breaker_tripped: false,
        finished?: false
      })

    assert out =~ "FEATURE"
    assert out =~ "(none)"
  end

  # ---- 029 US4: the `awaiting:` line (contracts/facade-api.md Status) --------

  describe "format_status/1 awaiting: line" do
    test "shows STATUS awaiting_answers and the round/waited/left line when a feature is waiting" do
      now = DateTime.utc_now()

      snapshot = %{
        per_feature: %{
          "007" => %{status: :awaiting_answers, elapsed_ms: 4_000, spec_number: 7}
        },
        totals: %{awaiting_answers: 1},
        spend: 0.0,
        breaker_tripped: false,
        finished?: false,
        awaiting: %{
          "007" => %{
            round: 1,
            max_rounds: 3,
            started_at: DateTime.add(now, -240, :second),
            deadline_at: DateTime.add(now, 1_620, :second)
          }
        }
      }

      out = Report.format_status(snapshot)

      assert out =~ "awaiting_answers"
      assert out =~ ~r/awaiting: 007 round 1\/3 waited 4m 2[67]m left/
    end

    test "the line is absent when mode is off (no :awaiting key at all — mode-off byte-identical)" do
      out =
        Report.format_status(%{
          per_feature: %{"001" => %{status: :running, elapsed_ms: 100}},
          totals: %{running: 1},
          spend: 0.0,
          breaker_tripped: false,
          finished?: false
        })

      refute out =~ "awaiting:"
    end

    test "the line is absent when :awaiting is present but empty" do
      out =
        Report.format_status(%{
          per_feature: %{},
          totals: %{},
          spend: 0.0,
          breaker_tripped: false,
          finished?: false,
          awaiting: %{}
        })

      refute out =~ "awaiting:"
    end
  end

  # ---- 029 US4: the `clarify:` block (data-model.md Coordinator report) -----

  describe "format_status/1 clarify: line" do
    test "renders a clarify: block only when the report's clarify_rounds is non-empty" do
      out =
        Report.format_status(%{
          per_feature: %{},
          totals: %{},
          spend: 0.0,
          breaker_tripped: false,
          finished?: true,
          report: %{clarify_rounds: %{"007" => [%{round: 1}, %{round: 2}]}}
        })

      assert out =~ "clarify: 007=2"
    end

    test "the clarify: line is absent (not empty) when clarify_rounds is %{} — mode-off byte-identical" do
      out =
        Report.format_status(%{
          per_feature: %{},
          totals: %{},
          spend: 0.0,
          breaker_tripped: false,
          finished?: true,
          report: %{clarify_rounds: %{}}
        })

      refute out =~ "clarify:"
    end

    test "absent entirely when the snapshot carries no :report at all" do
      out =
        Report.format_status(%{
          per_feature: %{},
          totals: %{},
          spend: 0.0,
          breaker_tripped: false,
          finished?: false
        })

      refute out =~ "clarify:"
    end
  end
end
