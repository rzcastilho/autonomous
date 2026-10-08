defmodule Autonomous.ReportTest do
  use ExUnit.Case, async: true

  alias Autonomous.Report

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

  test "format_status/1 shows the containment line after spend only when permissive" do
    snapshot = %{
      per_feature: %{},
      totals: %{},
      spend: 1.5,
      breaker_tripped: false,
      finished?: false,
      containment_profile: "permissive"
    }

    out = Report.format_status(snapshot)

    spend_idx = :binary.match(out, "spend:  $1.50") |> elem(0)
    containment_idx = :binary.match(out, "containment: permissive (no pack deny list)") |> elem(0)
    assert containment_idx > spend_idx
  end

  test "format_status/1 omits the containment line when strict" do
    snapshot = %{
      per_feature: %{},
      totals: %{},
      spend: 0.0,
      breaker_tripped: false,
      finished?: false,
      containment_profile: "strict"
    }

    refute Report.format_status(snapshot) =~ "containment:"
  end

  test "format_status/1 omits the containment line when absent (pre-030 byte-identity)" do
    snapshot = %{
      per_feature: %{},
      totals: %{},
      spend: 0.0,
      breaker_tripped: false,
      finished?: false
    }

    refute Report.format_status(snapshot) =~ "containment:"
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

  describe "format_reason/1 (032 backgrounded_command)" do
    test "phase atom, single command" do
      assert Report.format_reason({:backgrounded_command, :implement, ["mix test"]}) ==
               "implement ended waiting on backgrounded command: mix test"
    end

    test "truncates the command to 120 chars and counts the rest" do
      long = String.duplicate("x", 300)

      assert Report.format_reason({:backgrounded_command, :plan, [long, "b", "c"]}) ==
               "plan ended waiting on backgrounded command: " <>
                 String.duplicate("x", 120) <> " (+2 more)"
    end

    test "a chunk ref renders its task-phase label" do
      ref = %Autonomous.TaskPhaseRef{ordinal: 3, number: "3", title: "Polish"}

      assert Report.format_reason({:backgrounded_command, ref, ["npm run e2e"]}) ==
               ~s(task-phase 3 "Polish" ended waiting on backgrounded command: npm run e2e)
    end
  end

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

  describe "format_reason/1 (034 session_died)" do
    test "phase atom, start_failed" do
      d = %{kind: :start_failed, excerpt: "Invalid JSON"}

      assert Report.format_reason({:session_died, :specify, d}) ==
               "specify session failed to start: Invalid JSON"
    end

    test "task-phase ref, ended_early" do
      ref = %Autonomous.TaskPhaseRef{ordinal: 3, number: "3", title: "Title"}
      d = %{kind: :ended_early, excerpt: "cli gone"}

      assert Report.format_reason({:session_died, ref, d}) ==
               ~s(task-phase 3 "Title" session ended without a result: cli gone)
    end

    test "remediation attempt" do
      d = %{kind: :start_failed, excerpt: "x"}

      assert Report.format_reason({:session_died, {:remediation, 2}, d}) ==
               "remediation attempt 2 session failed to start: x"
    end

    test "never a raw term" do
      d = %{kind: :start_failed, excerpt: "x"}
      refute Report.format_reason({:session_died, :plan, d}) =~ "%{"
    end
  end

  describe "format_reason/1 (036 untrusted_workspace)" do
    @obs %{workspace: "/x/repo", kinds: ["permissions.allow", "permissions.additionalDirectories"]}

    test "phase atom with path and kinds" do
      assert Report.format_reason({:untrusted_workspace, :plan, @obs}) ==
               "untrusted_workspace in plan — CLI ignored permissions.allow, permissions.additionalDirectories " <>
                 "from the committed pack; workspace /x/repo is not trusted " <>
                 ~S|(projects["/x/repo"].hasTrustDialogAccepted). Trust it, then resume/2.|
    end

    test "empty kinds render (unknown); nil workspace names the missing cwd" do
      out = Report.format_reason({:untrusted_workspace, :plan, %{workspace: nil, kinds: []}})
      assert out =~ "CLI ignored (unknown) from the committed pack; session had no working directory."
    end

    test "chunk ref and remediation attempt" do
      ref = %Autonomous.TaskPhaseRef{ordinal: 3, number: "3", title: "Title"}
      assert Report.format_reason({:untrusted_workspace, ref, @obs}) =~ ~s(in task-phase 3 "Title" —)
      assert Report.format_reason({:untrusted_workspace, {:remediation, 2}, @obs}) =~ "in remediation attempt 2 —"
    end
  end
end
