defmodule SpeckitOrchestrator.WaveHistoryTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.WaveHistory

  defp summary(attrs) do
    Map.merge(%{run_id: "000001", state: :completed, scope: {:breakdown, "alpha"}}, attrs)
  end

  describe "source_for/2" do
    test "an in-flight summary scoped to the slug matches live" do
      live = summary(%{run_id: "000002", state: :in_flight})
      assert WaveHistory.source_for("alpha", {:ok, [live]}) == {:live, live}
    end

    for state <- [:parked, :completed, :superseded] do
      test "a #{state} summary scoped to the slug matches recorded" do
        recorded = summary(%{state: unquote(state)})
        assert WaveHistory.source_for("alpha", {:ok, [recorded]}) == {:recorded, recorded}
      end
    end

    test "an :ad_hoc scope is skipped" do
      ad_hoc = summary(%{scope: :ad_hoc})
      assert WaveHistory.source_for("alpha", {:ok, [ad_hoc]}) == :none
    end

    test "a damaged summary is skipped" do
      damaged = %{run_id: "000003", damaged: true, reason: :corrupt}
      assert WaveHistory.source_for("alpha", {:ok, [damaged]}) == :none
    end

    test "two runs of the same wave — newest (first in list) wins when neither is in-flight" do
      newest = summary(%{run_id: "000005", state: :completed})
      older = summary(%{run_id: "000004", state: :parked})
      assert WaveHistory.source_for("alpha", {:ok, [newest, older]}) == {:recorded, newest}
    end

    test "two runs of the same wave — the in-flight one wins even if listed second" do
      recorded = summary(%{run_id: "000006", state: :completed})
      live = summary(%{run_id: "000005", state: :in_flight})
      assert WaveHistory.source_for("alpha", {:ok, [recorded, live]}) == {:live, live}
    end

    test "an {:error, reason} history is unavailable" do
      assert WaveHistory.source_for("alpha", {:error, :read_failed}) ==
               {:unavailable, :read_failed}
    end

    test "empty history matches nothing" do
      assert WaveHistory.source_for("alpha", {:ok, []}) == :none
    end

    test "a summary scoped to a different wave is skipped" do
      other = summary(%{scope: {:breakdown, "beta"}})
      assert WaveHistory.source_for("alpha", {:ok, [other]}) == :none
    end
  end

  describe "default_package/2" do
    test "packages == [] returns nil regardless of history" do
      assert WaveHistory.default_package([], {:ok, [summary(%{})]}) == nil
    end

    test "an in-flight summary scoped to a package wins" do
      live = summary(%{run_id: "000002", state: :in_flight, scope: {:breakdown, "beta"}})
      recorded = summary(%{run_id: "000003", state: :completed, scope: {:breakdown, "alpha"}})

      assert WaveHistory.default_package(["alpha", "beta"], {:ok, [recorded, live]}) == "beta"
    end

    test "the newest non-damaged summary scoped to a package wins when nothing is in-flight" do
      newest = summary(%{run_id: "000005", state: :completed, scope: {:breakdown, "beta"}})
      older = summary(%{run_id: "000004", state: :parked, scope: {:breakdown, "alpha"}})

      assert WaveHistory.default_package(["alpha", "beta"], {:ok, [newest, older]}) == "beta"
    end

    test "an ad-hoc-only history falls back to the first package" do
      ad_hoc = summary(%{scope: :ad_hoc})
      assert WaveHistory.default_package(["alpha", "beta"], {:ok, [ad_hoc]}) == "alpha"
    end

    test "a summary's slug not in packages is skipped" do
      other = summary(%{scope: {:breakdown, "gamma"}})
      assert WaveHistory.default_package(["alpha", "beta"], {:ok, [other]}) == "alpha"
    end

    test "a damaged summary is skipped, falling back to the first package" do
      damaged = %{run_id: "000006", damaged: true, reason: :corrupt}
      assert WaveHistory.default_package(["alpha", "beta"], {:ok, [damaged]}) == "alpha"
    end

    test "an {:error, _} history falls back to the first package" do
      assert WaveHistory.default_package(["alpha", "beta"], {:error, :read_failed}) == "alpha"
    end

    test "no runs falls back to the first package" do
      assert WaveHistory.default_package(["alpha", "beta"], {:ok, []}) == "alpha"
    end
  end

  describe "interrupt/2" do
    defp row(attrs) do
      Map.merge(%{status: :running, current_phase: :tasks, phases: %{}}, attrs)
    end

    test "a :running row from a non-in-flight run is drawn interrupted on the phase after its checkpoint" do
      result = WaveHistory.interrupt(row(%{}), :parked)

      assert result.status == :interrupted
      assert result.phases == %{analyze: %{state: :interrupted}}
    end

    test "a :running row with no checkpoint (current_phase: nil) is interrupted on the first phase" do
      result = WaveHistory.interrupt(row(%{current_phase: nil}), :completed)

      assert result.status == :interrupted
      assert result.phases == %{specify: %{state: :interrupted}}
    end

    test "a :running row already on the final phase changes status only, phases untouched" do
      result = WaveHistory.interrupt(row(%{current_phase: :converge, phases: %{converge: %{state: :completed}}}), :superseded)

      assert result.status == :interrupted
      assert result.phases == %{converge: %{state: :completed}}
    end

    test "a terminal-status row is unchanged regardless of run_state" do
      for status <- [:done, :escalated, :halted, :failed, :pending] do
        original = row(%{status: status})
        assert WaveHistory.interrupt(original, :parked) == original
      end
    end

    test "run_state: :in_flight never interrupts, even a :running row" do
      original = row(%{})
      assert WaveHistory.interrupt(original, :in_flight) == original
    end
  end

  describe "interrupt_all/2" do
    test "maps interrupt/2 over every row" do
      per_feature = %{
        "001" => row(%{}),
        "002" => row(%{status: :done})
      }

      result = WaveHistory.interrupt_all(per_feature, :parked)

      assert result["001"].status == :interrupted
      assert result["002"].status == :done
    end
  end
end
