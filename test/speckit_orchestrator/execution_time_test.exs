defmodule SpeckitOrchestrator.ExecutionTimeTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.ExecutionTime

  defp w(key, from, to), do: %{key: key, from: from, to: to}

  describe "elapsed_ms/2 — union over windows" do
    test "empty list is nil" do
      assert ExecutionTime.elapsed_ms([], 1_000) == nil
    end

    test "disjoint windows sum" do
      windows = [w(:a, 0, 100), w(:b, 200, 250)]
      assert ExecutionTime.elapsed_ms(windows, 1_000) == 150
    end

    test "a window nested in another adds nothing (SC-006)" do
      windows = [w(:outer, 0, 1_000), w(:inner, 100, 200)]
      assert ExecutionTime.elapsed_ms(windows, 10_000) == 1_000
    end

    test "a partial overlap is counted once" do
      windows = [w(:a, 0, 100), w(:b, 50, 150)]
      assert ExecutionTime.elapsed_ms(windows, 1_000) == 150
    end

    test "windows that merely touch form one span" do
      windows = [w(:a, 0, 100), w(:b, 100, 200)]
      assert ExecutionTime.elapsed_ms(windows, 1_000) == 200
    end

    test "an open window is closed at max(now, from), never negative" do
      windows = [w(:a, 500, nil)]
      assert ExecutionTime.elapsed_ms(windows, 100) == 0
      assert ExecutionTime.elapsed_ms(windows, 500) == 0
      assert ExecutionTime.elapsed_ms(windows, 600) == 100
    end

    test "a DateTime now is converted to unix millis" do
      windows = [w(:a, 0, nil)]
      now = DateTime.from_unix!(1, :second)
      assert ExecutionTime.elapsed_ms(windows, now) == 1_000
    end

    test "monotone in now: an open window never shrinks as now advances" do
      windows = [w(:a, 0, nil), w(:b, 2_000, 2_500)]
      e1 = ExecutionTime.elapsed_ms(windows, 1_000)
      e2 = ExecutionTime.elapsed_ms(windows, 3_000)
      assert e2 >= e1
    end

    test "no open window: elapsed is unaffected by now" do
      windows = [w(:a, 0, 100)]
      assert ExecutionTime.elapsed_ms(windows, 1_000) == ExecutionTime.elapsed_ms(windows, 5_000)
    end

    test "closing at the duration a span reported equals the value shown live at that instant" do
      opened = ExecutionTime.open([], :phase, 0)
      live_value = ExecutionTime.elapsed_ms(opened, 300)

      closed = ExecutionTime.close(opened, :phase, 300)
      closed_value = ExecutionTime.elapsed_ms(closed, 300)

      assert closed_value == live_value
    end
  end

  describe "open/3, close/3, close_all/2" do
    test "open/3 replaces any existing open window under the same key" do
      windows = ExecutionTime.open([], :phase, 0)
      windows = ExecutionTime.open(windows, :phase, 50)

      assert [%{key: :phase, from: 50, to: nil}] = windows
    end

    test "close/3 sets to = max(to, from) on the open window with the same key" do
      windows = ExecutionTime.open([], :phase, 100)
      windows = ExecutionTime.close(windows, :phase, 300)

      assert [%{key: :phase, from: 100, to: 300}] = windows
    end

    test "close/3 clamps to at least from (never negative length)" do
      windows = ExecutionTime.open([], :phase, 100)
      windows = ExecutionTime.close(windows, :phase, 50)

      assert [%{key: :phase, from: 100, to: 100}] = windows
    end

    test "close/3 with no matching open window leaves the list unchanged" do
      windows = [w(:other, 0, 100)]
      assert ExecutionTime.close(windows, :phase, 300) == windows
    end

    test "close_all/2 closes every open window at the same instant" do
      windows =
        []
        |> ExecutionTime.open(:a, 0)
        |> ExecutionTime.open(:b, 100)

      closed = ExecutionTime.close_all(windows, 500)

      assert Enum.all?(closed, &(&1.to == 500))
    end

    test "close_all/2 leaves already-closed windows untouched" do
      windows = [w(:a, 0, 100)]
      assert ExecutionTime.close_all(windows, 500) == ExecutionTime.normalize(windows)
    end
  end

  describe "normalize/1" do
    test "deduplicates by {key, from}: a closed window beats an open one" do
      windows = [w(:phase, 0, nil), w(:phase, 0, 100)]
      assert ExecutionTime.normalize(windows) == [w(:phase, 0, 100)]
    end

    test "among closed collisions, the larger to wins" do
      windows = [w(:phase, 0, 100), w(:phase, 0, 300)]
      assert ExecutionTime.normalize(windows) == [w(:phase, 0, 300)]
    end

    test "is idempotent" do
      windows = [w(:b, 100, 200), w(:a, 0, nil), w(:a, 0, 50)]
      once = ExecutionTime.normalize(windows)
      twice = ExecutionTime.normalize(once)
      assert once == twice
    end

    test "sorts by {from, to} with nil to last among equals" do
      windows = [w(:a, 0, nil), w(:b, 0, 50)]
      assert ExecutionTime.normalize(windows) == [w(:b, 0, 50), w(:a, 0, nil)]
    end
  end

  describe "from_attempts/1" do
    @all_phases [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge]
    @extra_kinds [:remediation, :implement_chunk, :auto_remediation]

    defp dt(unix_ms), do: DateTime.from_unix!(unix_ms, :millisecond)

    test "one window per attempt with both started_at and ended_at, for every phase atom" do
      attempts =
        Enum.map(@all_phases ++ @extra_kinds, fn phase ->
          %{phase: phase, ordinal: 1, started_at: dt(0), ended_at: dt(100)}
        end)

      windows = ExecutionTime.from_attempts(attempts)

      assert length(windows) == length(@all_phases) + length(@extra_kinds)

      assert Enum.all?(windows, fn w -> w.from == 0 and w.to == 100 end)

      keys = MapSet.new(windows, & &1.key)

      for phase <- @all_phases ++ @extra_kinds do
        assert MapSet.member?(keys, {:attempt, phase, 1})
      end
    end

    test "an attempt missing started_at yields no window" do
      attempts = [%{phase: :specify, ordinal: 1, started_at: nil, ended_at: dt(100)}]
      assert ExecutionTime.from_attempts(attempts) == []
    end

    test "an attempt missing ended_at yields no window" do
      attempts = [%{phase: :specify, ordinal: 1, started_at: dt(0), ended_at: nil}]
      assert ExecutionTime.from_attempts(attempts) == []
    end

    test "an attempt with a non-DateTime timestamp yields no window and never raises" do
      attempts = [%{phase: :specify, ordinal: 1, started_at: "not-a-datetime", ended_at: dt(100)}]
      assert ExecutionTime.from_attempts(attempts) == []
    end

    test "an attempt with a reversed timestamp pair yields no window" do
      attempts = [%{phase: :specify, ordinal: 1, started_at: dt(100), ended_at: dt(0)}]
      assert ExecutionTime.from_attempts(attempts) == []
    end

    test "well-formed attempts still produce windows alongside malformed ones" do
      attempts = [
        %{phase: :specify, ordinal: 1, started_at: dt(0), ended_at: dt(100)},
        %{phase: :clarify, ordinal: 1, started_at: nil, ended_at: dt(100)},
        %{phase: :plan, ordinal: 1, started_at: dt(200), ended_at: dt(150)}
      ]

      windows = ExecutionTime.from_attempts(attempts)
      assert [%{key: {:attempt, :specify, 1}, from: 0, to: 100}] = windows
    end

    test "non-list input yields []" do
      assert ExecutionTime.from_attempts(nil) == []
      assert ExecutionTime.from_attempts(%{}) == []
    end

    test "output is normalized" do
      attempts = [
        %{phase: :specify, ordinal: 1, started_at: dt(100), ended_at: dt(200)},
        %{phase: :specify, ordinal: 2, started_at: dt(0), ended_at: dt(50)}
      ]

      assert ExecutionTime.from_attempts(attempts) ==
               [
                 %{key: {:attempt, :specify, 2}, from: 0, to: 50},
                 %{key: {:attempt, :specify, 1}, from: 100, to: 200}
               ]
    end
  end

  describe "SC-006 parity: roll-up over chunks / final analyze over superseded runs" do
    test "implement roll-up over its chunks measures the same with and without the inner attempts" do
      rollup = %{phase: :implement, ordinal: 1, started_at: dt(0), ended_at: dt(1_000)}

      chunks = [
        %{phase: :implement_chunk, ordinal: 1, started_at: dt(0), ended_at: dt(300)},
        %{phase: :implement_chunk, ordinal: 2, started_at: dt(300), ended_at: dt(600)},
        %{phase: :implement_chunk, ordinal: 3, started_at: dt(600), ended_at: dt(1_000)}
      ]

      without_chunks = ExecutionTime.elapsed_ms(ExecutionTime.from_attempts([rollup]), 2_000)
      with_chunks = ExecutionTime.elapsed_ms(ExecutionTime.from_attempts([rollup | chunks]), 2_000)

      assert without_chunks == 1_000
      assert with_chunks == 1_000
    end

    test "final analyze over its superseded runs and corrections measures the same with and without them" do
      final = %{phase: :analyze, ordinal: 3, started_at: dt(0), ended_at: dt(1_000)}

      superseded_and_corrections = [
        %{phase: :analyze, ordinal: 1, started_at: dt(0), ended_at: dt(200)},
        %{phase: :auto_remediation, ordinal: 1, started_at: dt(200), ended_at: dt(400)},
        %{phase: :analyze, ordinal: 2, started_at: dt(400), ended_at: dt(700)},
        %{phase: :auto_remediation, ordinal: 2, started_at: dt(700), ended_at: dt(900)}
      ]

      without_inner = ExecutionTime.elapsed_ms(ExecutionTime.from_attempts([final]), 2_000)

      with_inner =
        ExecutionTime.elapsed_ms(
          ExecutionTime.from_attempts([final | superseded_and_corrections]),
          2_000
        )

      assert without_inner == 1_000
      assert with_inner == 1_000
    end

    test "a superseded re-run of a whole phase after resume-from-earlier-phase counts in full (not contained)" do
      first_run = %{phase: :plan, ordinal: 1, started_at: dt(0), ended_at: dt(100)}
      resumed_run = %{phase: :plan, ordinal: 2, started_at: dt(5_000), ended_at: dt(5_200)}

      windows = ExecutionTime.from_attempts([first_run, resumed_run])
      assert ExecutionTime.elapsed_ms(windows, 10_000) == 300
    end
  end

  describe "native_to_ms/1" do
    test "converts native time units to milliseconds" do
      native = System.convert_time_unit(1_500, :millisecond, :native)
      assert ExecutionTime.native_to_ms(native) == 1_500
    end
  end
end
