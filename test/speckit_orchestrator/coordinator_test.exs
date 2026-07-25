defmodule SpeckitOrchestrator.CoordinatorTest do
  # async: false — the set_cap/2 tests mutate global Config app env (mirrored
  # by Coordinator.set_cap/2), same convention as run_context_test.exs.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Config, Coordinator, Feature, Ledger, RepoIdentity}

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "f#{id}", path: "#{id}.md", prereqs: prereqs}

  # A runner that reports each started feature (with its notify fn) to the test,
  # so the test controls when and how each feature finishes.
  defp controllable_runner(test_pid) do
    fn feature, notify -> send(test_pid, {:started, feature.id, notify}) end
  end

  defp start(features, opts) do
    {:ok, pid} =
      Coordinator.start_link(
        [features: features, runner: controllable_runner(self()), owner: self()] ++ opts
      )

    on_exit(fn -> safe_stop(pid) end)
    pid
  end

  # Now that Coordinator traps exits (FR-027), it self-terminates the instant
  # its starting (`start_link/1`-calling) test process dies — a `:gen_server`
  # parent-exit convention that fires independently of any `on_exit`
  # callback. That races this on_exit's own best-effort `GenServer.stop/1}`:
  # `Process.alive?/1` can see `true` a moment before the process' own
  # self-triggered shutdown completes, so `GenServer.stop/1` can still land on
  # an already-dying process and raise. Harmless either way — the process is
  # gone or is about to be — so swallow it.
  defp safe_stop(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  defp await_started(id) do
    assert_receive {:started, ^id, notify}, 1_000
    notify
  end

  test "diamond DAG releases wave by wave and completes" do
    features = [
      feat("001"),
      feat("002", ["001"]),
      feat("003", ["001"]),
      feat("004", ["002", "003"])
    ]

    start(features, max_concurrency: 4)

    n1 = await_started("001")
    refute_received {:started, "002", _}
    n1.("001", :done, nil)

    n2 = await_started("002")
    n3 = await_started("003")
    n2.("002", :done, nil)
    n3.("003", :done, nil)

    n4 = await_started("004")
    n4.("004", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002", "003", "004"]
  end

  test "concurrency cap limits in-flight features" do
    features = [feat("001"), feat("002"), feat("003")]
    start(features, max_concurrency: 2)

    _n1 = await_started("001")
    n2 = await_started("002")
    # third must wait behind the cap
    refute_received {:started, "003", _}

    n2.("002", :done, nil)
    _n3 = await_started("003")
  end

  test "a dependent of an escalated prereq is reported blocked" do
    features = [feat("001"), feat("002", ["001"])]
    start(features, max_concurrency: 2)

    n1 = await_started("001")
    n1.("001", :escalated, :needs_human)

    refute_received {:started, "002", _}
    assert_receive {:run_complete, report}, 1_000
    assert report.escalated == ["001"]
    assert report.blocked == ["002"]
  end

  test "a tripped breaker releases nothing (pre-tripped ledger)" do
    ledger = start_ledger(0.0)
    features = [feat("001"), feat("002", ["001"])]
    start(features, max_concurrency: 2, ledger: ledger)

    refute_received {:started, _, _}
    assert_receive {:run_complete, report}, 1_000
    assert report.breaker_tripped
    assert Enum.sort(report.not_started) == ["001", "002"]
    assert report.done == []
  end

  test "breaker tripping mid-run drains in-flight then releases no more" do
    ledger = start_ledger(100.0)
    features = [feat("001"), feat("002", ["001"])]
    start(features, max_concurrency: 2, ledger: ledger)

    n1 = await_started("001")
    # trip the breaker while 001 is in flight
    Ledger.record(ledger, nil, 150.0)
    n1.("001", :done, nil)

    refute_received {:started, "002", _}
    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001"]
    assert report.not_started == ["002"]
    assert report.breaker_tripped
  end

  test "empty backlog finishes immediately" do
    start([], max_concurrency: 2)
    assert_receive {:run_complete, report}, 1_000
    assert report.done == []
  end

  # set_cap/2 mirrors to app env (a global, not per-process, side effect) —
  # every test that calls it must restore the prior value on exit so it
  # cannot bleed into other test files (e.g. config_test.exs).
  defp with_restored_max_concurrency(test) do
    prior = Application.get_env(:speckit_orchestrator, :max_concurrency)
    on_exit(fn -> Application.put_env(:speckit_orchestrator, :max_concurrency, prior) end)
    test.()
  end

  test "set_cap/2 raises the wave cap so a previously-waiting feature releases on the next advance" do
    with_restored_max_concurrency(fn ->
      features = [feat("001"), feat("002"), feat("003")]
      pid = start(features, max_concurrency: 2)

      _n1 = await_started("001")
      n2 = await_started("002")
      refute_received {:started, "003", _}

      assert Coordinator.set_cap(pid, 3) == :ok
      # cap alone doesn't spawn work; the next advance (triggered by a finish) sees it.
      refute_received {:started, "003", _}

      n2.("002", :done, nil)
      _n3 = await_started("003")
    end)
  end

  test "set_cap/2 mirrors the new cap to app env" do
    with_restored_max_concurrency(fn ->
      features = [feat("001")]
      pid = start(features, max_concurrency: 2)
      _n1 = await_started("001")

      assert Coordinator.set_cap(pid, 5) == :ok
      assert Application.get_env(:speckit_orchestrator, :max_concurrency) == 5
    end)
  end

  # ---- :statuses init option (crash recovery, T020) ------------------------

  test "a supplied :statuses init option seeds state.statuses instead of the all-:pending default — a :done feature is never released even when its prereqs are also :done" do
    features = [feat("001"), feat("002", ["001"])]

    start(features,
      max_concurrency: 2,
      statuses: %{"001" => :done, "002" => :done}
    )

    refute_received {:started, _, _}
    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002"]
  end

  test "a feature seeded :pending in :statuses releases normally through Release.next_wave/4" do
    features = [feat("001"), feat("002", ["001"])]

    start(features,
      max_concurrency: 2,
      statuses: %{"001" => :done, "002" => :pending}
    )

    n2 = await_started("002")
    n2.("002", :done, nil)

    assert_receive {:run_complete, report}, 1_000
    assert report.done == ["001", "002"]
  end

  # ---- :manifest seam (crash recovery, T021) --------------------------------

  defmodule FakeManifest do
    use Agent

    def start_link(test_pid), do: Agent.start_link(fn -> test_pid end, name: __MODULE__)

    # Best-effort, mirroring RunManifest.write/1's own contract — a
    # terminate/2-triggered write racing this fake's own teardown (both react
    # to the same test-process death independently) must not crash a
    # Coordinator that's already mid-shutdown.
    def write(payload) do
      __MODULE__ |> Agent.get(& &1) |> send({:manifest_write, payload})
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp start_fake_manifest(test_pid) do
    {:ok, pid} = FakeManifest.start_link(test_pid)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
  end

  test "a fake injected via :manifest receives write/1 on init, each spawn_feature, and each finish" do
    start_fake_manifest(self())
    features = [feat("001")]
    start(features, max_concurrency: 2, manifest: FakeManifest)

    assert_receive {:manifest_write, init_payload}, 1_000
    assert init_payload.statuses == %{"001" => :pending}

    assert_receive {:manifest_write, spawn_payload}, 1_000
    assert spawn_payload.statuses == %{"001" => :running}

    n1 = await_started("001")
    n1.("001", :done, nil)

    assert_receive {:manifest_write, finish_payload}, 1_000
    assert finish_payload.statuses == %{"001" => :done}
  end

  test "the default manifest seam (when :manifest is omitted) is RunManifest" do
    # RunManifest.write/1 resolves run.json under Config.autonomous_root (012),
    # partitioned by this repo's identity segment (no layout here → segment
    # resolved from Config.repo()) — not :transcript_root.
    root = Path.join(System.tmp_dir!(), "coord_rm_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:speckit_orchestrator, :autonomous_root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:speckit_orchestrator, :autonomous_root, prev)
    end)

    features = [feat("001")]
    start(features, max_concurrency: 2)
    n1 = await_started("001")
    n1.("001", :done, nil)

    assert_receive {:run_complete, _report}, 1_000
    assert File.exists?(manifest_path(root))
  end

  # Mirrors RunManifest's segment resolution (Config.repo() → origin segment,
  # nil → flat bucket) so this assertion targets the same slot the module wrote.
  defp manifest_path(root) do
    case RepoIdentity.resolve(Config.repo()) do
      {:ok, segment} -> Path.join([root, "transcripts", segment, "run.json"])
      {:error, _} -> Path.join([root, "transcripts", "run.json"])
    end
  end

  # ---- terminate/2 shutdown flush (FR-027, T029) ----------------------------

  # Coordinator writes the manifest on init, on every spawn, and on every
  # finish — plus, now, once more on terminate/2. Collecting every write
  # (rather than draining then asserting "the next one") sidesteps any
  # ordering race between a cast being processed and our own draining, and
  # lets every assertion target the true final snapshot: the last write.
  defp collect_manifest_writes do
    receive do
      {:manifest_write, payload} -> [payload | collect_manifest_writes()]
    after
      200 -> []
    end
  end

  defp start_ledger(budget) do
    {:ok, ledger} = Ledger.start_link(budget: budget, name: nil)
    on_exit(fn -> safe_stop(ledger) end)
    ledger
  end

  test "a normal drain (all features already terminal) flushes the manifest unchanged on terminate/2" do
    start_fake_manifest(self())
    features = [feat("001")]
    pid = start(features, max_concurrency: 2, manifest: FakeManifest)

    n1 = await_started("001")
    n1.("001", :done, nil)
    assert_receive {:run_complete, _report}, 1_000

    GenServer.stop(pid)

    last = collect_manifest_writes() |> List.last()
    assert last.statuses == %{"001" => :done}
  end

  test "a forced shutdown mid-phase records the in-flight feature :interrupted, leaving its Ledger reservation intact" do
    ledger = start_ledger(100.0)
    start_fake_manifest(self())
    features = [feat("001"), feat("002")]
    pid = start(features, max_concurrency: 2, manifest: FakeManifest, ledger: ledger)

    await_started("001")
    n2 = await_started("002")
    n2.("002", :done, nil)

    {:ok, _ref} = Ledger.reserve(ledger, 10.0)

    GenServer.stop(pid)

    last = collect_manifest_writes() |> List.last()
    assert last.statuses["001"] == :interrupted
    assert last.statuses["002"] == :done

    # the reservation is untouched — Coordinator's flush never cancels/commits it
    assert Ledger.snapshot(ledger).reserved == 10.0
  end

  test "terminate/2 flush never reports committed spend higher than Ledger's own committed total" do
    ledger = start_ledger(100.0)
    start_fake_manifest(self())
    features = [feat("001")]
    pid = start(features, max_concurrency: 2, manifest: FakeManifest, ledger: ledger)

    await_started("001")
    {:ok, ref} = Ledger.reserve(ledger, 10.0)
    Ledger.record(ledger, ref, 7.0)

    GenServer.stop(pid)

    last = collect_manifest_writes() |> List.last()
    assert last.spend == 7.0
    assert last.statuses["001"] == :interrupted
  end
end
