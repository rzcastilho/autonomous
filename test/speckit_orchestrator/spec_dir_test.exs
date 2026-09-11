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

  # A feature whose wave-local `id` and repo-monotonic `spec_number` differ —
  # every candidate must be composed from `spec_number`, never `id`, once one
  # is allocated (feature 022, `Feature.spec_id/1` semantics).
  defp feat_spec(id, slug, spec_number), do: %{id: id, slug: slug, spec_number: spec_number}

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
      # specs/002-categories exists and is empty; the CLI recorded the dir
      # that actually holds the file. (Feature 022 net one: a *second*
      # candidate reached only via the prefix wildcard, with no recorded
      # pointer, is FR-010 ambiguity — see the "candidates constrained to
      # spec_id" describe block below — so this case goes through candidate 2.)
      dir = worktree(dirs: ["specs/002-categories"], files: [], recorded: "specs/002-alt")
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

  # Feature 022 net one (FR-009/FR-010, contracts/spec-dir-resolution.md §2-3):
  # every candidate is constrained to the feature's own `spec_id` — `id` when
  # unallocated, `spec_number` (zero-padded) once one is. These reproduce the
  # contract's §3 behaviour table directly, on a worktree carrying a completed
  # `specs/001-core-ledger/` (from a wave numbered `001`) plus this feature's
  # own directory named by its *allocated* spec number `015`.
  describe "candidates constrained to spec_id (feature 022 net one)" do
    test "candidate 1 is composed from spec_number, not the wave-local id" do
      dir = worktree(dirs: ["specs/015-billing"])

      assert SpecDir.file(dir, feat_spec("001", "billing", 15), "tasks.md") ==
               Path.join(dir, "specs/015-billing/tasks.md")
    end

    test "candidate 2 (recorded dir) is accepted when its numeric prefix equals spec_id" do
      # specs/015-billing exists but is empty; the CLI recorded a differently
      # slugged directory that also starts with the allocated spec number.
      dir = worktree(dirs: ["specs/015-billing"], files: [], recorded: "specs/015-billing-2")
      File.mkdir_p!(Path.join(dir, "specs/015-billing-2"))
      File.write!(Path.join(dir, "specs/015-billing-2/tasks.md"), "# tasks\n")

      assert SpecDir.file(dir, feat_spec("001", "billing", 15), "tasks.md") ==
               Path.join(dir, "specs/015-billing-2/tasks.md")
    end

    test "candidate 2 is rejected when its numeric prefix does not equal spec_id" do
      # The recorded dir is the inherited feature's own — a stacked worktree's
      # live leak this feature exists to close (contract §2, "closes a live
      # leak").
      dir = worktree(dirs: [], recorded: "specs/001-core-ledger")

      assert SpecDir.file(dir, feat_spec("001", "billing", 15), "tasks.md") == nil
    end

    test "candidate 3 requires exactly one prefix match — two contribute nothing" do
      # Neither directory is the exact spec_id-slug name, so candidate 1
      # never matches; both share the "015-" prefix, so candidate 3 is
      # ambiguous per FR-010 and must not be settled by ordering.
      dir = worktree(dirs: ["specs/015-billing", "specs/015-billing-alt"], files: ["tasks.md"])

      assert SpecDir.file(dir, feat_spec("001", "notbilling", 15), "tasks.md") == nil
    end

    test "candidate 3 resolves on a single unambiguous prefix match" do
      dir = worktree(dirs: ["specs/015-something-else"])

      assert SpecDir.file(dir, feat_spec("001", "billing", 15), "tasks.md") ==
               Path.join(dir, "specs/015-something-else/tasks.md")
    end

    test "never falls through to the inherited feature's directory across a spec_id mismatch" do
      dir = worktree(dirs: [])

      assert SpecDir.file(dir, feat_spec("001", "billing", 15), "plan.md") == nil
      assert File.regular?(Path.join(dir, "specs/001-core-ledger/plan.md"))
    end
  end
end
