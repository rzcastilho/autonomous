defmodule SpeckitOrchestrator.Container.MountTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Container.Mount

  @fixtures_dir Path.join([__DIR__, "..", "..", "fixtures", "mountinfo"])

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  describe "parse/1" do
    test "parses mount_point, fs_type, and options for every line" do
      mounts = Mount.parse(fixture("durable_bind_mount.txt"))
      assert length(mounts) == 4

      autonomous = Enum.find(mounts, &(&1.mount_point == "/home/alice/.autonomous"))
      assert autonomous.fs_type == "ext4"
      assert "rw" in autonomous.options
    end

    test "handles a line with an optional field before the '-' separator" do
      mounts = Mount.parse(fixture("tmpfs_home_nested_bind.txt"))
      nested = Enum.find(mounts, &(&1.mount_point == "/home/alice/.autonomous"))
      assert nested.fs_type == "ext4"
    end
  end

  describe "mount_point?/2" do
    test "durable bind mount at $HOME/.autonomous is recognised" do
      assert Mount.mount_point?(fixture("durable_bind_mount.txt"), "/home/alice/.autonomous")
    end

    test "tmpfs-only $HOME — $HOME/.autonomous is NOT its own mount point" do
      refute Mount.mount_point?(fixture("tmpfs_home_only.txt"), "/home/alice/.autonomous")
    end

    test "$HOME (the tmpfs itself) IS a mount point" do
      assert Mount.mount_point?(fixture("tmpfs_home_only.txt"), "/home/alice")
    end

    test "nested bind: $HOME is tmpfs AND $HOME/.autonomous is its own bind mount" do
      contents = fixture("tmpfs_home_nested_bind.txt")
      assert Mount.mount_point?(contents, "/home/alice")
      assert Mount.mount_point?(contents, "/home/alice/.autonomous")
    end

    test "a path with no matching entry is not a mount point" do
      refute Mount.mount_point?(fixture("durable_bind_mount.txt"), "/no/such/path")
    end

    test "trailing slash on the queried path is normalized" do
      assert Mount.mount_point?(fixture("durable_bind_mount.txt"), "/home/alice/.autonomous/")
    end
  end
end
