defmodule Autonomous.VolumeUsageTest do
  use ExUnit.Case, async: true

  alias Autonomous.VolumeUsage

  @moduletag :tmp_dir

  test "measures a directory in bytes", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "f"), String.duplicate("x", 20_000))
    assert {:ok, bytes} = VolumeUsage.measure(dir)
    assert bytes >= 20_000 and rem(bytes, 1024) == 0
  end

  test "missing path is not mounted, never zero", %{tmp_dir: dir} do
    assert {:unknown, "not mounted"} = VolumeUsage.measure(Path.join(dir, "nope"))
  end

  test "a slow command times out", %{tmp_dir: dir} do
    slow = fn _ ->
      Process.sleep(500)
      {"1\tx", 0}
    end

    assert {:unknown, "timed out"} = VolumeUsage.measure(dir, 20, command: slow)
  end

  test "du failure is reported with its first line", %{tmp_dir: dir} do
    failing = fn _ -> {"du: cannot read\nmore", 1} end

    assert {:unknown, "du failed: du: cannot read"} =
             VolumeUsage.measure(dir, 1000, command: failing)
  end

  test "unparseable output is unknown", %{tmp_dir: dir} do
    assert {:unknown, "du failed: garbage"} =
             VolumeUsage.measure(dir, 1000, command: fn _ -> {"garbage", 0} end)
  end
end
