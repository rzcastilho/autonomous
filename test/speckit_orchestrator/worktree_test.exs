defmodule SpeckitOrchestrator.WorktreeTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Feature, Worktree}

  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # Build a throwaway base repo with the committed scaffold, unless
  # `scaffold: false`.
  defp base_repo(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "wt_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    git!(dir, ["config", "user.email", "t@example.com"])
    git!(dir, ["config", "user.name", "Tester"])

    if Keyword.get(opts, :scaffold, true) do
      File.mkdir_p!(Path.join(dir, ".specify/memory"))
      File.write!(Path.join(dir, ".specify/memory/constitution.md"), "# Constitution\n")
      File.mkdir_p!(Path.join(dir, ".claude/skills"))
      File.write!(Path.join(dir, ".claude/skills/.gitkeep"), "")
      File.write!(Path.join(dir, ".claude/settings.json"), ~s({"permissions":{}}))
    end

    File.write!(Path.join(dir, "README.md"), "base\n")
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", "base"])

    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp feature, do: %Feature{id: "001", slug: "core-ledger", path: "001-core-ledger.md"}

  defp with_root(repo) do
    root = Path.join(System.tmp_dir!(), "wt_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    [repo: repo, worktree_root: root]
  end

  test "create/2 adds a worktree on feature/NNN-slug with the scaffold present" do
    repo = base_repo()
    opts = with_root(repo)

    assert {:ok, wt} = Worktree.create(feature(), opts)
    assert wt.branch == "feature/001-core-ledger"
    assert wt.feature_id == "001"
    assert File.dir?(wt.path)
    assert File.dir?(Path.join(wt.path, ".specify"))
    assert File.regular?(Path.join(wt.path, ".claude/settings.json"))

    {out, 0} = System.cmd("git", ["-C", repo, "branch", "--list", "feature/001-core-ledger"])
    assert out =~ "feature/001-core-ledger"
  end

  test "create/2 aborts and tears down when the scaffold is missing" do
    repo = base_repo(scaffold: false)
    opts = with_root(repo)

    assert {:error, {:missing_scaffold, missing}} = Worktree.create(feature(), opts)
    assert ".specify" in missing
    assert ".claude/settings.json" in missing
    # half-made worktree was removed
    refute File.dir?(Path.join(opts[:worktree_root], "001-core-ledger"))
  end

  test "create/2 with require_scaffold: false skips the assertion" do
    repo = base_repo(scaffold: false)
    opts = with_root(repo) ++ [require_scaffold: false]
    assert {:ok, wt} = Worktree.create(feature(), opts)
    assert File.dir?(wt.path)
  end

  test "remove/1 deletes the worktree directory" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))
    assert File.dir?(wt.path)
    assert :ok = Worktree.remove(wt)
    refute File.dir?(wt.path)
  end

  test "keep_for_inspection/1 leaves the tree and returns its path" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))
    assert {:ok, path} = Worktree.keep_for_inspection(wt)
    assert path == wt.path
    assert File.dir?(path)
  end

  test "create/2 surfaces a git failure (duplicate branch)" do
    repo = base_repo()
    opts = with_root(repo)
    assert {:ok, _} = Worktree.create(feature(), opts)
    # second create at a fresh root but same branch name -> git fails
    assert {:error, {:worktree_add, _}} = Worktree.create(feature(), with_root(repo))
  end
end
