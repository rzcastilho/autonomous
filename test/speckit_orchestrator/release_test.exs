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

  test "releasable?/2 requires pending self and all prereqs done" do
    f = feat("002", ["001"])
    refute Release.releasable?(f, %{})
    assert Release.releasable?(f, %{"001" => :done})
    refute Release.releasable?(%{f | status: :running}, %{"001" => :done})
  end
end
