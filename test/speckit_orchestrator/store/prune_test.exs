defmodule SpeckitOrchestrator.Store.PruneTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Prune

  @old ~U[2026-01-01 00:00:00Z]
  @boundary ~U[2026-06-01 00:00:00Z]
  @recent ~U[2026-07-01 00:00:00Z]

  describe "plan/3" do
    test "an in-flight run is never removable, regardless of boundary" do
      runs = [%{run_id: "r000001", state: :in_flight, ended_at: nil, bytes: 500}]

      assert %{
               removable: [],
               retained: [%{run_id: "r000001", reason: :in_flight}],
               bytes_reclaimable: 0
             } =
               Prune.plan(runs, @boundary, [])
    end

    test "a resumable run (protected_run_ids) is never removable, even before the boundary" do
      runs = [%{run_id: "r000002", state: :completed, ended_at: @old, bytes: 500}]

      assert %{
               removable: [],
               retained: [%{run_id: "r000002", reason: :resumable}],
               bytes_reclaimable: 0
             } =
               Prune.plan(runs, @boundary, ["r000002"])
    end

    test "a completed run after the boundary is retained, not removed" do
      runs = [%{run_id: "r000003", state: :completed, ended_at: @recent, bytes: 500}]

      assert %{removable: [], retained: [%{run_id: "r000003", reason: :after_boundary}]} =
               Prune.plan(runs, @boundary, [])
    end

    test "a run with no ended_at (never closed) is retained as after_boundary, not removed" do
      runs = [%{run_id: "r000004", state: :completed, ended_at: nil, bytes: 500}]

      assert %{removable: [], retained: [%{run_id: "r000004", reason: :after_boundary}]} =
               Prune.plan(runs, @boundary, [])
    end

    test "a completed run at or before the boundary is removable, summing bytes_reclaimable" do
      runs = [
        %{run_id: "r000005", state: :completed, ended_at: @old, bytes: 500},
        %{run_id: "r000006", state: :completed, ended_at: @boundary, bytes: 300}
      ]

      assert %{
               removable: removable,
               retained: [],
               bytes_reclaimable: 800
             } = Prune.plan(runs, @boundary, [])

      assert Enum.map(removable, & &1.run_id) == ["r000005", "r000006"]
    end

    test "a protected run is reported retained with a reason, never silently skipped" do
      runs = [
        %{run_id: "r000007", state: :in_flight, ended_at: nil, bytes: 100},
        %{run_id: "r000008", state: :completed, ended_at: @old, bytes: 200}
      ]

      plan = Prune.plan(runs, @boundary, ["r000008"])

      assert length(plan.retained) == 2
      assert plan.removable == []
      assert plan.bytes_reclaimable == 0
    end

    test "mixed set: only the genuinely removable runs count toward bytes_reclaimable" do
      runs = [
        %{run_id: "in_flight", state: :in_flight, ended_at: nil, bytes: 999},
        %{run_id: "protected", state: :completed, ended_at: @old, bytes: 999},
        %{run_id: "too_recent", state: :completed, ended_at: @recent, bytes: 999},
        %{run_id: "removable_1", state: :completed, ended_at: @old, bytes: 100},
        %{run_id: "removable_2", state: :completed, ended_at: @old, bytes: 50}
      ]

      plan = Prune.plan(runs, @boundary, ["protected"])

      assert Enum.map(plan.removable, & &1.run_id) == ["removable_1", "removable_2"]
      assert plan.bytes_reclaimable == 150
      assert Enum.map(plan.retained, & &1.run_id) == ["in_flight", "protected", "too_recent"]
    end

    test "an empty run list plans nothing" do
      assert Prune.plan([], @boundary, []) == %{removable: [], retained: [], bytes_reclaimable: 0}
    end
  end
end
