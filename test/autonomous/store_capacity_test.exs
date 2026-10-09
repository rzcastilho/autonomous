defmodule Autonomous.StoreCapacityTest do
  use Autonomous.StoreCase, async: false

  @moduledoc """
  `Autonomous.store_capacity/0` (018, T018) — measures via
  `Store.Query.capacity/0`, decides via `Store.Capacity.check/1`, estimates
  `reclaimable_bytes` via `Store.Prune.plan/3` over `Store.Query.runs/2`.
  """

  defp with_repo(dir) do
    prev = Application.get_env(:autonomous, :repo)
    Application.put_env(:autonomous, :repo, dir)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:autonomous, :repo, prev),
        else: Application.delete_env(:autonomous, :repo)
    end)
  end

  defp with_capacity(capacity_bytes, headroom_bytes) do
    prev_capacity = Application.get_env(:autonomous, :store_capacity_bytes)
    prev_headroom = Application.get_env(:autonomous, :store_headroom_bytes)

    Application.put_env(:autonomous, :store_capacity_bytes, capacity_bytes)
    Application.put_env(:autonomous, :store_headroom_bytes, headroom_bytes)

    on_exit(fn ->
      restore(:store_capacity_bytes, prev_capacity)
      restore(:store_headroom_bytes, prev_headroom)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:autonomous, key)
  defp restore(key, value), do: Application.put_env(:autonomous, key, value)

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "speckit_store_capacity_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    with_repo(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    :ok
  end

  test "reports :ok with a shortfall of nil when under capacity" do
    with_capacity(1_500_000_000, 150_000_000)

    assert {:ok, capacity} = Autonomous.store_capacity()
    assert capacity.status == :ok
    assert capacity.shortfall_bytes == nil
    assert capacity.used_bytes >= 0
    assert capacity.capacity_bytes == 1_500_000_000
    assert capacity.headroom_bytes == 150_000_000
    assert capacity.reclaimable_bytes >= 0
  end

  test "reports :refusing with a shortfall once headroom is exhausted (FR-031b)" do
    with_capacity(1, 1)

    assert {:ok, capacity} = Autonomous.store_capacity()
    assert capacity.status == :refusing
    assert is_integer(capacity.shortfall_bytes)
    assert capacity.shortfall_bytes > 0
  end

  test "reclaimable_bytes accounts for a resumable run as protected (never counted as reclaimable)" do
    with_capacity(1_500_000_000, 150_000_000)

    repo_id =
      Autonomous.RepoIdentity.partition(Application.get_env(:autonomous, :repo))

    {:ok, _run_id} =
      Store.open_run(repo_id, %{
        features: [
          %{
            feature_id: "001",
            slug: "f",
            path: "specs/001",
            number: 1,
            group: :backlog,
            created_at: nil
          }
        ],
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    assert {:ok, %{reclaimable_bytes: 0}} = Autonomous.store_capacity()
  end
end
