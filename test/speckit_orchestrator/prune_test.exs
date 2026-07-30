defmodule SpeckitOrchestrator.PruneTest do
  use SpeckitOrchestrator.StoreCase, async: false

  @moduledoc """
  Facade-level `prune_preview/1` and `prune/1` (018 Phase 6, T070,
  contracts/capacity-and-prune.md § Prune). A resumable or in-flight run is
  never removed regardless of boundary; `prune_preview/1` performs nothing;
  nothing is ever removed without an explicit operator `prune/1, confirm:
  true` (SC-014).
  """

  alias SpeckitOrchestrator.{RepoIdentity, RunContext}

  setup do
    dir = Path.join(System.tmp_dir!(), "speckit_prune_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    on_exit(fn -> File.rm_rf(dir) end)

    prev = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :repo, dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:speckit_orchestrator, :repo, prev),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    {:ok, repo: dir, repo_id: RepoIdentity.partition(dir)}
  end

  defp open_run(repo_id, feature_id \\ "001") do
    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: [
          %{
            feature_id: feature_id,
            slug: "f",
            path: "specs/#{feature_id}",
            number: System.unique_integer([:positive, :monotonic]),
            group: :backlog,
            created_at: nil
          }
        ],
        settings: RunContext.to_map(%RunContext{}),
        scope: :ad_hoc,
        layout: %{}
      })

    {repo_id, run_id}
  end

  defp attempt(feature_id, transcript \\ "output") do
    now = DateTime.utc_now()

    %{
      attempt: %{
        feature_id: feature_id,
        phase: :specify,
        ordinal: 1,
        step: 1,
        label: "specify",
        started_at: now,
        ended_at: now,
        duration_ms: 1,
        outcome: :ok,
        model: "sonnet",
        cost_usd: 0.0,
        cost_kind: :estimate
      },
      transcript: transcript
    }
  end

  defp close(run_key, outcome \\ :all_done) do
    :ok = Writer.close_run(run_key, outcome)
  end

  test "prune_preview/1 reports the plan and removes nothing", %{repo: repo, repo_id: repo_id} do
    {^repo_id, run_id} = run_key = open_run(repo_id)
    :ok = Writer.record_phase_attempt(run_key, attempt("001"))
    :ok = Writer.record_feature_terminal(run_key, "001", :done, nil)
    close(run_key)

    assert {:ok, %{removable: [%{run_id: ^run_id}], bytes_reclaimable: bytes}} =
             SpeckitOrchestrator.prune_preview(repo: repo)

    assert bytes > 0
    assert {:ok, [%{run_id: ^run_id}]} = SpeckitOrchestrator.run_history(repo: repo)
  end

  test "a resumable run (an escalated feature) is never removed, regardless of boundary", %{
    repo: repo,
    repo_id: repo_id
  } do
    {^repo_id, run_id} = run_key = open_run(repo_id)

    :ok =
      Writer.record_escalation(run_key, %{
        feature_id: "001",
        kind: :escalated,
        phase: :analyze,
        reason: "critical finding",
        evidence: %{}
      })

    :ok = Writer.record_feature_terminal(run_key, "001", :escalated, "critical finding")
    close(run_key, :escalated)

    far_future = DateTime.add(DateTime.utc_now(), 3600 * 24 * 365, :second)

    assert {:ok, %{removable: [], retained: [%{run_id: ^run_id, reason: :resumable}]}} =
             SpeckitOrchestrator.prune_preview(repo: repo, before: far_future)

    assert {:ok, %{removed: [], bytes_reclaimed: 0}} =
             SpeckitOrchestrator.prune(repo: repo, before: far_future, confirm: true)

    assert {:ok, [%{run_id: ^run_id}]} = SpeckitOrchestrator.run_history(repo: repo)
  end

  test "an in-flight run is never removed, regardless of boundary", %{
    repo: repo,
    repo_id: repo_id
  } do
    {^repo_id, run_id} = open_run(repo_id)
    far_future = DateTime.add(DateTime.utc_now(), 3600 * 24 * 365, :second)

    assert {:ok, %{removable: [], retained: [%{run_id: ^run_id, reason: :in_flight}]}} =
             SpeckitOrchestrator.prune_preview(repo: repo, before: far_future)
  end

  test "prune/1 without confirm: true refuses and removes nothing", %{
    repo: repo,
    repo_id: repo_id
  } do
    {^repo_id, run_id} = run_key = open_run(repo_id)
    :ok = Writer.record_feature_terminal(run_key, "001", :done, nil)
    close(run_key)

    assert {:error, :confirmation_required} = SpeckitOrchestrator.prune(repo: repo)
    assert {:ok, [%{run_id: ^run_id}]} = SpeckitOrchestrator.run_history(repo: repo)
  end

  test "prune/1, confirm: true deletes every row of a removable run across all tables, leaving a resumable run and its rows untouched",
       %{repo: repo, repo_id: repo_id} do
    {^repo_id, removable_id} = removable_key = open_run(repo_id, "001")
    :ok = Writer.record_phase_attempt(removable_key, attempt("001", "gone"))
    :ok = Writer.record_feature_terminal(removable_key, "001", :done, nil)
    close(removable_key)

    {^repo_id, kept_id} = kept_key = open_run(repo_id, "002")
    :ok = Writer.record_phase_attempt(kept_key, attempt("002", "kept"))

    :ok =
      Writer.record_escalation(kept_key, %{
        feature_id: "002",
        kind: :escalated,
        phase: :analyze,
        reason: "critical finding",
        evidence: %{}
      })

    :ok = Writer.record_feature_terminal(kept_key, "002", :escalated, "critical finding")
    close(kept_key, :escalated)

    assert {:ok, %{removed: [^removable_id], bytes_reclaimed: bytes}} =
             SpeckitOrchestrator.prune(repo: repo, confirm: true)

    assert bytes > 0

    assert {:ok, [%{run_id: ^kept_id}]} = SpeckitOrchestrator.run_history(repo: repo)
    assert {:error, :absent} = SpeckitOrchestrator.run_detail(removable_id, repo: repo)

    assert {:ok, %{run: %{run_id: ^kept_id}}} =
             SpeckitOrchestrator.run_detail(kept_id, repo: repo)

    assert {:ok, rows} =
             Mnesia.transaction(fn ->
               Mnesia.index_read(:speckit_feature_run, removable_key, :run_key)
             end)

    assert rows == []
  end

  test "filling the store past headroom without pruning leaves row counts unchanged (SC-014)", %{
    repo_id: repo_id
  } do
    for n <- 1..3 do
      key = open_run(repo_id, "f#{n}")
      :ok = Writer.record_feature_terminal(key, "f#{n}", :done, nil)
      close(key)
    end

    before_count = Mnesia.table_info(:speckit_run, :size)
    assert before_count == 3

    Application.put_env(:speckit_orchestrator, :store_capacity_bytes, 1)
    Application.put_env(:speckit_orchestrator, :store_headroom_bytes, 1)
    on_exit(fn -> Application.delete_env(:speckit_orchestrator, :store_capacity_bytes) end)
    on_exit(fn -> Application.delete_env(:speckit_orchestrator, :store_headroom_bytes) end)

    assert {:ok, %{status: :refusing}} = SpeckitOrchestrator.store_capacity()
    assert Mnesia.table_info(:speckit_run, :size) == before_count
  end
end
