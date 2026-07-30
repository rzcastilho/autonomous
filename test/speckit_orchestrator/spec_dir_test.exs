defmodule SpeckitOrchestrator.SpecDirTest do
  @moduledoc """
  A stacked worktree carries every earlier feature's `specs/` directory, so
  "resolve the current feature's spec dir" is the precondition for every gate
  that reads a file. These cases pin the resolution order and, more importantly,
  that nothing ever falls through to another feature's directory.
  """
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.SpecDir

  defp worktree(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "spec_dir_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)

    # The inherited feature: finished long ago, sorts first, has every file.
    File.mkdir_p!(Path.join(dir, "specs/001-core-ledger"))
    File.write!(Path.join(dir, "specs/001-core-ledger/spec.md"), "# 001\n")
    File.write!(Path.join(dir, "specs/001-core-ledger/plan.md"), "# 001 plan\n")
    File.write!(Path.join(dir, "specs/001-core-ledger/tasks.md"), "- [x] T001 done\n")

    Enum.each(Keyword.get(opts, :dirs, ["specs/002-categories"]), fn own ->
      File.mkdir_p!(Path.join(dir, own))

      Enum.each(Keyword.get(opts, :files, ["spec.md", "plan.md", "tasks.md"]), fn leaf ->
        File.write!(Path.join([dir, own, leaf]), "# 002 #{leaf}\n")
      end)
    end)

    if recorded = Keyword.get(opts, :recorded) do
      File.mkdir_p!(Path.join(dir, ".specify"))

      File.write!(
        Path.join(dir, ".specify/feature.json"),
        JSON.encode!(%{feature_directory: recorded})
      )
    end

    dir
  end

  defp feat(id \\ "002", slug \\ "categories"), do: %{id: id, slug: slug}

  describe "resolve/2" do
    test "prefers specs/<id>-<slug> over anything else present" do
      dir = worktree(recorded: "specs/001-core-ledger")

      assert SpecDir.resolve(dir, feat()) == Path.join(dir, "specs/002-categories")
    end

    test "falls back to the dir the Spec Kit CLI recorded when the slug drifted" do
      dir = worktree(dirs: ["specs/002-categorise"], recorded: "specs/002-categorise")

      assert SpecDir.resolve(dir, feat()) == Path.join(dir, "specs/002-categorise")
    end

    test "falls back to the id prefix with neither an exact slug nor a recorded dir" do
      dir = worktree(dirs: ["specs/002-something-else"])

      assert SpecDir.resolve(dir, feat()) == Path.join(dir, "specs/002-something-else")
    end

    test "nil rather than an inherited feature's dir when this feature has none" do
      dir = worktree(dirs: [])

      assert SpecDir.resolve(dir, feat()) == nil
    end

    test "ignores a recorded dir escaping the worktree, absolute or via .." do
      for escape <- ["../elsewhere", "/etc"] do
        dir = worktree(dirs: [], recorded: escape)
        assert SpecDir.resolve(dir, feat()) == nil
      end
    end

    test "nil for a missing worktree, a nil worktree, or a nil feature" do
      assert SpecDir.resolve("/nonexistent/nowhere", feat()) == nil
      assert SpecDir.resolve(nil, feat()) == nil
      assert SpecDir.resolve(worktree(), nil) == nil
    end
  end

  describe "file/3" do
    test "resolves the leaf inside this feature's dir, never the inherited one" do
      dir = worktree()

      assert SpecDir.file(dir, feat(), "tasks.md") ==
               Path.join(dir, "specs/002-categories/tasks.md")
    end

    test "skips a candidate dir that exists but lacks the file" do
      # specs/002-categories exists and is empty; the recorded dir has the file.
      dir = worktree(dirs: ["specs/002-categories"], files: [])
      File.mkdir_p!(Path.join(dir, "specs/002-alt"))
      File.write!(Path.join(dir, "specs/002-alt/tasks.md"), "- [ ] T001\n")

      assert SpecDir.file(dir, feat(), "tasks.md") == Path.join(dir, "specs/002-alt/tasks.md")
    end

    test "nil rather than the inherited feature's file" do
      dir = worktree(dirs: [])

      assert SpecDir.file(dir, feat(), "plan.md") == nil
      # Proving the inherited copy really is there to be wrongly returned.
      assert File.regular?(Path.join(dir, "specs/001-core-ledger/plan.md"))
    end

    test "resolves the first feature's own files when it is the one being built" do
      dir = worktree()

      assert SpecDir.file(dir, feat("001", "core-ledger"), "plan.md") ==
               Path.join(dir, "specs/001-core-ledger/plan.md")
    end
  end
end
