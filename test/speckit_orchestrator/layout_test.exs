defmodule SpeckitOrchestrator.LayoutTest do
  # async: false — mutates the global :autonomous_root/:specs_root app env.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Layout

  setup do
    root = Path.join(System.tmp_dir!(), "layout_#{System.unique_integer([:positive])}")
    prev_autonomous = Application.get_env(:speckit_orchestrator, :autonomous_root)
    prev_specs = Application.get_env(:speckit_orchestrator, :specs_root)
    Application.put_env(:speckit_orchestrator, :autonomous_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev_autonomous,
        do: Application.put_env(:speckit_orchestrator, :autonomous_root, prev_autonomous),
        else: Application.delete_env(:speckit_orchestrator, :autonomous_root)

      if prev_specs,
        do: Application.put_env(:speckit_orchestrator, :specs_root, prev_specs),
        else: Application.delete_env(:speckit_orchestrator, :specs_root)
    end)

    repo = Path.join(System.tmp_dir!(), "layout_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)

    %{root: root, repo: repo}
  end

  describe "build/3 — breakdown scope" do
    test "resolves all four roots as pure path joins", %{root: root, repo: repo} do
      assert {:ok, layout} = Layout.build(repo, "ledgerlite-abc123", {:breakdown, "core"})

      assert layout.worktree_root == Path.join([root, "worktrees", "ledgerlite-abc123"])

      assert layout.transcript_root ==
               Path.join([root, "transcripts", "ledgerlite-abc123", "core"])

      assert layout.breakdown_root == Path.join(repo, "specs/autonomous/breakdown/core")
      assert layout.ad_hoc_root == nil
      assert Layout.in_repo_rel(layout) == "specs/autonomous/breakdown/core"
    end

    test "rejects the reserved 'ad-hoc' breakdown slug", %{repo: repo} do
      assert {:error, {:reserved_slug, "ad-hoc"}} =
               Layout.build(repo, "ledgerlite-abc123", {:breakdown, "ad-hoc"})
    end
  end

  describe "build/3 — ad-hoc scope" do
    test "resolves all four roots, breakdown_root nil", %{root: root, repo: repo} do
      assert {:ok, layout} = Layout.build(repo, "ledgerlite-abc123", :ad_hoc)

      assert layout.worktree_root == Path.join([root, "worktrees", "ledgerlite-abc123"])

      assert layout.transcript_root ==
               Path.join([root, "transcripts", "ledgerlite-abc123", "ad-hoc"])

      assert layout.breakdown_root == nil
      assert layout.ad_hoc_root == Path.join(repo, "specs/autonomous/ad-hoc")
      assert Layout.in_repo_rel(layout) == "specs/autonomous/ad-hoc"
    end
  end

  describe "in_repo_rel/1 — bare scope" do
    test "accepts a bare scope value without a built Layout" do
      assert Layout.in_repo_rel({:breakdown, "core"}) == "specs/autonomous/breakdown/core"
      assert Layout.in_repo_rel(:ad_hoc) == "specs/autonomous/ad-hoc"
    end
  end

  describe "ensure/1" do
    test "creates every missing root", %{repo: repo} do
      assert {:ok, layout} = Layout.build(repo, "ledgerlite-abc123", {:breakdown, "core"})
      assert :ok = Layout.ensure(layout)

      assert File.dir?(layout.worktree_root)
      assert File.dir?(layout.transcript_root)
    end

    test "fails loud when a root cannot be created", %{repo: repo} do
      assert {:ok, layout} = Layout.build(repo, "ledgerlite-abc123", {:breakdown, "core"})

      # Make the parent of worktree_root a regular file, so mkdir_p under it fails.
      blocker = Path.dirname(layout.worktree_root)
      File.mkdir_p!(Path.dirname(blocker))
      File.write!(blocker, "not a directory")

      assert {:error, {:mkdir, _path, _reason}} = Layout.ensure(layout)
    end
  end
end
