defmodule SpeckitOrchestrator.PersistenceFailureTest do
  # async: false — the shared store (StoreCase clears tables + Store.Health
  # per test) plus real-named Coordinator/Ledger, mirroring
  # coordinator_test.exs's breaker-tripped conventions for the persistence
  # breaker instead (018, contracts/persistence-failure.md § Test plan, SC-013).
  use SpeckitOrchestrator.StoreCase, async: false

  alias SpeckitOrchestrator.{Coordinator, Feature, FeatureRunner, RepoIdentity, RunContext}

  @coordinator SpeckitOrchestrator.Coordinator

  defp feat(id, number \\ nil),
    do: %Feature{id: id, number: number || String.to_integer(id), slug: "f#{id}", path: "#{id}.md"}

  defp controllable_runner(test_pid) do
    fn feature, notify -> send(test_pid, {:started, feature.id, notify}) end
  end

  defp await_started(id) do
    assert_receive {:started, ^id, notify}, 1_000
    notify
  end

  defp stop_coordinator do
    case Process.whereis(@coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  setup do
    stop_coordinator()

    on_exit(fn ->
      stop_coordinator()
      # `Store.Health` is a single named process shared by the whole test
      # run, not reset by `StoreCase`'s per-test setup after THIS file's
      # last test — every test here that calls `Health.record_failure/1`
      # must leave it clean, or every later `run/1` call anywhere in the
      # suite sees a poisoned `preflight_store_writable/0` and refuses.
      Health.clear()
    end)

    :ok
  end

  defp open_run(repo_id \\ "o:persistence-failure-test", feature_ids \\ ["001", "002"]) do
    features =
      Enum.map(feature_ids, fn id ->
        %{
          feature_id: id,
          slug: "f#{id}",
          path: "#{id}.md",
          number: String.to_integer(id),
          group: :backlog,
          created_at: nil
        }
      end)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: features,
        settings:
          RunContext.to_map(%RunContext{
            budget_usd: 100.0
          }),
        scope: :ad_hoc,
        layout: %{}
      })

    {repo_id, run_id}
  end

  # ---- Coordinator: releases nothing new once the store is unwritable -------

  test "a pre-failed store releases nothing (Coordinator sees Store.Health at init)" do
    run_key = open_run()
    Health.record_failure(:simulated)

    features = [feat("001"), feat("002")]

    {:ok, pid} =
      Coordinator.start_link(
        features: features,
        runner: controllable_runner(self()),
        owner: self(),
        run_key: run_key
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    refute_received {:started, _, _}
    assert_receive {:run_complete, report}, 1_000
    assert Enum.sort(report.not_started) == ["001", "002"]
    assert report.done == []
  end

  test "a store failure mid-run drains in-flight work then releases no more (0 mid-flight aborts)" do
    run_key = open_run()
    features = [feat("001"), feat("002")]

    {:ok, pid} =
      Coordinator.start_link(
        features: features,
        runner: controllable_runner(self()),
        owner: self(),
        run_key: run_key
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    n1 = await_started("001")
    # The store goes unwritable while "001" is in flight — the feature
    # finishes its current phase (simulated here as the whole feature, since
    # Coordinator's own drain point is between-feature; the finer
    # between-phase drain is FeatureRunner's own, exercised below) rather
    # than being killed mid-flight.
    Health.record_failure(:simulated_write_failure)
    n1.("001", :done, nil)

    refute_received {:started, "002", _}
    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001"]
    assert report.not_started == ["002"]
  end

  test "the store's own run record is closed and flagged incomplete on a persistence-failure drain" do
    run_key = open_run()
    features = [feat("001")]

    {:ok, pid} =
      Coordinator.start_link(
        features: features,
        runner: controllable_runner(self()),
        owner: self(),
        run_key: run_key
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    n1 = await_started("001")
    Health.record_failure(:simulated_write_failure)
    n1.("001", :done, nil)

    assert_receive {:run_complete, _report}, 1_000

    # `close_run/3` runs against the SAME failed Store.Health this drain
    # tripped, so its own write may itself fail — `flag_record_incomplete/2`
    # is best-effort by design (FR-010a's own doc): the run staying
    # `:in_flight` with a stale `updated_at` is itself the incompleteness
    # signal `resumable/1` reports, so assert on whichever one landed.
    {:ok, detail} = Store.run(run_key)
    assert detail.run.record_complete? == false or detail.run.state == :in_flight
  end

  # ---- FeatureRunner: drains between phases, never mid-phase -----------------

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_worktree do
    repo = Path.join(System.tmp_dir!(), "pf_repo_#{System.unique_integer([:positive])}")
    root = Path.join(System.tmp_dir!(), "pf_root_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])

    {:ok, wt} = SpeckitOrchestrator.Worktree.create(feat("001"), repo: repo, worktree_root: root)
    on_exit(fn -> File.rm_rf(repo) end)
    on_exit(fn -> File.rm_rf(root) end)
    wt
  end

  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(_prompt, _options) do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :assistant,
          data: %{session_id: "s", message: %{"content" => "Phase completed."}},
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s",
            result: "Phase completed.",
            is_error: false,
            total_cost_usd: 0.01
          },
          raw: %{}
        }
      ]
    end
  end

  @tag :integration
  test "a store failure between phases halts the feature after the phase that completed, not mid-phase" do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)
    end)

    run_key = open_run("o:persistence-failure-feature-runner", ["001"])
    wt = scaffolded_worktree()

    # Pre-failed before the loop starts: real Mnesia writes still succeed
    # underneath (only the `Store.Health` flag is flipped), so the drain
    # check — evaluated *after* each phase's own transaction, before the
    # next phase starts — is what actually stops the run, deterministically
    # after exactly one phase (`:specify`) rather than mid-phase.
    Health.record_failure(:simulated_write_failure)

    result = FeatureRunner.run(feat("001"), worktree: wt, notify: self(), run_key: run_key)

    assert result.status == :halted
    assert {:persistence_failed, :simulated_write_failure} = result.reason

    # The phase that ran before the halt is durably recorded — zero
    # mid-flight aborts, exactly the completed work survives, and no
    # second phase attempt exists (the run never reached :clarify).
    {:ok, detail} = Store.run(run_key)
    feature = Enum.find(detail.features, &(&1.feature_id == "001"))
    assert [attempt] = feature.phase_attempts
    assert attempt.phase == :specify
    assert attempt.outcome == :ok
  end

  # ---- resumable/1: reports gap_possible? for an incomplete record ----------

  test "resumable/1 reports gap_possible?: true for a run flagged incomplete" do
    run_key = open_run("o:persistence-failure-gap", ["001"])
    {repo_id, _run_id} = run_key

    :ok = Writer.flag_record_incomplete(run_key, :simulated_write_failure)

    assert {:ok, summary} = SpeckitOrchestrator.resumable(repo_id)
    assert summary.gap_possible? == true
  end

  test "resumable/1 reports gap_possible?: false for a normally-recorded run" do
    run_key = open_run("o:persistence-failure-no-gap", ["001"])
    {repo_id, _run_id} = run_key

    assert {:ok, summary} = SpeckitOrchestrator.resumable(repo_id)
    assert summary.gap_possible? == false
  end

  # ---- run/1: refuses to start on an unwritable store (FR-009) --------------

  test "run/1 refuses to start when the store is unwritable, before any spend" do
    repo = Path.join(System.tmp_dir!(), "pf_run_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["remote", "add", "origin", "https://example.com/pf-run.git"])
    on_exit(fn -> File.rm_rf(repo) end)

    prev_repo = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, repo)

    on_exit(fn ->
      if prev_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    Health.record_failure(:simulated_write_failure)

    assert {:error, {:preflight, problems}} =
             SpeckitOrchestrator.run(features: [feat("001")], runner: fn _f, _n -> :ok end)

    assert Enum.any?(problems, &match?({:store_unwritable, _}, &1))
    assert Store.current_run_key(RepoIdentity.partition(repo)) == nil
  end

  # ---- telemetry: [:speckit, :store, :write_failed] --------------------------

  test "[:speckit, :store, :write_failed] is emitted on an aborted Store.Writer transaction" do
    test_pid = self()
    handler_id = "pf-write-failed-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:speckit, :store, :write_failed],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:write_failed, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    run_key = open_run("o:persistence-failure-telemetry", ["001"])
    {repo_id, run_id} = run_key
    missing_feature_key = {repo_id, run_id, "does-not-exist"}

    # `record_feature_terminal/5` aborts the transaction with `{:absent, key}`
    # when the feature row doesn't exist — a real, reproducible write
    # failure, not a simulated flag.
    assert {:error, {:absent, ^missing_feature_key}} =
             Writer.record_feature_terminal(run_key, "does-not-exist", :done, :ok, [])

    assert_receive {:write_failed, %{}, %{reason: {:absent, ^missing_feature_key}}}, 1_000
    assert Health.failed?()
  end
end
