defmodule SpeckitOrchestrator.StackedRunTest do
  @moduledoc """
  019: every run is a stacked sequential run — there is no toggle, no cap.
  Renamed from `pr_workflow_test.exs` (T017): the toggle-off cases are gone
  because there is no other shape left to compare against; what remains is
  the stacked-always behaviour, unconditionally.
  """

  # async: false — the facade run uses a fixed Coordinator name. StoreCase
  # (not plain ExUnit.Case) because 027's publish-stop and empty-branch
  # cases park a real store run that would otherwise block every later
  # test's `run/1` on the same repository (`{:error, {:parked_run, …}}`).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Config, Feature, RepoIdentity, Store, Worktree}

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

  test "a resumed run stacks on an uncorroborated (:blocked) predecessor, not past it" do
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

    # 002 finished and published, but reconciliation could not corroborate it
    # (`Recovery.persisted_status/1` renders a `{:conflict, _}` as `:blocked`)
    # — e.g. its `Describe.run/3` failed, so the store holds a `pr_url` with
    # no `pr_description`. Its branch is still there and still unmerged, so it
    # is still the base 003 belongs on. Selecting the chain on `:done` skipped
    # it and handed 003 `feature/001-core`, whose squash then swallowed 002's
    # entire diff into 003's PR.
    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        statuses: %{"001" => :done, "002" => :blocked, "003" => :pending},
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "003", "feature/002-vote"}, 2_000
    assert_receive {:pr, "003", "feature/002-vote"}, 2_000

    refute_received {:built, "002", _}
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

  # ---- US1: a backlog publish failure stops the chain (027, FR-002/003/004) --

  test "a backlog feature's publish failure stops the chain: feature 2 never releases, the run parks, and stopped_by names the publish-failed reason" do
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

    # 001's publish fails with an arbitrary (non-normalized) seam term; 002
    # would succeed if it ever ran.
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
                    %{
                      feature_id: "001",
                      kind: :pr_failed,
                      reason: {:publish_failed, :pr_failed, _detail}
                    }},
                   2_000

    # The chain stopped at 001 — 002 never builds, never publishes.
    refute_received {:built, "002", _}
    refute_received {:pr, "002", _}

    assert_receive {:run_complete, report}, 2_000
    assert report.failed == ["001"]
    assert report.not_started == ["002"]

    assert %{feature_id: "001", status: :failed, reason: {:publish_failed, :pr_failed, detail}} =
             report.stopped_by

    assert detail.branch == "feature/001-core"
  end

  test "an ad-hoc feature's publish failure never stops the run — it stays :done (FR-007)" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    publisher = fn _feature, _base -> {:error, :push_rejected} end

    features = [ad_hoc_feat("900", "hotfix", ~U[2026-01-01 00:00:00Z])]

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "900", "main"}, 2_000
    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["900"]
    assert report.stopped_by == nil
  end

  test "an empty branch (no commits beyond base) fails the real publisher before any push, against a real temp repo" do
    repo = temp_repo!()
    on_exit(fn -> File.rm_rf!(repo) end)

    prior_repo = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, repo)

    on_exit(fn ->
      if prior_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prior_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    feature = feat("001", "core")
    branch = Worktree.locate(feature).branch

    # Branch points at the same commit as "main" — no commits beyond base,
    # so it is unpublishable as-is. No remote is configured on this temp
    # repo, so a push attempt would fail with a different (push_failed)
    # reason — `:empty_branch` proves the push step never ran.
    {_out, 0} = System.cmd("git", ["-C", repo, "branch", branch, "main"])

    me = self()

    executor = fn f, base, notify ->
      send(me, {:built, f.id, base})
      notify.(f.id, :done, nil)
      :ok
    end

    # No :publisher seam — exercises the real `publish_feature/3`.
    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: [feature],
        executor: executor,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "001", "main"}, 2_000
    assert_receive {:run_complete, report}, 2_000

    assert %{feature_id: "001", status: :failed, reason: {:publish_failed, :empty_branch, detail}} =
             report.stopped_by

    assert detail.branch == branch
    assert detail.branch_sha == detail.base_sha
  end

  test "stack_seed/1 seeds the chain by spec_id, not backlog number, when they differ" do
    me = self()

    executor = fn feature, base, notify ->
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    # A backlog feature whose spec_id (015) differs from its backlog number
    # (002) — the chain entry must name the branch the feature actually
    # built on (`feature/015-vote`), not `feature/002-vote`.
    seeded = %{feat("002", "vote") | spec_number: 15}
    features = [seeded, feat("003", "results")]

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: features,
        statuses: %{"002" => :done, "003" => :pending},
        executor: executor,
        publisher: fn _f, _b -> {:ok, "u"} end,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:built, "003", "feature/015-vote"}, 2_000
    refute_received {:built, "002", _}
  end

  # Regression (mod-player r000002): the executor allocates the spec number on
  # its own copy of the feature, so the publisher's closure still held
  # `spec_number: nil` and published/stacked `feature/004-…` — a branch that
  # never existed — instead of the `feature/017-…` it actually built on.
  test "a spec number allocated during the run names the published and stacked branch" do
    me = self()

    # Mirrors `default_executor/5`: allocation lands in the store only, never
    # on the struct the stacked runner closed over.
    executor = fn feature, base, notify ->
      run_key = Store.current_run_key(RepoIdentity.partition(Config.repo()))
      n = if feature.id == "001", do: 17, else: 18
      :ok = Store.record_spec_number(run_key, feature.id, n)
      send(me, {:built, feature.id, base})
      notify.(feature.id, :done, nil)
      :ok
    end

    publisher = fn feature, base ->
      send(me, {:pr, feature.id, Worktree.locate(feature).branch, base})
      {:ok, "https://example/pr/#{feature.id}"}
    end

    {:ok, pid} =
      SpeckitOrchestrator.run(
        features: [feat("001", "contrast"), feat("002", "motion")],
        executor: executor,
        publisher: publisher,
        owner: me
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert_receive {:pr, "001", "feature/017-contrast", "main"}, 2_000
    assert_receive {:built, "002", "feature/017-contrast"}, 2_000
    assert_receive {:pr, "002", "feature/018-motion", "feature/017-contrast"}, 2_000
    assert_receive {:run_complete, report}, 2_000
    assert report.done == ["001", "002"]
  end

  defp temp_repo! do
    path =
      Path.join(System.tmp_dir!(), "speckit-empty-branch-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    {_out, 0} = System.cmd("git", ["-C", path, "init", "-q", "-b", "main"])

    # `RepoIdentity.resolve/1` (Layout preflight) reads `origin` locally —
    # any parseable URL satisfies it without a reachable remote.
    {_out, 0} =
      System.cmd("git", ["-C", path, "remote", "add", "origin", "https://example/scratch.git"])

    {_out, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "--allow-empty",
        "-q",
        "-m",
        "root"
      ])

    path
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
