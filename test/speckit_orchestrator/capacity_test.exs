defmodule SpeckitOrchestrator.CapacityTest do
  # async: false — real-named Coordinator plus the shared store (StoreCase
  # clears tables per test).
  use SpeckitOrchestrator.StoreCase, async: false

  @moduledoc """
  Facade-level capacity refusal (018 Phase 6, T069,
  contracts/capacity-and-prune.md § What a refusal does and does not
  block). A capacity refusal blocks only `run/1`/`resume_run/1` — everything
  else (`run_history/1`, `run_detail/1`, `transcript/1`, `export_run/3`,
  `prune_preview/1`, `prune/1`) stays available (FR-031c, SC-015).
  """

  alias SpeckitOrchestrator.{Feature, RepoIdentity, RunContext}

  @coordinator SpeckitOrchestrator.Coordinator

  setup do
    dir =
      Path.join(System.tmp_dir!(), "speckit_capacity_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", "https://x/y.git"])

    put_repo(dir)
    with_capacity(1, 1)
    stop_coordinator()

    on_exit(fn ->
      stop_coordinator()
      File.rm_rf(dir)
    end)

    {:ok, repo: dir}
  end

  defp stop_coordinator do
    case Process.whereis(@coordinator) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  defp put_repo(dir) do
    prev = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:speckit_orchestrator, :repo, prev),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)
  end

  defp with_capacity(capacity_bytes, headroom_bytes) do
    prev_capacity = Application.get_env(:speckit_orchestrator, :store_capacity_bytes)
    prev_headroom = Application.get_env(:speckit_orchestrator, :store_headroom_bytes)

    Application.put_env(:speckit_orchestrator, :store_capacity_bytes, capacity_bytes)
    Application.put_env(:speckit_orchestrator, :store_headroom_bytes, headroom_bytes)

    on_exit(fn ->
      restore(:store_capacity_bytes, prev_capacity)
      restore(:store_headroom_bytes, prev_headroom)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:speckit_orchestrator, key)
  defp restore(key, value), do: Application.put_env(:speckit_orchestrator, key, value)

  defp open_pending_run(repo) do
    repo_id = RepoIdentity.partition(repo)

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{feature_id: "001", slug: "f", path: "specs/001", number: 1, group: :backlog, created_at: nil}
        ],
        settings: RunContext.to_map(%RunContext{}),
        scope: :ad_hoc,
        layout: %{}
      })

    {repo_id, run_id}
  end

  test "run/1 refuses under a capacity refusal, starting no work", %{repo: repo} do
    assert {:error, {:preflight, [{:store_capacity, capacity}]}} =
             SpeckitOrchestrator.run(
               features: [%Feature{id: "001", number: 1, slug: "f", path: "001.md"}]
             )

    assert capacity.status == :refusing
    assert Process.whereis(@coordinator) == nil
    assert {:ok, []} = SpeckitOrchestrator.run_history(repo: repo)
  end

  test "resume_run/1 refuses on the same basis as run/1", %{repo: repo} do
    open_pending_run(repo)

    assert {:error, {:preflight, [{:store_capacity, capacity}]}} =
             SpeckitOrchestrator.resume_run()

    assert capacity.status == :refusing
    assert Process.whereis(@coordinator) == nil
  end

  test "resume/2 refuses on the same basis as run/1", %{repo: repo} do
    {repo_id, run_id} = open_pending_run(repo)

    :ok =
      Writer.record_phase_attempt({repo_id, run_id}, %{
        attempt: %{
          feature_id: "001",
          phase: :specify,
          ordinal: 1,
          step: 1,
          label: "specify",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 1,
          outcome: :ok,
          model: "sonnet",
          cost_usd: 0.0,
          cost_kind: :estimate
        },
        checkpoint: %{phase: :plan, last_completed_phase: :specify, status: :pending}
      })

    assert {:error, {:preflight, [{:store_capacity, capacity}]}} =
             SpeckitOrchestrator.resume("001")

    assert capacity.status == :refusing
    assert Process.whereis(@coordinator) == nil
  end

  test "history, detail, transcript, export, and prune all stay available under a capacity refusal",
       %{repo: repo} do
    {repo_id, run_id} = open_pending_run(repo)
    run_key = {repo_id, run_id}

    :ok =
      Writer.record_phase_attempt(run_key, %{
        attempt: %{
          feature_id: "001",
          phase: :specify,
          ordinal: 1,
          step: 1,
          label: "specify",
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          duration_ms: 1,
          outcome: :ok,
          model: "sonnet",
          cost_usd: 0.0,
          cost_kind: :estimate
        },
        transcript: "specify output"
      })

    assert {:ok, capacity} = SpeckitOrchestrator.store_capacity()
    assert capacity.status == :refusing

    assert {:ok, [%{run_id: ^run_id}]} = SpeckitOrchestrator.run_history(repo: repo)
    assert {:ok, %{run: %{run_id: ^run_id}}} = SpeckitOrchestrator.run_detail(run_id, repo: repo)

    [feature] = elem(SpeckitOrchestrator.run_detail(run_id, repo: repo), 1).features
    [attempt] = feature.phase_attempts
    assert {:ok, %{body: "specify output"}} = SpeckitOrchestrator.transcript(attempt.attempt_id)

    out =
      Path.join(
        System.tmp_dir!(),
        "capacity_test_export_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(out) end)
    assert {:ok, ^out} = SpeckitOrchestrator.export_run(run_id, out, repo: repo)

    assert {:ok, %{removable: [], retained: _}} =
             SpeckitOrchestrator.prune_preview(repo: repo)

    assert {:ok, %{removed: [], bytes_reclaimed: 0}} =
             SpeckitOrchestrator.prune(repo: repo, confirm: true)
  end
end
