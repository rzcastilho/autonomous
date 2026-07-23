defmodule SpeckitOrchestrator.RunDirectoryLayoutTest do
  # async: false — mutates the global :autonomous_root/:repo app env.
  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.{Backlog, Layout, RepoIdentity, Worktree}

  @moduletag :integration

  @packages_fixture Path.expand("../fixtures/breakdown_packages", __DIR__)

  setup do
    autonomous_root =
      Path.join(System.tmp_dir!(), "run_dir_layout_#{System.unique_integer([:positive])}")

    prev_autonomous = Application.get_env(:speckit_orchestrator, :autonomous_root)
    prev_repo = Application.get_env(:speckit_orchestrator, :repo)
    Application.put_env(:speckit_orchestrator, :autonomous_root, autonomous_root)

    on_exit(fn ->
      File.rm_rf(autonomous_root)

      if prev_autonomous,
        do: Application.put_env(:speckit_orchestrator, :autonomous_root, prev_autonomous),
        else: Application.delete_env(:speckit_orchestrator, :autonomous_root)

      if prev_repo,
        do: Application.put_env(:speckit_orchestrator, :repo, prev_repo),
        else: Application.delete_env(:speckit_orchestrator, :repo)
    end)

    %{autonomous_root: autonomous_root}
  end

  defp init_repo!(origin_url) do
    dir = Path.join(System.tmp_dir!(), "run_dir_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["init", "-q", dir])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", origin_url])
    dir
  end

  # A repo carrying both fixture breakdown packages (alpha/beta, T021) under
  # specs/autonomous/breakdown/, committed content per the data-model grammar.
  defp init_repo_with_packages! do
    repo = init_repo!("git@github.com:rzcastilho/packages-demo.git")
    dest = Path.join(repo, "specs/autonomous/breakdown")
    File.mkdir_p!(dest)
    File.cp_r!(@packages_fixture, dest)
    repo
  end

  test "two repos with different origins resolve worktree/transcript roots sharing no common subpath" do
    repo_a = init_repo!("git@github.com:rzcastilho/ledgerlite.git")
    repo_b = init_repo!("git@github.com:rzcastilho/other-target.git")
    on_exit(fn -> File.rm_rf(repo_a) end)
    on_exit(fn -> File.rm_rf(repo_b) end)

    {:ok, segment_a} = RepoIdentity.resolve(repo_a)
    {:ok, segment_b} = RepoIdentity.resolve(repo_b)
    assert segment_a != segment_b

    {:ok, layout_a} = Layout.build(repo_a, segment_a, {:breakdown, "core"})
    {:ok, layout_b} = Layout.build(repo_b, segment_b, {:breakdown, "core"})

    refute layout_a.worktree_root == layout_b.worktree_root
    refute layout_b.worktree_root =~ layout_a.worktree_root
    refute layout_a.worktree_root =~ layout_b.worktree_root

    refute layout_a.transcript_root == layout_b.transcript_root
    refute layout_b.transcript_root =~ layout_a.transcript_root
    refute layout_a.transcript_root =~ layout_b.transcript_root
  end

  test "Worktree.create/2 resolves under the given Layout's worktree_root" do
    repo = init_repo!("git@github.com:rzcastilho/ledgerlite.git")
    on_exit(fn -> File.rm_rf(repo) end)

    {_, 0} = System.cmd("git", ["-C", repo, "commit", "--allow-empty", "-q", "-m", "init"])
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.keep"), "")
    File.write!(Path.join(repo, ".claude/settings.json"), "{}")
    File.mkdir_p!(Path.join(repo, ".specify"))
    File.write!(Path.join(repo, ".specify/.keep"), "")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "scaffold"])

    {:ok, segment} = RepoIdentity.resolve(repo)
    {:ok, layout} = Layout.build(repo, segment, {:breakdown, "core"})

    feature = %SpeckitOrchestrator.Feature{id: "001", slug: "demo", path: "001-demo.md"}

    assert {:ok, worktree} =
             Worktree.create(feature, repo: repo, worktree_root: layout.worktree_root)

    assert String.starts_with?(worktree.path, layout.worktree_root)
    Worktree.remove(worktree)
  end

  test "SpeckitOrchestrator.run/1 against a repo with no origin remote refuses at preflight, creating no worktree/transcript directory",
       %{autonomous_root: autonomous_root} do
    dir = Path.join(System.tmp_dir!(), "run_dir_no_origin_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {_, 0} = System.cmd("git", ["init", "-q", dir])

    Application.put_env(:speckit_orchestrator, :repo, dir)

    assert {:error, {:preflight, problems}} = SpeckitOrchestrator.run(features: [])
    assert Enum.any?(problems, &match?({:no_origin, _}, &1))

    refute File.dir?(Path.join(autonomous_root, "worktrees"))
    refute File.dir?(Path.join(autonomous_root, "transcripts"))
  end

  # ---- US2: breakdown package organization (T022, SC-002) --------------------

  test "packages alpha and beta (both containing feature 001) resolve their feature files and transcripts under distinct slug segments with 0 overwrites" do
    repo = init_repo_with_packages!()
    on_exit(fn -> File.rm_rf(repo) end)

    {:ok, segment} = RepoIdentity.resolve(repo)

    {:ok, layout_alpha} = Layout.build(repo, segment, {:breakdown, "alpha"})
    {:ok, layout_beta} = Layout.build(repo, segment, {:breakdown, "beta"})

    refute layout_alpha.breakdown_root == layout_beta.breakdown_root
    refute layout_alpha.transcript_root == layout_beta.transcript_root

    # Each package's own feature 001 loads under its own slug, with distinct
    # content (SC-002: overlapping ids never collide).
    assert [%{id: "001", slug: "widget"}] = Backlog.load!(layout_alpha.breakdown_root)
    assert [%{id: "001", slug: "gadget"}] = Backlog.load!(layout_beta.breakdown_root)

    :ok = Layout.ensure(layout_alpha)
    :ok = Layout.ensure(layout_beta)

    alpha_dir = Path.join(layout_alpha.transcript_root, "001")
    beta_dir = Path.join(layout_beta.transcript_root, "001")
    File.mkdir_p!(alpha_dir)
    File.mkdir_p!(beta_dir)
    File.write!(Path.join(alpha_dir, "01-specify.md"), "alpha content")
    File.write!(Path.join(beta_dir, "01-specify.md"), "beta content")

    # 0 overwrites — each package's feature-001 transcript keeps its own content.
    assert File.read!(Path.join(alpha_dir, "01-specify.md")) == "alpha content"
    assert File.read!(Path.join(beta_dir, "01-specify.md")) == "beta content"
  end

  # ---- US3: ad-hoc separation (T027, SC-003) ----------------------------------

  test "an ad-hoc run and a breakdown run in the same repo resolve to distinct locations — the ad-hoc feature never lands under any breakdown package dir" do
    repo = init_repo_with_packages!()
    on_exit(fn -> File.rm_rf(repo) end)

    {:ok, segment} = RepoIdentity.resolve(repo)

    {:ok, breakdown_layout} = Layout.build(repo, segment, {:breakdown, "alpha"})
    {:ok, ad_hoc_layout} = Layout.build(repo, segment, :ad_hoc)

    # Feature-file location: ad-hoc's dedicated dir, never under a breakdown
    # package.
    assert String.ends_with?(ad_hoc_layout.ad_hoc_root, "specs/autonomous/ad-hoc")
    refute ad_hoc_layout.ad_hoc_root == breakdown_layout.breakdown_root
    refute String.starts_with?(ad_hoc_layout.ad_hoc_root, breakdown_layout.breakdown_root)

    # The ad-hoc seed write is worktree-relative (resolves I1, T023) — never
    # the base-repo-absolute ad_hoc_root.
    worktree_path = Path.join(System.tmp_dir!(), "run_dir_wt_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(worktree_path) end)
    seed_path = Path.join([worktree_path, Layout.in_repo_rel(ad_hoc_layout), "001-widget.md"])
    File.mkdir_p!(Path.dirname(seed_path))
    File.write!(seed_path, "ad-hoc seed content")

    assert File.exists?(seed_path)
    # the ad-hoc seed never lands in the breakdown package's own directory —
    # they resolve to entirely separate subtrees.
    refute String.starts_with?(seed_path, breakdown_layout.breakdown_root)
    refute ad_hoc_layout.ad_hoc_root == breakdown_layout.breakdown_root

    # Transcript location: distinct scope segments (ad-hoc vs the breakdown
    # slug), even for the same feature id.
    refute ad_hoc_layout.transcript_root == breakdown_layout.transcript_root
    assert String.ends_with?(ad_hoc_layout.transcript_root, "/ad-hoc")
    assert String.ends_with?(breakdown_layout.transcript_root, "/alpha")
  end

  # ---- US3: reserved "ad-hoc" package name (T028, FR-010) ---------------------

  test "SpeckitOrchestrator.run/1 selecting a breakdown package literally named 'ad-hoc' is refused at preflight, before any Backlog load" do
    repo = init_repo!("git@github.com:rzcastilho/ledgerlite.git")
    on_exit(fn -> File.rm_rf(repo) end)

    Application.put_env(:speckit_orchestrator, :repo, repo)

    assert {:error, {:preflight, problems}} = SpeckitOrchestrator.run(slug: "ad-hoc")
    assert Enum.any?(problems, &match?({:reserved_slug, "ad-hoc"}, &1))
  end
end
