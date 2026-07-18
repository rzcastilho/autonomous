defmodule SpeckitOrchestrator.PRWorkflowTest do
  # async: false — the facade run uses a fixed Coordinator name.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Feature

  defp feat(id, slug, prereqs \\ []),
    do: %Feature{id: id, slug: slug, path: "#{id}.md", prereqs: prereqs}

  test "pr_workflow stacks each feature on the prior branch and opens one PR per :done" do
    me = self()

    # Fake executor: record the base a feature was built on, then complete it.
    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    # Fake publisher: record (feature, base), succeed.
    publisher = fn feature, base ->
      send(me, {:pr, feature.id, base})
      {:ok, "https://example/pr/#{feature.id}"}
    end

    features = [
      feat("001", "core"),
      feat("002", "vote", ["001"]),
      feat("003", "results", ["002"])
    ]

    {:ok, pid} =
      SpeckitOrchestrator.run(
        pr_workflow: true,
        features: features,
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # Built strictly in order, each stacked on the previous completed branch.
    # 002 having base "feature/001-core" is only possible if 001 finished first —
    # this proves the sequential + stacked behavior.
    assert_receive {:built, "001", "main"}, 2_000
    assert_receive {:built, "002", "feature/001-core"}, 2_000
    assert_receive {:built, "003", "feature/002-vote"}, 2_000

    # Exactly one PR per feature, against the base it was built on.
    assert_receive {:pr, "001", "main"}, 2_000
    assert_receive {:pr, "002", "feature/001-core"}, 2_000
    assert_receive {:pr, "003", "feature/002-vote"}, 2_000

    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["001", "002", "003"]
  end

  test "pr_workflow forces sequential execution (cap 1) even with an injected runner" do
    me = self()

    # Controllable runner: report each start; the test controls completion.
    runner = fn feature, notify -> send(me, {:started, feature.id, notify}) end

    features = [feat("001", "a"), feat("002", "b"), feat("003", "c")]

    {:ok, pid} =
      SpeckitOrchestrator.run(pr_workflow: true, features: features, runner: runner, owner: me)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # Only 001 starts; 002 waits behind the cap of 1.
    assert_receive {:started, "001", n1}, 2_000
    refute_received {:started, "002", _}

    n1.("001", :done, nil)
    assert_receive {:started, "002", n2}, 2_000
    refute_received {:started, "003", _}

    n2.("002", :done, nil)
    assert_receive {:started, "003", _}, 2_000
  end

  test "a second run replaces the previous Coordinator (no :already_started)" do
    me = self()
    runner = fn feature, notify -> send(me, {:started, feature.id, notify}) end
    feats = [feat("001", "a")]

    {:ok, pid1} = SpeckitOrchestrator.run(features: feats, runner: runner, owner: me)
    assert_receive {:started, "001", _}, 2_000

    # Re-run without the first having drained — must not collide on the fixed name.
    {:ok, pid2} = SpeckitOrchestrator.run(features: feats, runner: runner, owner: me)
    on_exit(fn -> if Process.alive?(pid2), do: GenServer.stop(pid2) end)

    assert pid2 != pid1
    refute Process.alive?(pid1)
  end
end
