defmodule SpeckitOrchestrator.Store.MnesiaTest do
  use SpeckitOrchestrator.StoreCase, async: false

  describe "storage-type rules (Store.Schema realized)" do
    test "disc_copies for run-control tables, disc_only_copies only for the transcript table" do
      assert Mnesia.table_info(:speckit_run, :storage_type) == :disc_copies
      assert Mnesia.table_info(:speckit_feature_run, :storage_type) == :disc_copies
      assert Mnesia.table_info(:speckit_transcript, :storage_type) == :disc_only_copies
    end

    test "speckit_run is the only ordered_set table" do
      assert Mnesia.table_info(:speckit_run, :type) == :ordered_set
      assert Mnesia.table_info(:speckit_transcript, :type) == :set
      assert Mnesia.table_info(:speckit_feature_run, :type) == :set
    end

    test "ordered_set + disc_only_copies is rejected by :mnesia (research R1 probe)" do
      result =
        :mnesia.create_table(:speckit_ordered_disc_only_probe,
          attributes: [:a, :b],
          type: :ordered_set,
          disc_only_copies: [node()]
        )

      assert {:aborted, {:bad_type, _tab, {:not_supported, :ordered_set, :disc_only_copies}}} =
               result
    end
  end

  describe "transaction/1" do
    test "commits and returns {:ok, result}" do
      assert {:ok, :done} = Mnesia.transaction(fn -> :done end)
    end

    test "an abort inside the fun surfaces as {:error, reason}" do
      assert {:error, :nope} = Mnesia.transaction(fn -> Mnesia.abort(:nope) end)
    end

    test "a raised exception inside the fun is also reported as {:error, _}, never propagated" do
      assert {:error, _reason} =
               Mnesia.transaction(fn -> raise "boom" end)
    end
  end

  describe "write/read/delete primitives" do
    test "write then read returns the row; delete then read returns []" do
      row = {:speckit_meta, :probe_key, "probe_value"}

      {:ok, [^row]} =
        Mnesia.transaction(fn ->
          Mnesia.write(row)
          Mnesia.read(:speckit_meta, :probe_key)
        end)

      {:ok, []} =
        Mnesia.transaction(fn ->
          Mnesia.delete(:speckit_meta, :probe_key)
          Mnesia.read(:speckit_meta, :probe_key)
        end)
    end

    test "transactional read-modify-write sequence bump loses no update under 50 concurrent writers" do
      repo_id = "o:mnesia-seq-probe"

      Mnesia.transaction(fn -> Mnesia.write({:speckit_seq, repo_id, 1, nil, nil}) end)

      1..50
      |> Task.async_stream(
        fn _ ->
          Mnesia.transaction(fn ->
            [{:speckit_seq, ^repo_id, next, origin, local_path}] =
              Mnesia.read(:speckit_seq, repo_id, :write)

            Mnesia.write({:speckit_seq, repo_id, next + 1, origin, local_path})
          end)
        end,
        max_concurrency: 25
      )
      |> Stream.run()

      {:ok, [{:speckit_seq, ^repo_id, final, nil, nil}]} =
        Mnesia.transaction(fn -> Mnesia.read(:speckit_seq, repo_id) end)

      assert final == 51
    end
  end

  describe "index_read/3" do
    test "returns rows matching the secondary index value" do
      Mnesia.transaction(fn ->
        Mnesia.write(
          {:speckit_run, {"o:idx-probe", "r000001"}, "o:idx-probe", "r000001", :in_flight, nil,
           :in_flight, DateTime.utc_now(), nil, nil, 0.0, true, nil, :ad_hoc, %{}, nil, 1}
        )

        Mnesia.write(
          {:speckit_run, {"o:idx-probe", "r000002"}, "o:idx-probe", "r000002", :completed,
           :all_done, :all_done, DateTime.utc_now(), DateTime.utc_now(), 1, 0.0, true, nil,
           :ad_hoc, %{}, nil, 1}
        )

        Mnesia.write(
          {:speckit_run, {"o:idx-other", "r000001"}, "o:idx-other", "r000001", :in_flight, nil,
           :in_flight, DateTime.utc_now(), nil, nil, 0.0, true, nil, :ad_hoc, %{}, nil, 1}
        )
      end)

      {:ok, rows} =
        Mnesia.transaction(fn -> Mnesia.index_read(:speckit_run, "o:idx-probe", :repo_id) end)

      assert length(rows) == 2
      assert Enum.all?(rows, fn tuple -> elem(tuple, 2) == "o:idx-probe" end)
    end
  end

  describe "table_info/2" do
    test ":memory for the disc_only_copies transcript table is bytes, not words (research R1 probe)" do
      assert is_integer(Mnesia.table_info(:speckit_transcript, :memory))
    end
  end
end
