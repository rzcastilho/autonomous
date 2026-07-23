defmodule SpeckitOrchestrator.WorktreeTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{Feature, Worktree}

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

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

  test "commit/2 persists generated artifacts onto the branch, honoring .gitignore" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))

    File.write!(Path.join(wt.path, ".gitignore"), ".speckit_logs/\n")
    File.mkdir_p!(Path.join(wt.path, "lib"))
    File.write!(Path.join(wt.path, "lib/ledger.ex"), "defmodule Ledger do\nend\n")
    File.mkdir_p!(Path.join(wt.path, ".speckit_logs"))
    File.write!(Path.join(wt.path, ".speckit_logs/01-specify.md"), "transcript\n")

    assert :ok = Worktree.commit(wt, "speckit: feature 001 pipeline artifacts (done)")

    {tree, 0} = System.cmd("git", ["-C", repo, "ls-tree", "-r", "--name-only", wt.branch])
    assert tree =~ "lib/ledger.ex"
    # .gitignore respected — transcript logs stay out of the commit
    refute tree =~ ".speckit_logs"

    {msg, 0} = System.cmd("git", ["-C", repo, "log", "-1", "--format=%an %s", wt.branch])
    assert msg =~ "speckit-orchestrator"
    assert msg =~ "pipeline artifacts (done)"
  end

  test "commit/2 is a no-op on a clean tree" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))
    {before, 0} = System.cmd("git", ["-C", repo, "rev-parse", wt.branch])

    assert :noop = Worktree.commit(wt, "nothing to do")

    {after_, 0} = System.cmd("git", ["-C", repo, "rev-parse", wt.branch])
    assert before == after_
  end

  @tag :integration
  test "squash/3 collapses N per-phase commits into one at the fork point" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))
    {base_sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"])
    base_sha = String.trim(base_sha)

    for n <- 1..3 do
      File.write!(Path.join(wt.path, "file#{n}.txt"), "phase #{n}\n")
      git!(wt.path, ["add", "-A"])
      git!(wt.path, ["commit", "-q", "-m", "speckit: 001 checkpoint after phase#{n}"])
    end

    {pre_squash_head, 0} = System.cmd("git", ["-C", repo, "rev-parse", wt.branch])
    pre_squash_head = String.trim(pre_squash_head)

    assert :ok = Worktree.squash(wt, base_sha, "speckit: 001 pipeline artifacts (done)")

    {count, 0} =
      System.cmd("git", ["-C", repo, "rev-list", "--count", "#{base_sha}..#{wt.branch}"])

    assert String.trim(count) == "1"

    {diff, 0} = System.cmd("git", ["-C", repo, "diff", pre_squash_head, wt.branch])
    assert diff == ""
  end

  @tag :integration
  test "squash/3 returns :noop when nothing is staged after the reset" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))
    {head, 0} = System.cmd("git", ["-C", repo, "rev-parse", wt.branch])
    head = String.trim(head)

    assert :noop = Worktree.squash(wt, head, "nothing to squash")
  end

  @tag :integration
  test "restore/1 discards an uncommitted partial file and preserves gitignored transcripts" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))

    File.mkdir_p!(Path.join(wt.path, "lib"))
    File.write!(Path.join(wt.path, "lib/ledger.ex"), "defmodule Ledger do\nend\n")
    git!(wt.path, ["add", "-A"])
    git!(wt.path, ["commit", "-q", "-m", "clean commit"])

    File.write!(Path.join(wt.path, ".gitignore"), ".speckit_logs/\n")
    File.mkdir_p!(Path.join(wt.path, ".speckit_logs"))
    File.write!(Path.join(wt.path, ".speckit_logs/01-specify.md"), "transcript\n")
    git!(wt.path, ["add", ".gitignore"])
    git!(wt.path, ["commit", "-q", "-m", "gitignore"])

    File.write!(Path.join(wt.path, "lib/partial.ex"), "defmodule Partial do\nend\n")

    assert :ok = Worktree.restore(wt)

    refute File.exists?(Path.join(wt.path, "lib/partial.ex"))
    assert File.exists?(Path.join(wt.path, "lib/ledger.ex"))
    assert File.exists?(Path.join(wt.path, ".speckit_logs/01-specify.md"))
  end

  test "push/2 sends the feature branch to the configured remote" do
    repo = base_repo()
    {:ok, wt} = Worktree.create(feature(), with_root(repo))

    # A bare repo acts as the remote; register it as `origin`.
    remote_dir = Path.join(System.tmp_dir!(), "wt_remote_#{System.unique_integer([:positive])}")
    File.mkdir_p!(remote_dir)
    git!(remote_dir, ["init", "-q", "--bare"])
    on_exit(fn -> File.rm_rf(remote_dir) end)
    git!(repo, ["remote", "add", "origin", remote_dir])

    File.mkdir_p!(Path.join(wt.path, "lib"))
    File.write!(Path.join(wt.path, "lib/x.ex"), "defmodule X do\nend\n")
    Worktree.commit(wt, "work")

    assert :ok = Worktree.push(wt, "origin")

    # The branch now exists on the remote at the worktree's commit.
    {remote_ref, 0} = System.cmd("git", ["-C", remote_dir, "rev-parse", wt.branch])
    {local_ref, 0} = System.cmd("git", ["-C", repo, "rev-parse", wt.branch])
    assert String.trim(remote_ref) == String.trim(local_ref)
  end
end
