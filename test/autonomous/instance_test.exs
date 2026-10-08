defmodule Autonomous.InstanceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Autonomous.{Instance, RepoIdentity}

  @root "/state"

  defp derive(repo, partition), do: Instance.derive(repo, partition, @root)

  describe "derive/3" do
    test "is deterministic" do
      assert derive("/r/a", "o:a-3fa9c1") == derive("/r/a", "o:a-3fa9c1")
    end

    test "lays out the instance directory under <root>/instances/<segment>" do
      i = derive("/r/ledgerlite", "o:ledgerlite-3fa9c1")

      assert i.segment == "ledgerlite-3fa9c1"
      assert i.node_name == :"autonomous_ledgerlite-3fa9c1@autonomous"
      assert i.store_dir == "/state/instances/ledgerlite-3fa9c1/mnesia"
      assert i.lock_path == "/state/instances/ledgerlite-3fa9c1/instance.lock"
      assert i.owner_path == "/state/instances/ledgerlite-3fa9c1/instance.json"
      assert i.cookie_path == "/state/instances/ledgerlite-3fa9c1/cookie"
    end

    test "strips the local partition prefix too" do
      assert derive("/r/x", "l:x-local-abc123").segment == "x-local-abc123"
    end

    test "two repos get distinct segment, node name and store dir" do
      a = derive("/r/a", "o:a-111111")
      b = derive("/r/b", "o:b-222222")

      refute a.segment == b.segment
      refute a.node_name == b.node_name
      refute a.store_dir == b.store_dir
    end

    test "store_dir is never inside the repo" do
      i = derive("/r/a", "o:a-111111")
      refute String.starts_with?(i.store_dir, "/r/a/")
    end

    property "node_name is a valid short node name for any segment" do
      check all name <- string(:printable, min_length: 1, max_length: 40) do
        i = derive("/r/x", "o:" <> name <> "-3fa9c1")
        [prefix, host] = i.node_name |> Atom.to_string() |> String.split("@")

        assert host == "autonomous"
        assert prefix =~ ~r/\Aautonomous_[A-Za-z0-9_-]+\z/
      end
    end

    test "dots and unicode are sanitized" do
      i = derive("/r/x", "o:my.repo-é-3fa9c1")
      assert i.node_name == :"autonomous_my_repo-_-3fa9c1@autonomous"
      assert i.segment == "my.repo-é-3fa9c1"
    end
  end

  describe "env_lines/1" do
    test "six identity lines, worktree root last" do
      i = derive("/r/a", "o:a-111111")
      lines = Instance.env_lines(i)

      assert length(lines) == 6
      assert List.last(lines) == "AUTONOMOUS_WORKTREE_ROOT=" <> Autonomous.Layout.worktree_root(@root, i.segment)
      assert hd(lines) == "AUTONOMOUS_INSTANCE_SEGMENT=a-111111"
      assert Enum.at(lines, 4) == "AUTONOMOUS_INSTANCE_LOCK=" <> i.lock_path
    end
  end

  describe "derive/3 through RepoIdentity (SSH vs HTTPS)" do
    test "both origin spellings of one repo give one identity" do
      {:ok, ssh} = RepoIdentity.canonicalize("git@github.com:acme/ledgerlite.git")
      {:ok, https} = RepoIdentity.canonicalize("https://github.com/acme/ledgerlite")

      a = derive("/r/a", "o:" <> RepoIdentity.segment(ssh))
      b = derive("/r/b", "o:" <> RepoIdentity.segment(https))

      assert a.segment == b.segment
      assert a.node_name == b.node_name
      assert a.store_dir == b.store_dir
    end
  end

  describe "verify/2" do
    setup do
      {:ok, i: derive("/r/a", "o:a-111111")}
    end

    test "ok when lock, node and store dir all match", %{i: i} do
      assert :ok = Instance.verify(%{locked: i.lock_path, node: i.node_name, store_dir: i.store_dir}, i)
    end

    test "unlocked is refused first", %{i: i} do
      assert {:error, {:instance_unlocked, lock}} =
               Instance.verify(%{locked: nil, node: :nonode@nohost, store_dir: "/x"}, i)

      assert lock == i.lock_path
    end

    test "wrong lock value counts as unlocked", %{i: i} do
      assert {:error, {:instance_unlocked, _}} =
               Instance.verify(%{locked: "/other.lock", node: i.node_name, store_dir: i.store_dir}, i)
    end

    test "ad hoc node name is a node mismatch", %{i: i} do
      assert {:error, {:instance_mismatch, :node, expected, :adhoc@autonomous}} =
               Instance.verify(
                 %{locked: i.lock_path, node: :adhoc@autonomous, store_dir: i.store_dir},
                 i
               )

      assert expected == i.node_name
    end

    test "a non-distributed VM (no --sname) is a node mismatch before Mnesia opens", %{i: i} do
      assert {:error, {:instance_mismatch, :node, _expected, :nonode@nohost}} =
               Instance.verify(
                 %{locked: i.lock_path, node: :nonode@nohost, store_dir: i.store_dir},
                 i
               )
    end

    test "right short name on the wrong host is a node mismatch", %{i: i} do
      wrong = String.to_atom("autonomous_a-111111@somewhere-else")

      assert {:error, {:instance_mismatch, :node, _, ^wrong}} =
               Instance.verify(%{locked: i.lock_path, node: wrong, store_dir: i.store_dir}, i)
    end

    test "wrong store dir is a store_dir mismatch", %{i: i} do
      assert {:error, {:instance_mismatch, :store_dir, expected, "/elsewhere"}} =
               Instance.verify(
                 %{locked: i.lock_path, node: i.node_name, store_dir: "/elsewhere"},
                 i
               )

      assert expected == i.store_dir
    end
  end

  describe "served?/2" do
    setup do
      {:ok, i: derive("/r/a", "o:a-111111")}
    end

    test "partition-string form", %{i: i} do
      assert Instance.served?(i, "o:a-111111")
      refute Instance.served?(i, "o:b-222222")
      refute Instance.served?(i, "l:a-local-111111")
    end

    test "path form resolves through the injected partition function", %{i: i} do
      assert Instance.served?(i, "/r/a", fn "/r/a" -> "o:a-111111" end)
      refute Instance.served?(i, "/r/b", fn "/r/b" -> "o:b-222222" end)
    end
  end

  describe "NotServedError" do
    test "names both repositories" do
      error = Instance.NotServedError.exception(served: "/r/a", given: "/r/b")

      assert error.message =~ "this instance serves /r/a; /r/b is not served here."
      assert error.message =~ "scripts/autonomous shell --target /r/b"
    end
  end

  describe "outside container mode (the test config)" do
    test "verify!/0 and assert_served!/1 are no-ops" do
      assert :ok = Instance.verify!()
      assert :ok = Instance.assert_served!("/definitely/not/served")
      assert :ok = Instance.assert_served!("o:whatever-000000")
    end
  end
end
