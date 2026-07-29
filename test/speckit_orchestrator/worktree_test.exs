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

  defp feature,
    do: %Feature{id: "001", number: 1, slug: "core-ledger", path: "001-core-ledger.md"}

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

  describe "merged?/4 — is this branch still a legitimate base?" do
    test "false for an unmerged branch, true once it lands in the base" do
      repo = base_repo()
      {:ok, wt} = Worktree.create(feature(), with_root(repo))

      File.write!(Path.join(wt.path, "work.txt"), "work\n")
      Worktree.commit(wt, "feature work")

      refute Worktree.merged?(repo, wt.branch, "main")

      git!(repo, ["merge", "--no-ff", "-m", "merge feature", wt.branch])

      assert Worktree.merged?(repo, wt.branch, "main")
    end

    test "true for a branch that no longer exists — deleted after its PR landed" do
      repo = base_repo()
      assert Worktree.merged?(repo, "feature/999-long-gone", "main")
    end

    test "prefers the remote-tracking base, since the local one lags what actually merged" do
      repo = base_repo()
      {:ok, wt} = Worktree.create(feature(), with_root(repo))
      File.write!(Path.join(wt.path, "work.txt"), "work\n")
      Worktree.commit(wt, "feature work")

      remote_dir = Path.join(System.tmp_dir!(), "wt_remote_#{System.unique_integer([:positive])}")
      File.mkdir_p!(remote_dir)
      git!(remote_dir, ["init", "-q", "--bare"])
      on_exit(fn -> File.rm_rf(remote_dir) end)
      git!(repo, ["remote", "add", "origin", remote_dir])
      git!(repo, ["push", "-q", "origin", "main"])

      # The merge happens upstream only — local `main` never sees it, which is
      # the normal state after someone merges the PR on the forge.
      clone = Path.join(System.tmp_dir!(), "wt_clone_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(clone) end)
      {_, 0} = System.cmd("git", ["clone", "-q", remote_dir, clone])
      git!(clone, ["config", "user.email", "m@example.test"])
      git!(clone, ["config", "user.name", "Merger"])
      git!(repo, ["push", "-q", "origin", wt.branch])
      git!(clone, ["fetch", "-q", "origin", wt.branch])
      git!(clone, ["merge", "--no-ff", "-m", "merge feature", "FETCH_HEAD"])
      git!(clone, ["push", "-q", "origin", "main"])

      git!(repo, ["fetch", "-q", "origin"])

      # Local main still has no idea, so an unqualified check says unmerged...
      refute Worktree.merged?(repo, wt.branch, "main")
      # ...but against origin/main it is plainly merged, and that is the truth
      # a PR base has to respect.
      assert Worktree.merged?(repo, wt.branch, "main", remote: "origin")
    end

    test "falls back to the local base when the remote-tracking ref is absent" do
      repo = base_repo()
      {:ok, wt} = Worktree.create(feature(), with_root(repo))
      File.write!(Path.join(wt.path, "work.txt"), "work\n")
      Worktree.commit(wt, "feature work")

      refute Worktree.merged?(repo, wt.branch, "main", remote: "nonexistent")
    end
  end

  test "push/2 replaces a previous run's diverged branch instead of failing non-fast-forward" do
    repo = base_repo()
    root = with_root(repo)

    remote_dir = Path.join(System.tmp_dir!(), "wt_remote_#{System.unique_integer([:positive])}")
    File.mkdir_p!(remote_dir)
    git!(remote_dir, ["init", "-q", "--bare"])
    on_exit(fn -> File.rm_rf(remote_dir) end)
    git!(repo, ["remote", "add", "origin", remote_dir])

    # Run one: build the feature branch and publish it.
    {:ok, first} = Worktree.create(feature(), root)
    File.write!(Path.join(first.path, "v1.txt"), "one\n")
    Worktree.commit(first, "run one")
    assert :ok = Worktree.push(first, "origin")
    {stale, 0} = System.cmd("git", ["-C", remote_dir, "rev-parse", first.branch])

    # Run two rebuilds the same feature from base — a different history for the
    # same branch name, which is exactly what a plain push rejects.
    Worktree.remove(first)
    git!(repo, ["branch", "-D", first.branch])
    {:ok, second} = Worktree.create(feature(), root)
    File.write!(Path.join(second.path, "v2.txt"), "two\n")
    Worktree.commit(second, "run two")

    assert :ok = Worktree.push(second, "origin")

    {remote_ref, 0} = System.cmd("git", ["-C", remote_dir, "rev-parse", second.branch])
    {local_ref, 0} = System.cmd("git", ["-C", repo, "rev-parse", second.branch])
    assert String.trim(remote_ref) == String.trim(local_ref)
    refute String.trim(remote_ref) == String.trim(stale)
  end

  test "push/2 refuses when the remote branch moved outside this repo — a human's commit is never overwritten" do
    repo = base_repo()
    root = with_root(repo)

    remote_dir = Path.join(System.tmp_dir!(), "wt_remote_#{System.unique_integer([:positive])}")
    File.mkdir_p!(remote_dir)
    git!(remote_dir, ["init", "-q", "--bare"])
    on_exit(fn -> File.rm_rf(remote_dir) end)
    git!(repo, ["remote", "add", "origin", remote_dir])

    {:ok, wt} = Worktree.create(feature(), root)
    File.write!(Path.join(wt.path, "v1.txt"), "one\n")
    Worktree.commit(wt, "orchestrator work")
    assert :ok = Worktree.push(wt, "origin")

    # Someone else pushes to the same branch from a separate clone — a review
    # fixup landed directly on the feature branch.
    clone = Path.join(System.tmp_dir!(), "wt_clone_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(clone) end)
    {_, 0} = System.cmd("git", ["clone", "-q", "--branch", wt.branch, remote_dir, clone])
    git!(clone, ["config", "user.email", "human@example.test"])
    git!(clone, ["config", "user.name", "Human"])
    File.write!(Path.join(clone, "review-fixup.txt"), "fix\n")
    git!(clone, ["add", "-A"])
    git!(clone, ["commit", "-q", "-m", "review fixup"])
    git!(clone, ["push", "-q", "origin", wt.branch])
    {human_ref, 0} = System.cmd("git", ["-C", remote_dir, "rev-parse", wt.branch])

    # The orchestrator rebuilds the branch and tries to publish over it.
    Worktree.remove(wt)
    git!(repo, ["branch", "-D", wt.branch])
    {:ok, rebuilt} = Worktree.create(feature(), root)
    File.write!(Path.join(rebuilt.path, "v2.txt"), "two\n")
    Worktree.commit(rebuilt, "orchestrator rebuild")

    assert {:error, {:remote_branch_moved, branch, _sha}} = Worktree.push(rebuilt, "origin")
    assert branch == rebuilt.branch

    # The human's commit is still the remote tip.
    {after_ref, 0} = System.cmd("git", ["-C", remote_dir, "rev-parse", wt.branch])
    assert String.trim(after_ref) == String.trim(human_ref)
  end
end
