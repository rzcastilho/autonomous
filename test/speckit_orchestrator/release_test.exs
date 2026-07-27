defmodule SpeckitOrchestrator.ReleaseTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Feature, Release}

  defp feat(id, prereqs \\ []) do
    %Feature{id: id, slug: "f#{id}", path: "#{id}.md", prereqs: prereqs}
  end

  # Diamond: 1 -> {2, 3} -> 4
  defp diamond do
    [feat("001"), feat("002", ["001"]), feat("003", ["001"]), feat("004", ["002", "003"])]
  end

  defp ids(features), do: Enum.map(features, & &1.id)

  test "solo first wave: only the prereq-free feature is releasable" do
    assert ids(Release.next_wave(diamond(), %{}, 4, false)) == ["001"]
  end

  test "wave releases dependents after the prereq completes" do
    statuses = %{"001" => :done}
    assert ids(Release.next_wave(diamond(), statuses, 4, false)) == ["002", "003"]
  end

  test "diamond join releases only after BOTH prereqs are done" do
    only_two = %{"001" => :done, "002" => :done, "003" => :running}
    assert ids(Release.next_wave(diamond(), only_two, 4, false)) == []

    both = %{"001" => :done, "002" => :done, "003" => :done}
    assert ids(Release.next_wave(diamond(), both, 4, false)) == ["004"]
  end

  test "concurrency cap limits the wave, ties by ascending id" do
    features = [feat("001"), feat("002"), feat("003")]
    assert ids(Release.next_wave(features, %{}, 2, false)) == ["001", "002"]
  end

  test "in-flight :running features consume slots" do
    features = [feat("001"), feat("002"), feat("003")]
    statuses = %{"001" => :running}
    # cap 2, one running -> 1 slot -> next pending by id
    assert ids(Release.next_wave(features, statuses, 2, false)) == ["002"]
  end

  test "tripped breaker releases nothing" do
    assert Release.next_wave(diamond(), %{"001" => :done}, 4, true) == []
  end

  test "dependent of an escalated/failed prereq is not released and is blocked?" do
    features = [feat("001"), feat("002", ["001"])]

    for bad <- [:escalated, :failed, :halted] do
      statuses = %{"001" => bad}
      assert Release.next_wave(features, statuses, 4, false) == []
      assert Release.blocked?(Enum.at(features, 1), statuses)
    end
  end

  describe "sequential_order/1" do
    test "a diamond linearizes to a topological order, ties broken by ascending id" do
      assert Release.sequential_order(diamond()) == ["001", "002", "003", "004"]
    end

    test "a chain keeps its chain order regardless of the list's own order" do
      chain = [feat("003", ["002"]), feat("001"), feat("002", ["001"])]
      assert Release.sequential_order(chain) == ["001", "002", "003"]
    end

    test "fully independent features order by ascending id" do
      assert Release.sequential_order([feat("003"), feat("001"), feat("002")]) ==
               ["001", "002", "003"]
    end

    # Guards against the order silently degrading to a plain id sort: here the
    # dependency inverts id order, so only a real topological walk gets it right.
    test "dependency order beats id order when the two disagree" do
      assert Release.sequential_order([feat("001", ["002"]), feat("002")]) == ["002", "001"]
    end

    test "omits a feature that can never be released, and still terminates" do
      # 003's prereq is not in the backlog at all, so it is never releasable.
      # (Backlog.load!/1 rejects this shape; the guard is here so a partial or
      # hand-built feature list can never spin the walk forever.)
      features = [feat("001"), feat("003", ["999"])]
      assert Release.sequential_order(features) == ["001"]
    end

    test "empty backlog yields an empty order" do
      assert Release.sequential_order([]) == []
    end

    # The projection's whole claim is that it reproduces the real policy, so
    # assert exactly that: replaying next_wave/4 at cap 1 must visit the same
    # ids in the same order.
    test "matches what next_wave/4 at cap 1 actually releases, step for step" do
      features = diamond()

      replayed =
        Enum.reduce(1..4, {%{}, []}, fn _step, {statuses, acc} ->
          [f] = Release.next_wave(features, statuses, 1, false)
          {Map.put(statuses, f.id, :done), acc ++ [f.id]}
        end)
        |> elem(1)

      assert Release.sequential_order(features) == replayed
    end
  end

  test "releasable?/2 requires pending self and all prereqs done" do
    f = feat("002", ["001"])
    refute Release.releasable?(f, %{})
    assert Release.releasable?(f, %{"001" => :done})
    refute Release.releasable?(%{f | status: :running}, %{"001" => :done})
  end
end
