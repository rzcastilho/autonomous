defmodule Autonomous.TargetPackTest do
  use ExUnit.Case, async: true

  alias Autonomous.TargetPack

  defp tmp_repo do
    dir = Path.join(System.tmp_dir!(), "tp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  test "install/2 lays down local settings, the contract-6 marker, and template constitution" do
    repo = tmp_repo()
    assert {:ok, summary} = TargetPack.install(repo)
    refute summary.constitution_skipped
    refute summary.stale_hook_removed
    assert summary.settings
    assert summary.marker

    # 044: the pack settings land in settings.local.json — settings.json is never written.
    refute File.exists?(Path.join(repo, ".claude/settings.json"))
    assert File.regular?(Path.join(repo, ".claude/settings.local.json"))

    assert Jason.decode!(File.read!(Path.join(repo, ".claude/autonomous-pack.json"))) ==
             %{"contract" => 6}

    refute File.exists?(Path.join(repo, ".claude/hooks"))
    settings = Jason.decode!(File.read!(Path.join(repo, ".claude/settings.local.json")))
    refute Map.has_key?(settings, "hooks")
    refute Map.has_key?(settings["permissions"], "deny")

    assert File.read!(Path.join(repo, ".specify/memory/constitution.md")) =~
             "AUTONOMOUS_TEMPLATE"
  end

  test "install/2 never clobbers an existing constitution" do
    repo = tmp_repo()
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Real constitution\n")

    assert {:ok, summary} = TargetPack.install(repo)
    assert summary.constitution_skipped

    assert File.read!(Path.join(repo, ".specify/memory/constitution.md")) ==
             "# Real constitution\n"
  end

  test "verify/1 fails while the template constitution is in place" do
    repo = tmp_repo()
    {:ok, _} = TargetPack.install(repo)
    assert {:error, problems} = TargetPack.verify(repo, check_git: false)
    assert Enum.any?(problems, &match?({:default_constitution, _}, &1))
  end

  test "verify/1 passes for a customized, committed target repo" do
    repo = tmp_repo()
    {:ok, _} = TargetPack.install(repo)
    File.rm!(Path.join(repo, ".claude/settings.local.json"))
    File.rm!(Path.join(repo, ".claude/autonomous-pack.json"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Real\n\n1. cents only.\n")

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "pack"])

    assert :ok = TargetPack.verify(repo)
  end

  test "verify/1 reports an uncommitted constitution when git-checking" do
    repo = tmp_repo()
    {:ok, _} = TargetPack.install(repo)
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Real\n\n1. cents.\n")
    git!(repo, ["init", "-q", "-b", "main"])

    assert {:error, problems} = TargetPack.verify(repo)
    assert Enum.any?(problems, &match?({:uncommitted, _}, &1))
  end

  test "verify/1 reports missing scaffold on a bare repo" do
    repo = tmp_repo()
    assert {:error, problems} = TargetPack.verify(repo, check_git: false)
    assert Enum.any?(problems, &match?({:missing, ".claude/skills"}, &1))
    refute Enum.any?(problems, &match?({:missing, ".claude/settings.json"}, &1))
  end

  # A target that commits a *current* pack: the marker + the pack's settings.json.
  defp committed_target do
    repo = tmp_repo()
    {:ok, _} = TargetPack.install(repo)

    File.rename!(
      Path.join(repo, ".claude/settings.local.json"),
      Path.join(repo, ".claude/settings.json")
    )

    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Real\n\n1. cents.\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "pack"])
    repo
  end

  test "verify(check_remote: true) fails when the target has no remote" do
    repo = committed_target()
    assert {:error, problems} = TargetPack.verify(repo, check_remote: true)
    assert Enum.any?(problems, &match?({:no_remote, "origin"}, &1))
  end

  test "verify(check_remote: true) passes once origin is configured" do
    repo = committed_target()
    remote = Path.join(System.tmp_dir!(), "tp_remote_#{System.unique_integer([:positive])}")
    File.mkdir_p!(remote)
    git!(remote, ["init", "-q", "--bare"])
    on_exit(fn -> File.rm_rf(remote) end)
    git!(repo, ["remote", "add", "origin", remote])

    assert :ok = TargetPack.verify(repo, check_remote: true)
  end

  test "verify(check_remote: <name>) checks a named remote" do
    repo = committed_target()
    assert {:error, problems} = TargetPack.verify(repo, check_remote: "upstream")
    assert Enum.any?(problems, &match?({:no_remote, "upstream"}, &1))
  end

  # A target still carrying the pre-039 (contract 5) pack: the scope_guard hook
  # file, its PreToolUse registration, and no autonomous-pack.json marker.
  defp downgrade_to_contract_5(repo) do
    File.write!(Path.join(repo, ".claude/autonomous-pack.json"), ~s({"contract": 5}))
    File.mkdir_p!(Path.join(repo, ".claude/hooks"))
    File.write!(Path.join(repo, ".claude/hooks/scope_guard.py"), "PACK_CONTRACT = 5\n")

    settings = Path.join(repo, ".claude/settings.json")

    old =
      settings
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("hooks", %{
        "PreToolUse" => [
          %{
            "matcher" => "Write|Edit|Bash",
            "hooks" => [
              %{
                "type" => "command",
                "command" => ~s(python3 "$CLAUDE_PROJECT_DIR/.claude/hooks/scope_guard.py")
              }
            ]
          }
        ]
      })

    File.write!(settings, Jason.encode!(old))
  end

  defp commit_all(repo, msg) do
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", msg])
  end

  defp wrap({:error, reason}), do: {:error, [reason]}

  defp assert_outdated(result, path) do
    assert {:error, problems} = result

    assert [{:pack_outdated, ^path, hint}] =
             Enum.filter(problems, &match?({:pack_outdated, _, _}, &1))

    assert hint =~ "contract 6"
    assert hint =~ "update the tracked file"
    assert hint =~ "git rm --cached"
  end

  describe "pack contract 6 (039) — checked on every run" do
    test "a freshly installed, committed pack passes" do
      repo = committed_target()
      assert :ok = TargetPack.verify(repo)
      assert :ok = TargetPack.check_pack_contract(repo)
    end

    test "verify/2 has no :profile option any more — passing one raises" do
      repo = committed_target()
      assert_raise ArgumentError, fn -> TargetPack.verify(repo, profile: "strict") end
    end

    test "an old (contract 5) committed pack is refused, naming the missing marker" do
      repo = committed_target()
      downgrade_to_contract_5(repo)
      commit_all(repo, "contract 5 pack")

      assert_outdated(TargetPack.verify(repo), ".claude/autonomous-pack.json")
    end

    test "a marker below contract 6 is refused" do
      repo = committed_target()
      File.write!(Path.join(repo, ".claude/autonomous-pack.json"), ~s({"contract": 5}))
      commit_all(repo, "marker 5")

      assert_outdated(TargetPack.verify(repo), ".claude/autonomous-pack.json")
    end

    test "a registered scope_guard hook in settings.json is refused" do
      repo = committed_target()
      downgrade_to_contract_5(repo)
      File.rm_rf!(Path.join(repo, ".claude/hooks"))
      File.write!(Path.join(repo, ".claude/autonomous-pack.json"), ~s({"contract": 6}))
      commit_all(repo, "stale registration only")

      assert_outdated(TargetPack.verify(repo), ".claude/settings.json")
    end

    test "a permissions.deny list in settings.json is refused" do
      repo = committed_target()
      settings = Path.join(repo, ".claude/settings.json")

      File.write!(
        settings,
        settings
        |> File.read!()
        |> Jason.decode!()
        |> put_in(["permissions", "deny"], ["Bash"])
        |> Jason.encode!()
      )

      commit_all(repo, "deny list")

      assert_outdated(TargetPack.verify(repo), ".claude/settings.json")
    end

    test "a committed scope_guard.py file is refused" do
      repo = committed_target()
      File.mkdir_p!(Path.join(repo, ".claude/hooks"))
      File.write!(Path.join(repo, ".claude/hooks/scope_guard.py"), "x\n")
      commit_all(repo, "stale hook file")

      assert_outdated(TargetPack.verify(repo), ".claude/hooks/scope_guard.py")
    end

    test "reads the committed tree: an uncommitted re-install still fails, committing fixes it" do
      repo = committed_target()
      File.write!(Path.join(repo, ".claude/autonomous-pack.json"), ~s({"contract": 5}))
      commit_all(repo, "contract 5 marker")

      assert {:ok, %{marker: true}} = TargetPack.install(repo)
      assert_outdated(TargetPack.verify(repo), ".claude/autonomous-pack.json")

      # the local settings install/2 wrote are never part of the committed pack
      File.rm!(Path.join(repo, ".claude/settings.local.json"))
      commit_all(repo, "reinstall marker")
      assert :ok = TargetPack.verify(repo)
    end

    test "install/2 removes the stale hook file and the empty hooks dir, but never edits settings.json" do
      repo = committed_target()
      downgrade_to_contract_5(repo)
      before = File.read!(Path.join(repo, ".claude/settings.json"))

      assert {:ok, %{stale_hook_removed: true}} = TargetPack.install(repo)
      refute File.exists?(Path.join(repo, ".claude/hooks"))
      # 044: settings.json is the target's — its stale registration stays, and stays refused.
      assert File.read!(Path.join(repo, ".claude/settings.json")) == before

      assert_outdated(
        TargetPack.check_pack_contract(repo, false) |> wrap(),
        ".claude/settings.json"
      )
    end

    test "install/2 keeps a hooks dir that holds other files" do
      repo = tmp_repo()
      File.mkdir_p!(Path.join(repo, ".claude/hooks"))
      File.write!(Path.join(repo, ".claude/hooks/scope_guard.py"), "x\n")
      File.write!(Path.join(repo, ".claude/hooks/mine.sh"), "echo\n")

      assert {:ok, %{stale_hook_removed: true}} = TargetPack.install(repo)
      refute File.exists?(Path.join(repo, ".claude/hooks/scope_guard.py"))
      assert File.exists?(Path.join(repo, ".claude/hooks/mine.sh"))
    end

    test "a second install is a no-op (same bytes)" do
      repo = tmp_repo()
      {:ok, _} = TargetPack.install(repo)
      files = ~w(.claude/settings.local.json .claude/autonomous-pack.json)
      before = Map.new(files, &{&1, File.read!(Path.join(repo, &1))})
      {:ok, summary} = TargetPack.install(repo)
      refute summary.stale_hook_removed
      refute summary.settings
      refute summary.marker
      assert Map.new(files, &{&1, File.read!(Path.join(repo, &1))}) == before
    end

    test "the agent-root pack warning is gone" do
      Code.ensure_loaded!(TargetPack)
      refute function_exported?(TargetPack, :agent_root_warning, 1)
      assert TargetPack.contract() == 6
    end
  end

  describe "local settings (044)" do
    defp pack_settings,
      do:
        Jason.decode!(
          File.read!(Path.join(:code.priv_dir(:autonomous), "target_pack/.claude/settings.json"))
        )

    defp write_settings(repo, content) do
      File.mkdir_p!(Path.join(repo, ".claude"))
      File.write!(Path.join(repo, ".claude/settings.json"), content)
    end

    defp read_local(repo), do: File.read!(Path.join(repo, ".claude/settings.local.json"))

    test "local_settings/2 with no tracked settings is the pack verbatim" do
      assert TargetPack.local_settings(pack_settings(), nil) == pack_settings()
    end

    test "local_settings/2 omits every env key the tracked settings set" do
      pack = %{"env" => %{"A" => "1", "B" => "2"}, "x" => 1}
      tracked = %{"env" => %{"B" => "9"}, "x" => 2, "y" => 3}

      assert TargetPack.local_settings(pack, tracked) == %{"env" => %{"A" => "1"}, "x" => 1}
    end

    test "local_settings/2 drops env entirely when nothing is left" do
      pack = %{"env" => %{"A" => "1"}, "permissions" => %{"defaultMode" => "acceptEdits"}}

      assert TargetPack.local_settings(pack, %{"env" => %{"A" => "7"}}) ==
               %{"permissions" => %{"defaultMode" => "acceptEdits"}}
    end

    test "local_settings/2 keeps non-env keys verbatim" do
      tracked = %{"permissions" => %{"defaultMode" => "plan", "deny" => ["Bash"]}}
      assert TargetPack.local_settings(pack_settings(), tracked) == pack_settings()
    end

    test "install/2 with no settings.json writes the pack as settings.local.json" do
      repo = tmp_repo()
      assert {:ok, _} = TargetPack.install(repo)
      assert Jason.decode!(read_local(repo)) == pack_settings()
    end

    test "install/2 leaves the tracked env winning and never touches settings.json" do
      repo = tmp_repo()
      src = ~s({"env": {"BASH_MAX_TIMEOUT_MS": "60000", "FOO": "bar"}})
      write_settings(repo, src)
      assert {:ok, _} = TargetPack.install(repo)

      assert File.read!(Path.join(repo, ".claude/settings.json")) == src
      env = Jason.decode!(read_local(repo))["env"]
      refute Map.has_key?(env, "BASH_MAX_TIMEOUT_MS")
      assert env["BASH_DEFAULT_TIMEOUT_MS"] == "1800000"
    end

    test "unparseable or non-object settings.json: error, nothing written" do
      for bad <- ["{not json", "[1, 2]", ~s("str")] do
        repo = tmp_repo()
        write_settings(repo, bad)

        assert {:error, {:invalid_settings, ".claude/settings.json"}} = TargetPack.install(repo)
        assert File.read!(Path.join(repo, ".claude/settings.json")) == bad
        refute File.exists?(Path.join(repo, ".claude/autonomous-pack.json"))
        refute File.exists?(Path.join(repo, ".claude/settings.local.json"))
        refute File.exists?(Path.join(repo, ".specify/memory/constitution.md"))
      end
    end
  end

  # ---- 044: supply, exclude, source, the three target states --------------

  # A committed target with a customized constitution and `.claude/skills`, and
  # no pack file of any kind (the US1 shape).
  defp packless_target do
    repo = tmp_repo()
    File.mkdir_p!(Path.join(repo, ".claude/skills"))
    File.write!(Path.join(repo, ".claude/skills/.gitkeep"), "")
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Real\n\n1. cents.\n")
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@e.com"])
    git!(repo, ["config", "user.name", "T"])
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "base"])
    repo
  end

  defp linked_worktree(repo) do
    wt = repo <> "_wt"
    git!(repo, ["worktree", "add", "-q", "-b", "feature/x", wt])
    on_exit(fn -> File.rm_rf(wt) end)
    wt
  end

  defp porcelain(dir) do
    {out, 0} = System.cmd("git", ["-C", dir, "status", "--porcelain"], stderr_to_stdout: true)
    out
  end

  describe "a target with no pack files (G1)" do
    test "verify/2 passes" do
      assert :ok = TargetPack.verify(packless_target())
    end

    test "FR-002 checks still fail when the constitution or skills are missing" do
      repo = tmp_repo()
      assert {:error, problems} = TargetPack.verify(repo, check_git: false)
      assert {:missing, ".claude/skills"} in problems
      assert {:missing, ".specify/memory/constitution.md"} in problems
    end

    test "source/1 reports supplied at contract 6" do
      assert {:ok, %{source: :supplied, contract: 6}} = TargetPack.source(packless_target())
    end
  end

  describe "supply/1 (G9, G2, G10)" do
    test "writes both files into the worktree, untracked, and excludes them" do
      repo = packless_target()
      wt = linked_worktree(repo)

      assert {:ok, %{source: :supplied, wrote: wrote, excluded: excluded}} = TargetPack.supply(wt)
      assert Enum.sort(wrote) == [".claude/autonomous-pack.json", ".claude/settings.local.json"]

      assert Enum.sort(excluded) == [
               "/.claude/autonomous-pack.json",
               "/.claude/settings.local.json"
             ]

      assert File.regular?(Path.join(wt, ".claude/autonomous-pack.json"))
      assert File.regular?(Path.join(wt, ".claude/settings.local.json"))
      assert porcelain(wt) == ""
      assert porcelain(repo) == ""
      # FR-016: the checkout never gains either file.
      refute File.exists?(Path.join(repo, ".claude/autonomous-pack.json"))
      refute File.exists?(Path.join(repo, ".claude/settings.local.json"))
    end

    test "a second supply writes and excludes nothing; the block is not duplicated" do
      repo = packless_target()
      wt = linked_worktree(repo)
      {:ok, _} = TargetPack.supply(wt)

      assert {:ok, %{wrote: [], excluded: []}} = TargetPack.supply(wt)

      exclude = File.read!(Path.join(repo, ".git/info/exclude"))
      assert length(Regex.scan(~r/^\/\.claude\/autonomous-pack\.json$/m, exclude)) == 1
      assert length(Regex.scan(~r/feature 044/, exclude)) == 1
    end

    test "preserves operator lines in info/exclude and creates info/ when missing" do
      repo = packless_target()
      wt = linked_worktree(repo)
      exclude = Path.join(repo, ".git/info/exclude")
      File.write!(exclude, "*.swp")

      {:ok, _} = TargetPack.supply(wt)
      assert String.starts_with?(File.read!(exclude), "*.swp\n")

      File.rm_rf!(Path.join(repo, ".git/info"))
      assert {:ok, %{excluded: [_, _]}} = TargetPack.supply(wt)
      assert File.regular?(exclude)
    end
  end

  describe "a target that commits a current pack (G4, G6)" do
    test "verify/2 and source/1 accept it as committed" do
      repo = committed_target()
      assert :ok = TargetPack.verify(repo)
      assert {:ok, %{source: :committed, contract: 6}} = TargetPack.source(repo)
    end

    test "supply/1 leaves tracked files byte-identical and drops tracked env keys from the local file" do
      repo = committed_target()
      settings = Path.join(repo, ".claude/settings.json")

      File.write!(settings, ~s({"env": {"BASH_DEFAULT_TIMEOUT_MS": "60000"}}))

      commit_all(repo, "operator env")
      wt = linked_worktree(repo)
      before = File.read!(Path.join(wt, ".claude/settings.json"))

      assert {:ok, %{source: :committed}} = TargetPack.supply(wt)
      assert File.read!(Path.join(wt, ".claude/settings.json")) == before
      assert porcelain(wt) == ""

      env = Jason.decode!(File.read!(Path.join(wt, ".claude/settings.local.json")))["env"]
      refute Map.has_key?(env, "BASH_DEFAULT_TIMEOUT_MS")
      assert env["BASH_MAX_TIMEOUT_MS"] == "2700000"
    end

    test "a non-pack tracked settings.json passes and stays untouched" do
      repo = packless_target()
      write_settings(repo, ~s({"model": "opus"}))
      commit_all(repo, "own settings")
      wt = linked_worktree(repo)

      assert :ok = TargetPack.verify(repo)
      assert {:ok, _} = TargetPack.supply(wt)
      assert File.read!(Path.join(wt, ".claude/settings.json")) == ~s({"model": "opus"})
      assert porcelain(wt) == ""
    end
  end

  describe "refusals (G5, G7)" do
    test "an outdated committed pack is refused by verify/2 and supply/1 with both remedies" do
      repo = committed_target()
      downgrade_to_contract_5(repo)
      commit_all(repo, "contract 5 pack")
      wt = linked_worktree(repo)

      for path <- [".claude/autonomous-pack.json"] do
        assert_outdated(TargetPack.verify(repo), path)
        assert {:error, {:pack_outdated, ^path, hint}} = TargetPack.supply(wt)
        assert hint =~ "update the tracked file"
        assert hint =~ "git rm --cached"
      end
    end

    test "supply/1 refuses a tracked deny list, scope-guard hook and stale hook file" do
      repo = committed_target()
      downgrade_to_contract_5(repo)
      File.write!(Path.join(repo, ".claude/autonomous-pack.json"), ~s({"contract": 6}))
      commit_all(repo, "stale registration + file")
      wt = linked_worktree(repo)
      assert {:error, {:pack_outdated, ".claude/settings.json", _}} = TargetPack.supply(wt)

      File.rm_rf!(Path.join(repo, ".claude/hooks"))

      File.write!(
        Path.join(repo, ".claude/settings.json"),
        ~s({"permissions": {"deny": ["Bash"]}})
      )

      commit_all(repo, "deny")
      wt2 = linked_worktree_at(repo, "b")
      assert {:error, {:pack_outdated, ".claude/settings.json", _}} = TargetPack.supply(wt2)
    end

    test "a tracked settings.local.json is refused" do
      repo = packless_target()
      File.write!(Path.join(repo, ".claude/settings.local.json"), "{}")
      # a global gitignore commonly hides settings.local.json — force it in
      git!(repo, ["add", "-f", ".claude/settings.local.json"])
      git!(repo, ["commit", "-q", "-m", "tracked local"])
      wt = linked_worktree(repo)

      assert {:error, [{:pack_local_tracked, ".claude/settings.local.json", hint}]} =
               TargetPack.verify(repo)

      assert hint =~ "git rm --cached"

      assert {:error, {:pack_local_tracked, ".claude/settings.local.json", _}} =
               TargetPack.supply(wt)

      assert {:error, {:pack_local_tracked, _, _}} = TargetPack.source(repo)
    end

    test "a tracked settings.json that is not a JSON object is refused" do
      repo = packless_target()
      write_settings(repo, "[1, 2]")
      commit_all(repo, "bad settings")
      wt = linked_worktree(repo)

      assert {:error, [{:invalid_settings, ".claude/settings.json"}]} = TargetPack.verify(repo)
      assert {:error, {:invalid_settings, ".claude/settings.json"}} = TargetPack.supply(wt)
    end

    test "source/1 reports an outdated marker as refused" do
      repo = committed_target()
      File.write!(Path.join(repo, ".claude/autonomous-pack.json"), "not json")
      commit_all(repo, "bad marker")

      assert {:error, {:pack_outdated, ".claude/autonomous-pack.json", _}} =
               TargetPack.source(repo)
    end
  end

  defp linked_worktree_at(repo, suffix) do
    wt = repo <> "_wt_" <> suffix
    git!(repo, ["worktree", "add", "-q", "-b", "feature/" <> suffix, wt])
    on_exit(fn -> File.rm_rf(wt) end)
    wt
  end
end
