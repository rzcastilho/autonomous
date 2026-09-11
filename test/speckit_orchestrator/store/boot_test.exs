defmodule SpeckitOrchestrator.Store.BootTest do
  @moduledoc """
  `Store.Boot` owns process-global state (`:mnesia` is a per-node singleton),
  so exercising a fresh schema, a node-ownership mismatch, or a
  schema-version-ahead abort would corrupt the suite's shared, already-booted
  store if done in-process. Each scenario here boots in an isolated
  subprocess against its own temp directory instead.
  """

  use ExUnit.Case, async: false

  @tag :boot_subprocess
  test "a fresh schema boots :ok, creates every table, and the write-probe proves writability" do
    dir = tmp_dir("fresh")

    output =
      boot_script(dir, """
      tables = SpeckitOrchestrator.Store.Schema.names() |> MapSet.new()
      created = :mnesia.system_info(:tables) |> MapSet.new()
      IO.puts("TABLES_OK " <> to_string(MapSet.subset?(tables, created)))

      {:ok, probe} = SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.read(:speckit_meta, :write_probe)
      end)
      IO.puts("PROBE_OK " <> to_string(match?([{:speckit_meta, :write_probe, _}], probe)))

      {:ok, version} = SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.read(:speckit_meta, :schema_version)
      end)
      IO.puts("VERSION " <> inspect(version))
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "TABLES_OK true"
    assert output =~ "PROBE_OK true"
    assert output =~ "VERSION [{:speckit_meta, :schema_version, 5}]"
  end

  @tag :boot_subprocess
  test "rebooting against the same directory is idempotent" do
    dir = tmp_dir("reboot")

    output =
      boot_script(dir, """
      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_OK"
  end

  @tag :boot_subprocess
  test "a node recorded in speckit_meta different from node() aborts loud, naming both" do
    dir = tmp_dir("node_mismatch")

    output =
      boot_script(dir, """
      SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.write({:speckit_meta, :node, :"decoy@nohost"})
      end)

      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_ERROR {:schema_node_mismatch, :nonode@nohost, :decoy@nohost}"
  end

  @tag :boot_subprocess
  test "a schema_version newer than current aborts loud, never auto-coercing or downgrading" do
    dir = tmp_dir("version_ahead")

    output =
      boot_script(dir, """
      current = SpeckitOrchestrator.Store.Migrations.current_version()

      SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.write({:speckit_meta, :schema_version, current + 1})
      end)

      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_ERROR {:schema_version_ahead, 6, 5}"
  end

  @tag :boot_subprocess
  test "a recorded v1 schema aborts startup naming the incompatibility, per the 019 clean break (FR-022, FR-023)" do
    dir = tmp_dir("v1_refused")

    output =
      boot_script(dir, """
      SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.write({:speckit_meta, :schema_version, 1})
      end)

      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end

      {:ok, version} = SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.read(:speckit_meta, :schema_version)
      end)
      IO.puts("VERSION_AFTER " <> inspect(version))
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_ERROR {:incompatible_record, 1}"
    # The recorded version is left exactly as found — a refused migration
    # never partially advances it.
    assert output =~ "VERSION_AFTER [{:speckit_meta, :schema_version, 1}]"
  end

  @tag :boot_subprocess
  test "a recorded v2 schema migrates in place — feature_run rows survive and gain pr_url: nil, advanced_with_findings: nil, and spec_number: nil" do
    dir = tmp_dir("v2_migrated")

    output =
      boot_script(dir, """
      alias SpeckitOrchestrator.Store.{Mnesia, Records}

      # Pinned literal v2 shape — NOT derived from the live (current) schema,
      # which has moved on since. Deriving "the previous version" from
      # `Schema.table/1` breaks the moment the schema grows past it again.
      v2 = [
        :key, :run_key, :feature_id, :slug, :path, :number, :group,
        :created_at, :status, :terminal_reason, :worktree_path, :branch,
        :pr_description, :started_at, :ended_at
      ]

      # Reshape the live table back into the v2 record it would have on disk,
      # then write a row through that older shape.
      Mnesia.transform_table(:speckit_feature_run, &Tuple.delete_at(&1, tuple_size(&1) - 1), v2)

      row = List.to_tuple([:speckit_feature_run | Enum.map(v2, fn
        :key -> {"o:repo", "r000001", "001"}
        :run_key -> {"o:repo", "r000001"}
        :feature_id -> "001"
        :slug -> "core-ledger"
        :status -> :done
        _ -> nil
      end)])

      Mnesia.transaction(fn ->
        Mnesia.write(row)
        Mnesia.write({:speckit_meta, :schema_version, 2})
      end)

      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end

      {:ok, version} = Mnesia.transaction(fn ->
        Mnesia.read(:speckit_meta, :schema_version)
      end)
      IO.puts("VERSION_AFTER " <> inspect(version))

      {:ok, [tuple]} = Mnesia.transaction(fn ->
        Mnesia.read(:speckit_feature_run, {"o:repo", "r000001", "001"})
      end)
      {:ok, feature} = Records.decode(:speckit_feature_run, tuple)
      IO.puts("MIGRATED " <> inspect({feature.feature_id, feature.status, feature.pr_url, feature.advanced_with_findings, feature.spec_number}))
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_OK"
    assert output =~ "VERSION_AFTER [{:speckit_meta, :schema_version, 5}]"
    # The row is still readable through the current decode, with every
    # appended field defaulted/backfilled — a migration, not a reset.
    # spec_number backfills from :number, which this synthetic row left nil.
    assert output =~ ~s(MIGRATED {"001", :done, nil, nil, nil})
  end

  @tag :boot_subprocess
  test "a recorded v3 schema migrates in place — feature_run rows survive and gain advanced_with_findings: nil (feature 021) and spec_number backfilled" do
    dir = tmp_dir("v3_migrated")

    output =
      boot_script(dir, """
      alias SpeckitOrchestrator.Store.{Mnesia, Records}

      # Pinned literal v3 shape — see the v2 test above for why this must not
      # be derived from the live schema.
      v3 = [
        :key, :run_key, :feature_id, :slug, :path, :number, :group,
        :created_at, :status, :terminal_reason, :worktree_path, :branch,
        :pr_description, :started_at, :ended_at, :pr_url
      ]

      # Reshape the live table back into the v3 record it would have on disk,
      # then write a row through that older shape.
      Mnesia.transform_table(:speckit_feature_run, &Tuple.delete_at(&1, tuple_size(&1) - 1), v3)

      row = List.to_tuple([:speckit_feature_run | Enum.map(v3, fn
        :key -> {"o:repo", "r000001", "001"}
        :run_key -> {"o:repo", "r000001"}
        :feature_id -> "001"
        :slug -> "core-ledger"
        :number -> 1
        :status -> :done
        :pr_url -> "https://github.com/o/repo/pull/1"
        _ -> nil
      end)])

      Mnesia.transaction(fn ->
        Mnesia.write(row)
        Mnesia.write({:speckit_meta, :schema_version, 3})
      end)

      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end

      {:ok, version} = Mnesia.transaction(fn ->
        Mnesia.read(:speckit_meta, :schema_version)
      end)
      IO.puts("VERSION_AFTER " <> inspect(version))

      {:ok, [tuple]} = Mnesia.transaction(fn ->
        Mnesia.read(:speckit_feature_run, {"o:repo", "r000001", "001"})
      end)
      {:ok, feature} = Records.decode(:speckit_feature_run, tuple)
      IO.puts("MIGRATED " <> inspect({feature.feature_id, feature.pr_url, feature.advanced_with_findings, feature.spec_number}))
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_OK"
    assert output =~ "VERSION_AFTER [{:speckit_meta, :schema_version, 5}]"
    # pr_url survives untouched; advanced_with_findings is nil (appended);
    # spec_number backfills from this row's own :number (1) — feature 022.
    assert output =~ ~s(MIGRATED {"001", "https://github.com/o/repo/pull/1", nil, 1})
  end

  # ---- helpers ----------------------------------------------------------

  defp tmp_dir(label) do
    Path.join(
      System.tmp_dir!(),
      "speckit_boot_test_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp boot_script(dir, extra_code) do
    script = """
    Application.put_env(:speckit_orchestrator, :store_dir, #{inspect(dir)})

    case SpeckitOrchestrator.Store.Boot.start!() do
      :ok -> IO.puts("BOOT_OK")
      {:error, reason} -> IO.puts("BOOT_ERROR " <> inspect(reason))
    end

    #{extra_code}
    """

    {output, _exit_status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    File.rm_rf(dir)
    output
  end
end
