defmodule SpeckitOrchestrator.Store.IdsTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Store.Ids

  describe "run_id/1" do
    test "zero-pads to 6 digits" do
      assert Ids.run_id(1) == "r000001"
      assert Ids.run_id(42) == "r000042"
      assert Ids.run_id(999_999) == "r999999"
    end

    test "does not truncate a sequence wider than 6 digits" do
      assert Ids.run_id(1_000_000) == "r1000000"
    end

    test "zero-padded ids sort lexicographically the same as numerically" do
      ids = for seq <- [1, 2, 10, 20, 100, 999_999], do: Ids.run_id(seq)
      assert Enum.sort(ids) == ids
    end
  end

  describe "run_seq/1" do
    test "round-trips with run_id/1" do
      for seq <- [1, 7, 123, 999_999] do
        assert Ids.run_seq(Ids.run_id(seq)) == seq
      end
    end
  end

  describe "key shapes" do
    test "run_key/2" do
      assert Ids.run_key("o:repo-abc123", "r000001") == {"o:repo-abc123", "r000001"}
    end

    test "feature_key/3" do
      assert Ids.feature_key("o:repo-abc123", "r000001", "003") ==
               {"o:repo-abc123", "r000001", "003"}
    end

    test "attempt_id/5" do
      assert Ids.attempt_id("o:repo-abc123", "r000001", "003", :analyze, 1) ==
               {"o:repo-abc123", "r000001", "003", :analyze, 1}
    end

    test "ordinal_id/4" do
      assert Ids.ordinal_id("o:repo-abc123", "r000001", "003", 2) ==
               {"o:repo-abc123", "r000001", "003", 2}
    end

    test "amendment_id/3" do
      assert Ids.amendment_id("o:repo-abc123", "r000001", 1) == {"o:repo-abc123", "r000001", 1}
    end
  end
end
