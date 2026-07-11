defmodule SpeckitOrchestrator.ResolveTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Feature, Worktree}

  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp scaffolded_repo do
    repo = Path.join(System.tmp_dir!(), "rs_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# C\n")
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    on_exit(fn -> File.rm_rf(repo) end)
    repo
  end

  defp feature, do: %Feature{id: "007", slug: "recurring", path: "007-recurring.md"}

  test "resolve/2 removes a kept worktree; the branch survives and can be reused" do
    repo = scaffolded_repo()
    root = Path.join(System.tmp_dir!(), "rs_root_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    opts = [repo: repo, worktree_root: root, features: [feature()]]

    {:ok, wt} = Worktree.create(feature(), repo: repo, worktree_root: root)
    # simulate a human committing clarifications on the feature branch
    File.write!(Path.join(wt.path, "resolved.txt"), "clarified")
    git!(wt.path, ["add", "-A"])
    git!(wt.path, ["commit", "-q", "-m", "human resolution"])

    assert :ok = SpeckitOrchestrator.resolve("007", opts)
    refute File.dir?(wt.path)

    # branch still exists (human's commit preserved)
    {out, 0} = System.cmd("git", ["-C", repo, "branch", "--list", "feature/007-recurring"])
    assert out =~ "feature/007-recurring"

    # re-run reuses the existing branch (no -b) and gets the human's file
    {:ok, wt2} = Worktree.create(feature(), repo: repo, worktree_root: root)
    assert File.read!(Path.join(wt2.path, "resolved.txt")) == "clarified"
  end

  test "resolve/2 is a no-op when there is no kept worktree" do
    repo = scaffolded_repo()
    opts = [repo: repo, worktree_root: Path.join(System.tmp_dir!(), "none_#{System.unique_integer([:positive])}"), features: [feature()]]
    assert :ok = SpeckitOrchestrator.resolve("007", opts)
  end

  test "resolve/2 errors on an unknown feature" do
    assert {:error, {:unknown_feature, "999"}} =
             SpeckitOrchestrator.resolve("999", features: [feature()])
  end
end
