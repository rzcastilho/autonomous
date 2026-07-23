defmodule SpeckitOrchestrator.RunManifestTest do
  # async: false — mutates the global :transcript_root app env.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Feature, RunContext, RunManifest}

  setup do
    root = Path.join(System.tmp_dir!(), "rm_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:speckit_orchestrator, :transcript_root)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:speckit_orchestrator, :transcript_root, prev)
    end)

    %{root: root}
  end

  defp manifest_path(root), do: Path.join(root, "run.json")

  defp feat(id, prereqs \\ []),
    do: %Feature{id: id, slug: "f#{id}", path: "#{id}.md", prereqs: prereqs}

  defp base_payload(overrides \\ %{}) do
    Map.merge(
      %{
        features: [feat("001"), feat("002", ["001"])],
        statuses: %{"001" => :done, "002" => :running},
        context: %RunContext{pr_workflow: false, max_concurrency: 2},
        spend: 12.5,
        updated_at: 1
      },
      overrides
    )
  end

  # ---- write/1, read/0, clear/0 (T016) --------------------------------------

  test "write/1 persists features/statuses/context/spend/updated_at, string-keyed", %{root: root} do
    assert :ok = RunManifest.write(base_payload())

    decoded = root |> manifest_path() |> File.read!() |> Jason.decode!()

    assert decoded["spend"] == 12.5
    assert decoded["updated_at"] == 1
    assert decoded["statuses"] == %{"001" => "done", "002" => "running"}
    assert decoded["context"]["pr_workflow"] == false
    assert decoded["context"]["max_concurrency"] == 2

    assert decoded["features"] == [
             %{"id" => "001", "slug" => "f001", "path" => "001.md", "prereqs" => []},
             %{"id" => "002", "slug" => "f002", "path" => "002.md", "prereqs" => ["001"]}
           ]
  end

  test "read/0 returns {:ok, map} after a write" do
    :ok = RunManifest.write(base_payload())
    assert {:ok, record} = RunManifest.read()
    assert record["spend"] == 12.5
  end

  test "read/0 returns {:error, :no_manifest} when the slot is absent" do
    assert {:error, :no_manifest} = RunManifest.read()
  end

  test "read/0 returns {:error, :corrupt} on undecodable JSON", %{root: root} do
    File.mkdir_p!(root)
    File.write!(manifest_path(root), "not valid json{")
    assert {:error, :corrupt} = RunManifest.read()
  end

  test "read/0 returns {:error, :corrupt} on a JSON array (not an object)", %{root: root} do
    File.mkdir_p!(root)
    File.write!(manifest_path(root), Jason.encode!([1, 2, 3]))
    assert {:error, :corrupt} = RunManifest.read()
  end

  test "read/0 returns {:error, :corrupt} on a non-enoent File.read error", %{root: root} do
    # A directory at the manifest path makes File.read/1 fail with :eisdir,
    # not :enoent — exercises the read/0 error branch other than "absent".
    File.mkdir_p!(manifest_path(root))
    assert {:error, :corrupt} = RunManifest.read()
  end

  test "clear/0 deletes the slot", %{root: root} do
    :ok = RunManifest.write(base_payload())
    assert File.exists?(manifest_path(root))
    assert :ok = RunManifest.clear()
    refute File.exists?(manifest_path(root))
  end

  test "clear/0 is a no-op on a missing file" do
    assert :ok = RunManifest.clear()
  end

  test "write/1 to an unwritable transcript root is swallowed and returns :ok" do
    Application.put_env(:speckit_orchestrator, :transcript_root, "/proc/nonexistent/deny")
    assert :ok = RunManifest.write(base_payload())
  end

  test "write/1 accepts statuses already given as strings", %{root: root} do
    :ok = RunManifest.write(base_payload(%{statuses: %{"001" => "done", "002" => "running"}}))
    decoded = root |> manifest_path() |> File.read!() |> Jason.decode!()
    assert decoded["statuses"] == %{"001" => "done", "002" => "running"}
  end

  test "write/1 defaults a nil context to an empty map", %{root: root} do
    :ok = RunManifest.write(base_payload(%{context: nil}))
    decoded = root |> manifest_path() |> File.read!() |> Jason.decode!()
    assert decoded["context"] == %{}
  end

  # ---- resumable?/0 (T017) ---------------------------------------------------

  test "resumable?/0 is true when at least one feature status is running" do
    :ok = RunManifest.write(base_payload(%{statuses: %{"001" => :done, "002" => :running}}))
    assert RunManifest.resumable?()
  end

  test "resumable?/0 is true when at least one feature status is pending" do
    :ok = RunManifest.write(base_payload(%{statuses: %{"001" => :done, "002" => :pending}}))
    assert RunManifest.resumable?()
  end

  test "resumable?/0 is false when every feature is done" do
    :ok = RunManifest.write(base_payload(%{statuses: %{"001" => :done, "002" => :done}}))
    refute RunManifest.resumable?()
  end

  test "resumable?/0 is false when every feature is a gate divert" do
    :ok =
      RunManifest.write(base_payload(%{statuses: %{"001" => :escalated, "002" => :halted}}))

    refute RunManifest.resumable?()
  end

  test "resumable?/0 is false when no manifest exists" do
    refute RunManifest.resumable?()
  end

  # ---- reconstruct/1 (T018) ---------------------------------------------------

  test "reconstruct/1 keeps done/escalated/halted/failed as-is and resets running/pending to :pending" do
    :ok =
      RunManifest.write(
        base_payload(%{
          statuses: %{
            "001" => :done,
            "002" => :escalated,
            "003" => :halted,
            "004" => :failed,
            "005" => :running,
            "006" => :pending
          },
          features: [
            feat("001"),
            feat("002"),
            feat("003"),
            feat("004"),
            feat("005"),
            feat("006")
          ]
        })
      )

    {:ok, record} = RunManifest.read()
    {features, statuses} = RunManifest.reconstruct(record)

    assert Enum.map(features, & &1.id) |> Enum.sort() ==
             ["001", "002", "003", "004", "005", "006"]

    assert statuses == %{
             "001" => :done,
             "002" => :escalated,
             "003" => :halted,
             "004" => :failed,
             "005" => :pending,
             "006" => :pending
           }
  end

  test "reconstruct/1 rebuilds %Feature{} structs with id/slug/path/prereqs" do
    :ok =
      RunManifest.write(base_payload(%{features: [feat("001"), feat("002", ["001"])]}))

    {:ok, record} = RunManifest.read()
    {features, _statuses} = RunManifest.reconstruct(record)

    assert [%Feature{id: "001", slug: "f001", path: "001.md", prereqs: []}, f2] =
             Enum.sort_by(features, & &1.id)

    assert f2.id == "002"
    assert f2.prereqs == ["001"]
  end

  test "reconstruct/1 maps an unrecognized status string to :pending (fail-safe default)" do
    :ok =
      RunManifest.write(base_payload(%{statuses: %{"001" => "weird"}, features: [feat("001")]}))

    {:ok, record} = RunManifest.read()
    {_features, statuses} = RunManifest.reconstruct(record)

    assert statuses == %{"001" => :pending}
  end
end
