defmodule SpeckitOrchestrator.Store.MigrationsTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Migrations

  test "current_version/0 is 5 (019 clean break + pr_url + advanced_with_findings + spec_number)" do
    assert Migrations.current_version() == 5
  end

  test "all/0 is the v2 refusal, the v3 pr_url transform, the v4 advanced_with_findings transform, and the v5 spec_number transform" do
    assert [
             {2, v2_description, v2_fun},
             {3, v3_description, v3_fun},
             {4, v4_description, v4_fun},
             {5, v5_description, v5_fun}
           ] = Migrations.all()

    assert v2_description =~ "019 clean break"
    assert is_function(v2_fun, 0)
    assert v2_fun.() == {:error, {:incompatible_record, 1}}

    assert v3_description =~ "pr_url"
    assert is_function(v3_fun, 0)

    assert v4_description =~ "advanced_with_findings"
    assert is_function(v4_fun, 0)

    assert v5_description =~ "spec_number"
    assert is_function(v5_fun, 0)
  end

  describe "apply_pending/1" do
    test "from a fresh schema (nil) — unreachable in practice, since Store.Boot writes the current version directly without calling apply_pending, but the function itself must not silently succeed past a registered migration" do
      assert Migrations.apply_pending(nil) == {:error, {:incompatible_record, 1}}
    end

    test "from a recorded v1 — the v2 migration refuses, naming the incompatibility (FR-023), and halts before v3 runs" do
      assert Migrations.apply_pending(1) == {:error, {:incompatible_record, 1}}
    end

    test "from the current version — nothing pending, succeeds as a no-op" do
      assert Migrations.apply_pending(Migrations.current_version()) == :ok
      assert Migrations.apply_pending(Migrations.current_version() + 1) == :ok
    end
  end

  # Real-store migration (quickstart.md §6, SC-005): boots in an isolated
  # subprocess against its own temp directory, same technique as
  # `Store.BootTest`, so it never touches the suite's shared live store.
  @tag :integration
  test "a recorded v4 schema migrates to v5 in place — every row survives and spec_number backfills from number" do
    dir = tmp_dir("v4_migrated")

    output =
      boot_script(dir, """
      alias SpeckitOrchestrator.Store.{Mnesia, Records, Schema}

      v5 = Schema.table(:speckit_feature_run).attributes
      v4 = List.delete(v5, :spec_number)

      # Reshape the live table back into the v4 record it would have on disk,
      # then write two rows through that older shape.
      Mnesia.transform_table(:speckit_feature_run, &Tuple.delete_at(&1, tuple_size(&1) - 1), v4)

      row = fn feature_id, number ->
        List.to_tuple([:speckit_feature_run | Enum.map(v4, fn
          :key -> {"o:repo", "r000001", feature_id}
          :run_key -> {"o:repo", "r000001"}
          :feature_id -> feature_id
          :slug -> "core-ledger"
          :number -> number
          :status -> :done
          _ -> nil
        end)])
      end

      Mnesia.transaction(fn ->
        Mnesia.write(row.("001", 1))
        Mnesia.write(row.("002", 2))
        Mnesia.write({:speckit_meta, :schema_version, 4})
      end)

      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end

      {:ok, version} = Mnesia.transaction(fn ->
        Mnesia.read(:speckit_meta, :schema_version)
      end)
      IO.puts("VERSION_AFTER " <> inspect(version))

      {:ok, rows} = Mnesia.transaction(fn ->
        [Mnesia.read(:speckit_feature_run, {"o:repo", "r000001", "001"}),
         Mnesia.read(:speckit_feature_run, {"o:repo", "r000001", "002"})]
      end)

      [[t1], [t2]] = rows
      {:ok, f1} = Records.decode(:speckit_feature_run, t1)
      {:ok, f2} = Records.decode(:speckit_feature_run, t2)
      IO.puts("MIGRATED " <> inspect({f1.feature_id, f1.number, f1.spec_number, f1.status}))
      IO.puts("MIGRATED " <> inspect({f2.feature_id, f2.number, f2.spec_number, f2.status}))
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_OK"
    assert output =~ "VERSION_AFTER [{:speckit_meta, :schema_version, 5}]"
    # Nothing dropped or truncated; each row's spec_number equals its own
    # :number (FR-007) — a backfill, not an invented value.
    assert output =~ ~s(MIGRATED {"001", 1, 1, :done})
    assert output =~ ~s(MIGRATED {"002", 2, 2, :done})
  end

  @tag :integration
  test "a v1 directory still aborts by name — migration 5 never runs past the 019 refusal" do
    dir = tmp_dir("v1_still_refused")

    output =
      boot_script(dir, """
      SpeckitOrchestrator.Store.Mnesia.transaction(fn ->
        SpeckitOrchestrator.Store.Mnesia.write({:speckit_meta, :schema_version, 1})
      end)

      case SpeckitOrchestrator.Store.Boot.start!(#{inspect(dir)}) do
        :ok -> IO.puts("SECOND_BOOT_OK")
        {:error, reason} -> IO.puts("SECOND_BOOT_ERROR " <> inspect(reason))
      end
      """)

    assert output =~ "BOOT_OK"
    assert output =~ "SECOND_BOOT_ERROR {:incompatible_record, 1}"
  end

  # ---- helpers (mirrors Store.BootTest) --------------------------------

  defp tmp_dir(label) do
    Path.join(
      System.tmp_dir!(),
      "speckit_migrations_test_#{label}_#{System.unique_integer([:positive])}"
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
