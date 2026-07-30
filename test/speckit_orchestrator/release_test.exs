defmodule SpeckitOrchestrator.ReleaseTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Backlog, Feature, Release}

  defp feat(id, number, opts \\ []) do
    %Feature{
      id: id,
      number: number,
      slug: "f#{id}",
      path: "#{id}.md",
      group: Keyword.get(opts, :group, :backlog),
      created_at: Keyword.get(opts, :created_at),
      status: Keyword.get(opts, :status, :pending)
    }
  end

  defp ids(features), do: Enum.map(features, & &1.id)

  describe "order/1" do
    test "ascending by number over a gapped backlog" do
      gapped = [feat("020", 20), feat("001", 1), feat("005", 5)]
      assert ids(Release.order(gapped)) == ["001", "005", "020"]
    end

    test "independent of input list order" do
      a = [feat("001", 1), feat("005", 5), feat("020", 20)]
      b = [feat("020", 20), feat("001", 1), feat("005", 5)]
      c = [feat("005", 5), feat("020", 20), feat("001", 1)]

      assert Release.order(a) == Release.order(b)
      assert Release.order(b) == Release.order(c)
    end

    test "backlog features precede ad-hoc features regardless of numbering" do
      backlog = feat("003", 3)
      ad_hoc = feat("adhoc-1", 1, group: :ad_hoc, created_at: ~U[2026-01-01 00:00:00Z])

      assert ids(Release.order([ad_hoc, backlog])) == ["003", "adhoc-1"]
    end

    test "ad-hoc features order by created_at, tie-broken by number" do
      later = feat("a", 2, group: :ad_hoc, created_at: ~U[2026-01-02 00:00:00Z])
      earlier = feat("b", 1, group: :ad_hoc, created_at: ~U[2026-01-01 00:00:00Z])
      tie_high = feat("c", 5, group: :ad_hoc, created_at: ~U[2026-01-01 00:00:00Z])
      tie_low = feat("d", 3, group: :ad_hoc, created_at: ~U[2026-01-01 00:00:00Z])

      assert ids(Release.order([later, earlier, tie_high, tie_low])) == ["b", "d", "c", "a"]
    end

    test "a fixture's prose ## Prerequisites section has no effect on order (FR-010)" do
      dir = Path.expand("../fixtures/breakdown", __DIR__)
      features = Backlog.load!(dir)

      # The fixture's Prerequisites sections describe a dependency DAG where
      # 003/004/006 depend on 002, etc. — none of that is read by Release;
      # order/1 must still be a flat ascending walk over `number`.
      assert ids(Release.order(features)) == ~w(001 002 003 004 005 006 007)
    end
  end

  describe "next/3" do
    test "solo lowest-ordered pending feature is released, over a gapped backlog" do
      gapped = [feat("020", 20), feat("001", 1), feat("005", 5)]
      assert {:release, %Feature{id: "001"}} = Release.next(gapped, %{}, false)
    end

    test "never two in flight: any :running feature yields :none regardless of others' status" do
      features = [feat("001", 1), feat("002", 2), feat("003", 3)]
      statuses = %{"001" => :running}

      assert Release.next(features, statuses, false) == :none
    end

    test "stop on :escalated: later features stay pending and are never returned" do
      features = [feat("001", 1), feat("002", 2), feat("003", 3)]
      statuses = %{"001" => :done, "002" => :escalated}

      assert Release.next(features, statuses, false) == {:stopped, "002", :escalated}
    end

    test "stop on :halted: later features stay pending and are never returned" do
      features = [feat("001", 1), feat("002", 2), feat("003", 3)]
      statuses = %{"001" => :done, "002" => :halted}

      assert Release.next(features, statuses, false) == {:stopped, "002", :halted}
    end

    test "stop on :failed: later features stay pending and are never returned" do
      features = [feat("001", 1), feat("002", 2), feat("003", 3)]
      statuses = %{"001" => :done, "002" => :failed}

      assert Release.next(features, statuses, false) == {:stopped, "002", :failed}
    end

    test "when more than one non-done terminal exists, the lowest-ordered is reported" do
      features = [feat("001", 1), feat("002", 2), feat("003", 3)]
      statuses = %{"001" => :halted, "002" => :failed}

      assert Release.next(features, statuses, false) == {:stopped, "001", :halted}
    end

    test "breaker tripped yields :none even with a releasable feature" do
      features = [feat("001", 1)]
      assert Release.next(features, %{}, true) == :none
    end

    test "breaker tripped outranks a stopped feature: still :none (drain, don't kill)" do
      features = [feat("001", 1), feat("002", 2)]
      statuses = %{"001" => :halted}

      assert Release.next(features, statuses, true) == :none
    end

    test "nothing pending and nothing running or stopped: :none (run complete)" do
      features = [feat("001", 1)]
      assert Release.next(features, %{"001" => :done}, false) == :none
    end

    test "releases across the ad-hoc group only after the backlog is exhausted" do
      backlog_done = feat("001", 1, status: :done)
      ad_hoc = feat("adhoc-1", 1, group: :ad_hoc, created_at: ~U[2026-01-01 00:00:00Z])

      assert {:release, %Feature{id: "adhoc-1"}} =
               Release.next([backlog_done, ad_hoc], %{"001" => :done}, false)
    end
  end
end
