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

  test "install/2 lays down settings, the contract-6 marker, and template constitution" do
    repo = tmp_repo()
    assert {:ok, summary} = TargetPack.install(repo)
    refute summary.constitution_skipped
    refute summary.stale_hook_removed

    assert File.regular?(Path.join(repo, ".claude/settings.json"))

    assert Jason.decode!(File.read!(Path.join(repo, ".claude/autonomous-pack.json"))) ==
             %{"contract" => 6}

    refute File.exists?(Path.join(repo, ".claude/hooks"))
    settings = Jason.decode!(File.read!(Path.join(repo, ".claude/settings.json")))
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
    assert Enum.any?(problems, &match?({:missing, ".claude/settings.json"}, &1))
  end

  defp committed_target do
    repo = tmp_repo()
    {:ok, _} = TargetPack.install(repo)
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
    File.rm!(Path.join(repo, ".claude/autonomous-pack.json"))
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

  defp assert_outdated(result, path) do
    assert {:error, problems} = result

    assert [{:pack_outdated, ^path, hint}] =
             Enum.filter(problems, &match?({:pack_outdated, _, _}, &1))

    assert hint =~ "contract 6"
    assert hint =~ "TargetPack.install/2"
    assert hint =~ "commit the result"
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
      downgrade_to_contract_5(repo)
      commit_all(repo, "contract 5 pack")

      assert {:ok, %{stale_hook_removed: true}} = TargetPack.install(repo)
      assert_outdated(TargetPack.verify(repo), ".claude/autonomous-pack.json")

      commit_all(repo, "reinstall pack")
      assert :ok = TargetPack.verify(repo)
    end

    test "install/2 removes the stale hook file, its registration, and the empty hooks dir" do
      repo = committed_target()
      downgrade_to_contract_5(repo)

      assert {:ok, %{stale_hook_removed: true}} = TargetPack.install(repo)
      refute File.exists?(Path.join(repo, ".claude/hooks"))
      settings = Jason.decode!(File.read!(Path.join(repo, ".claude/settings.json")))
      refute Map.has_key?(settings, "hooks")
      assert :ok = TargetPack.check_pack_contract(repo, false)
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
      files = ~w(.claude/settings.json .claude/autonomous-pack.json)
      before = Map.new(files, &{&1, File.read!(Path.join(repo, &1))})
      {:ok, summary} = TargetPack.install(repo)
      refute summary.stale_hook_removed
      assert Map.new(files, &{&1, File.read!(Path.join(repo, &1))}) == before
    end

    test "the agent-root pack warning is gone" do
      Code.ensure_loaded!(TargetPack)
      refute function_exported?(TargetPack, :agent_root_warning, 1)
      assert TargetPack.contract() == 6
    end
  end

  describe "install/2 settings merge (032)" do
    defp pack_settings,
      do: File.read!(Path.join(:code.priv_dir(:autonomous), "target_pack/.claude/settings.json"))

    defp write_settings(repo, content) do
      File.mkdir_p!(Path.join(repo, ".claude"))
      File.write!(Path.join(repo, ".claude/settings.json"), content)
    end

    defp read_settings(repo), do: File.read!(Path.join(repo, ".claude/settings.json"))

    test "no existing settings: pack file written as-is" do
      repo = tmp_repo()
      assert {:ok, _} = TargetPack.install(repo)
      assert read_settings(repo) == pack_settings()
    end

    test "existing env is preserved; only absent pack keys are added (SC-004)" do
      repo = tmp_repo()
      write_settings(repo, ~s({"env": {"BASH_MAX_TIMEOUT_MS": "60000", "FOO": "bar"}}))
      assert {:ok, _} = TargetPack.install(repo)

      env = Jason.decode!(read_settings(repo))["env"]
      assert env["BASH_MAX_TIMEOUT_MS"] == "60000"
      assert env["FOO"] == "bar"
      assert env["BASH_DEFAULT_TIMEOUT_MS"] == "1800000"
    end

    test "non-env keys keep overwrite semantics" do
      repo = tmp_repo()
      write_settings(repo, ~s({"permissions": {"defaultMode": "plan", "deny": ["Bash"]}}))
      assert {:ok, _} = TargetPack.install(repo)

      assert Jason.decode!(read_settings(repo))["permissions"] ==
               Jason.decode!(pack_settings())["permissions"]
    end

    test "a second install is byte-identical" do
      repo = tmp_repo()
      write_settings(repo, ~s({"env": {"FOO": "bar"}}))
      {:ok, _} = TargetPack.install(repo)
      first = read_settings(repo)
      {:ok, _} = TargetPack.install(repo)
      assert read_settings(repo) == first
    end

    test "unparseable or non-object settings: error, nothing written" do
      for bad <- ["{not json", "[1, 2]", ~s("str")] do
        repo = tmp_repo()
        write_settings(repo, bad)

        assert {:error, {:invalid_settings, ".claude/settings.json"}} = TargetPack.install(repo)
        assert read_settings(repo) == bad
        refute File.exists?(Path.join(repo, ".claude/autonomous-pack.json"))
        refute File.exists?(Path.join(repo, ".specify/memory/constitution.md"))
      end
    end

    test "merge_settings/2 is pack-wins except env" do
      pack = %{"env" => %{"A" => "1", "B" => "2"}, "x" => 1}
      existing = %{"env" => %{"B" => "9"}, "x" => 2, "y" => 3}

      assert TargetPack.merge_settings(pack, existing) == %{
               "env" => %{"A" => "1", "B" => "9"},
               "x" => 1
             }
    end
  end
end
