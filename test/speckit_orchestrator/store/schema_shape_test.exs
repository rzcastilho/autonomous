defmodule SpeckitOrchestrator.Store.SchemaShapeTest do
  @moduledoc """
  The guard against `Schema` disagreeing with the tables on disk.

  This is the failure that killed a live run: `pr_url` was added to
  `Schema.table(:speckit_feature_run).attributes` and the project recompiled, so
  the running node believed the table had 15 attributes while the tables on disk
  still had 14 — no reboot, so no migration. Every `feature_run` read then
  returned `{:damaged, key, :shape_mismatch}` against rows that were perfectly
  intact, the run was flagged incomplete, and a feature was marked `:failed` for
  reasons that had nothing to do with it.

  `async: false` — these tests mutate the node-global booted-shape snapshot, and
  one of them reshapes a live table.
  """
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Store.{Boot, Mnesia, Records, Schema, Shape}

  @table :speckit_feature_run

  setup do
    # Restore whatever the suite's own boot recorded, whatever a test does to it.
    booted = Shape.booted(@table)

    on_exit(fn ->
      if booted, do: Shape.record(%{@table => booted}), else: Shape.forget()
      Boot.verify_table_shapes()
    end)

    {:ok, expected: Schema.table(@table).attributes}
  end

  defp one_short(attributes), do: List.delete(attributes, List.last(attributes))

  describe "Records.decode/2" do
    test "a Schema that outran the booted tables is reported as unmigrated, naming both shapes",
         %{expected: expected} do
      booted = one_short(expected)
      # The state a node is in after Schema gains an attribute and nothing
      # restarted: the tables are still the shape boot found them in.
      Shape.record(%{@table => booted})

      # A row in that booted shape — intact on disk, undecodable by this build.
      row = List.to_tuple([@table | Enum.map(booted, fn _ -> nil end)])

      assert {:error, {:damaged, _key, reason}} = Records.decode(@table, row)
      assert reason == {:unmigrated_schema, @table, expected, booted}
    end

    test "a genuinely malformed row against an in-step table is still :shape_mismatch" do
      assert {:error, {:damaged, _key, :shape_mismatch}} =
               Records.decode(@table, {@table, {"o:r", "r1", "001"}})
    end

    test "with no recorded shape at all it stays :shape_mismatch — no evidence either way" do
      Shape.forget()

      assert {:error, {:damaged, _key, :shape_mismatch}} =
               Records.decode(@table, {@table, {"o:r", "r1", "001"}})
    end

    test "an unknown table stays :shape_mismatch" do
      assert {:error, {:damaged, :unknown, :shape_mismatch}} =
               Records.decode(:not_a_real_table, {:not_a_real_table})
    end
  end

  describe "Store.Shape" do
    test "mismatch/2 is nil while Schema and the snapshot agree", %{expected: expected} do
      Shape.record(%{@table => expected})
      assert Shape.mismatch(@table, expected) == nil
    end

    test "mismatch/2 reports both shapes once they diverge", %{expected: expected} do
      booted = one_short(expected)
      Shape.record(%{@table => booted})
      assert Shape.mismatch(@table, expected) == {expected, booted}
    end

    test "mismatch/2 is nil with no snapshot, or with no expected shape", %{expected: expected} do
      Shape.forget()
      assert Shape.mismatch(@table, expected) == nil
      assert Shape.mismatch(@table, nil) == nil
    end
  end

  describe "Boot.verify_table_shapes/0" do
    test "passes against the booted store and records every table's shape", %{
      expected: expected
    } do
      Shape.forget()

      assert Boot.verify_table_shapes() == :ok
      assert Shape.booted(@table) == expected

      for %{name: name, attributes: attrs} <- Schema.tables() do
        assert Shape.booted(name) == attrs
      end
    end

    test "refuses a table whose live attributes disagree with Schema, naming both", %{
      expected: expected
    } do
      short = one_short(expected)
      :ok = Mnesia.transform_table(@table, &Tuple.delete_at(&1, tuple_size(&1) - 1), short)

      try do
        assert Boot.verify_table_shapes() ==
                 {:error, {:schema_shape_mismatch, @table, expected, short}}
      after
        :ok = Mnesia.transform_table(@table, &Tuple.insert_at(&1, tuple_size(&1), nil), expected)
      end
    end
  end
end
