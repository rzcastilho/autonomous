defmodule SpeckitOrchestrator.StackedRunTest do
  @moduledoc """
  019: every run is a stacked sequential run — there is no toggle, no cap.
  Renamed from `pr_workflow_test.exs` (T017): the toggle-off cases are gone
  because there is no other shape left to compare against; what remains is
  the stacked-always behaviour, unconditionally.
  """

  # async: false — the facade run uses a fixed Coordinator name.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Feature

  defp feat(id, slug),
    do: %Feature{id: id, number: String.to_integer(id), slug: slug, path: "#{id}.md"}

  defp ad_hoc_feat(id, slug, created_at),
    do: %Feature{
      id: id,
      number: String.to_integer(id),
      slug: slug,
      path: "#{id}.md",
      group: :ad_hoc,
      created_at: created_at
    }

  test "every run stacks each feature on the prior branch and opens one PR per :done" do
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

    features = [feat("001", "core"), feat("002", "vote"), feat("003", "results")]

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # Built strictly in ascending numeric order, each stacked on the previous
    # completed branch. 002 having base "feature/001-core" is only possible
    # if 001 finished first — this proves the sequential + stacked behavior.
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

  test "a resumed run stacks on the last :done feature's branch, not back on pr_base" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    publisher = fn feature, base ->
      send(me, {:pr, feature.id, base})
      {:ok, "https://example/pr/#{feature.id}"}
    end

    features = [feat("001", "core"), feat("002", "vote"), feat("003", "results")]

    # The shape a resume restores: 001 already built and published in an
    # earlier run, 002 the target, 003 untouched.
    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        statuses: %{"001" => :done, "002" => :pending, "003" => :pending},
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # 001 is already done, so it never rebuilds. 002 must target 001's branch —
    # a fresh `pr_base` seed would open its PR against "main", flattening the
    # stack and carrying 001's commits into it.
    assert_receive {:built, "002", "feature/001-core"}, 2_000
    assert_receive {:pr, "002", "feature/001-core"}, 2_000
    assert_receive {:built, "003", "feature/002-vote"}, 2_000
    assert_receive {:pr, "003", "feature/002-vote"}, 2_000

    refute_received {:built, "001", _}
    refute_received {:pr, "001", _}
  end

  test "a merged branch is skipped as a base — the next feature stacks on pr_base instead" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    publisher = fn feature, base ->
      send(me, {:pr, feature.id, base})
      {:ok, "https://example/pr/#{feature.id}"}
    end

    features = [feat("001", "core"), feat("002", "vote"), feat("003", "results")]

    # 001 is done AND its PR already landed in main. The stack the operator
    # expects is:
    #     main <- 001 (merged), main <- 002, 002 <- 003
    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        statuses: %{"001" => :done, "002" => :pending, "003" => :pending},
        executor: executor,
        publisher: publisher,
        merged?: fn branch -> branch == "feature/001-core" end,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # 002 skips the merged 001 and goes straight onto the trunk...
    assert_receive {:built, "002", "main"}, 2_000
    assert_receive {:pr, "002", "main"}, 2_000
    # ...but 003 still stacks on 002, which is open. The chain resumes; it does
    # not collapse to main for everything after a merge.
    assert_receive {:built, "003", "feature/002-vote"}, 2_000
    assert_receive {:pr, "003", "feature/002-vote"}, 2_000
  end

  test "a chain merged out of order still finds an open base rather than jumping to the trunk" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    features = [feat("001", "core"), feat("002", "vote"), feat("003", "results")]

    # 002 landed but 001 did not — degenerate, but the walk must not stop at
    # the newest link and give up on the whole chain.
    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        statuses: %{"001" => :done, "002" => :done, "003" => :pending},
        executor: executor,
        publisher: fn _f, _b -> {:ok, "u"} end,
        merged?: fn branch -> branch == "feature/002-vote" end,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "003", "feature/001-core"}, 2_000
  end

  test "a run with no restored statuses still seeds the stack at pr_base" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: [feat("001", "core")],
        executor: executor,
        publisher: fn _f, _b -> {:ok, "u"} end,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "001", "main"}, 2_000
  end

  test "an ad-hoc feature already :done never seeds the stack — it is not part of the chain" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    features = [feat("001", "core"), ad_hoc_feat("900", "hotfix", ~U[2026-01-01 00:00:00Z])]

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        statuses: %{"900" => :done, "001" => :pending},
        executor: executor,
        publisher: fn _f, _b -> {:ok, "u"} end,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # FR-028: an ad-hoc feature never advances the chain, so a :done one must
    # not become a backlog feature's base either.
    assert_receive {:built, "001", "main"}, 2_000
  end

  test "every run is strictly sequential (one feature at a time), even with an injected runner" do
    me = self()

    # Controllable runner: report each start; the test controls completion.
    runner = fn feature, notify -> send(me, {:started, feature.id, notify}) end

    features = [feat("001", "a"), feat("002", "b"), feat("003", "c")]

    {:ok, pid} = SpeckitOrchestrator.run(features: features, runner: runner, owner: me)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # Only 001 starts; 002 waits — there is no cap to raise, one-at-a-time is
    # structural (Release.next/3 rule 3), not a configured limit.
    assert_receive {:started, "001", n1}, 2_000
    refute_received {:started, "002", _}

    n1.("001", :done, nil)
    assert_receive {:started, "002", n2}, 2_000
    refute_received {:started, "003", _}

    n2.("002", :done, nil)
    assert_receive {:started, "003", _}, 2_000
  end

  test "an ad-hoc feature branches from Config.pr_base() and never advances the chain, even after it reaches :done (FR-028)" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    publisher = fn feature, base ->
      send(me, {:pr, feature.id, base})
      {:ok, "https://example/pr/#{feature.id}"}
    end

    # Two ad-hoc features in one run (a test-only seam list — run_spec/2 never
    # builds more than one). If completing the first ever advanced the stack
    # top, the second would branch from the first's branch instead of
    # Config.pr_base() — this is the only way to observe FR-028 from outside
    # StackTracker, since a real run_spec/2 ad-hoc run has exactly one feature
    # and the tracker never outlives its own run.
    features = [
      ad_hoc_feat("001", "first", ~U[2026-01-01 00:00:00Z]),
      ad_hoc_feat("002", "second", ~U[2026-01-02 00:00:00Z])
    ]

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "001", "main"}, 2_000
    assert_receive {:pr, "001", "main"}, 2_000
    # Still "main" — the first ad-hoc feature's :done never called set_top/2.
    assert_receive {:built, "002", "main"}, 2_000
    assert_receive {:pr, "002", "main"}, 2_000

    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["001", "002"]
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

  # ---- US3: a publish failure never breaks the chain (FR-018) ----------------

  test "a completed feature's PR publish failure still stacks the next feature on its local branch, and the failure is recorded via telemetry, not swallowed" do
    me = self()
    handler_id = {:publish_failed_test, self()}

    :telemetry.attach(
      handler_id,
      [:speckit, :publish, :failed],
      fn event, measurements, metadata, _config ->
        send(me, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    # 001's publish fails; 002's succeeds — proves the failure neither halts
    # nor blocks the chain.
    publisher = fn
      %Feature{id: "001"}, _base ->
        {:error, :push_rejected}

      feature, base ->
        send(me, {:pr, feature.id, base})
        {:ok, "https://example/pr/#{feature.id}"}
    end

    features = [feat("001", "core"), feat("002", "vote")]

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "001", "main"}, 2_000

    assert_receive {:telemetry, [:speckit, :publish, :failed], %{},
                    %{feature_id: "001", reason: :push_rejected}},
                   2_000

    # 002 still stacks on 001's local branch, despite 001's PR never opening.
    assert_receive {:built, "002", "feature/001-core"}, 2_000
    assert_receive {:pr, "002", "feature/001-core"}, 2_000

    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["001", "002"]
  end

  # T033 (quickstart Scenario 3): every remaining `pr_workflow`/`max_concurrency`
  # reference under lib/ and config/ lives inside the retired-option refusal
  # paths T018–T024 built — nothing reads them as a live setting anymore.
  test "no live pr_workflow/max_concurrency reference survives outside the refusal paths" do
    root = Path.expand("../..", __DIR__)

    {output, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(grep -rn "pr_workflow\\|max_concurrency" lib config | grep -v retired || true)
        ],
        cd: root
      )

    assert output == "",
           "found live pr_workflow/max_concurrency reference(s) outside the refusal paths:\n#{output}"
  end
end
