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
    assert output =~ "VERSION [{:speckit_meta, :schema_version, 1}]"
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
    assert output =~ "SECOND_BOOT_ERROR {:schema_version_ahead, 2, 1}"
  end

  @tag :boot_subprocess
  test "a schema_version older than current applies pending migrations and advances the recorded version" do
    dir = tmp_dir("version_behind")

    output =
      boot_script(dir, """
      SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.write({:speckit_meta, :schema_version, 0})
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
    assert output =~ "SECOND_BOOT_OK"
    assert output =~ "VERSION_AFTER [{:speckit_meta, :schema_version, 1}]"
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
