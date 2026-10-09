defmodule Autonomous.TargetPackTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias Autonomous.TargetPack

  defp tmp_repo do
    dir = Path.join(System.tmp_dir!(), "tp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp git!(repo, args),
    do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  test "install/2 lays down settings, executable hook, and template constitution" do
    repo = tmp_repo()
    assert {:ok, summary} = TargetPack.install(repo)
    refute summary.constitution_skipped

    assert File.regular?(Path.join(repo, ".claude/settings.json"))
    hook = Path.join(repo, ".claude/hooks/scope_guard.py")
    assert File.regular?(hook)
    stat = File.stat!(hook)
    assert (stat.mode &&& 0o100) != 0, "hook should be executable"

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

  defp old_settings_json do
    Jason.encode!(%{
      "permissions" => %{
        "defaultMode" => "acceptEdits",
        "allow" => ["Read"],
        "deny" => ["Bash(sudo:*)"]
      }
    })
  end

  defp old_hook_source, do: "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n"

  describe "containment profile (030)" do
    test "profile strict (default) is unchanged, passes on an un-upgraded pack" do
      repo = committed_target()
      settings = Path.join(repo, ".claude/settings.json")

      File.write!(settings, old_settings_json())
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "downgrade to pre-030 pack"])

      assert :ok = TargetPack.verify(repo)
      assert :ok = TargetPack.verify(repo, profile: "strict")
    end

    test "profile permissive passes for a freshly installed, committed pack" do
      repo = committed_target()
      assert :ok = TargetPack.verify(repo, profile: "permissive")
    end

    test "profile permissive fails when the committed settings.json still has a deny list" do
      repo = committed_target()
      settings = Path.join(repo, ".claude/settings.json")

      File.write!(settings, old_settings_json())
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "reintroduce deny list"])

      assert {:error, problems} = TargetPack.verify(repo, profile: "permissive")
      assert Enum.any?(problems, &match?({:pack_outdated, ".claude/hooks/scope_guard.py", _}, &1))
    end

    test "profile permissive fails when the committed hook predates contract 2 (030)" do
      repo = committed_target()
      hook = Path.join(repo, ".claude/hooks/scope_guard.py")

      File.write!(hook, old_hook_source())
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "downgrade hook"])

      assert {:error, problems} = TargetPack.verify(repo, profile: "permissive")
      assert Enum.any?(problems, &match?({:pack_outdated, ".claude/hooks/scope_guard.py", _}, &1))
    end

    test "profile permissive fails when the committed hook is contract 3" do
      repo = committed_target()
      hook = Path.join(repo, ".claude/hooks/scope_guard.py")

      File.write!(
        hook,
        String.replace(File.read!(hook), "PACK_CONTRACT = 5", "PACK_CONTRACT = 3")
      )

      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "contract 3 hook"])

      assert {:error, problems} = TargetPack.verify(repo, profile: "permissive")
      assert Enum.any?(problems, &match?({:pack_outdated, ".claude/hooks/scope_guard.py", _}, &1))
    end

    test "profile permissive fails when the upgrade is installed but uncommitted" do
      repo = committed_target()
      hook = Path.join(repo, ".claude/hooks/scope_guard.py")

      File.write!(hook, old_hook_source())
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "downgrade hook"])

      # Re-install (contract 4 again) but leave it uncommitted — HEAD: still
      # sees the downgraded hook, so this must fail exactly like a missing
      # upgrade.
      {:ok, _} = TargetPack.install(repo)

      assert {:error, problems} = TargetPack.verify(repo, profile: "permissive")
      assert Enum.any?(problems, &match?({:pack_outdated, ".claude/hooks/scope_guard.py", _}, &1))
    end

    test "check_pack_contract/1 reads the committed hook, not the working tree" do
      repo = committed_target()
      hook = Path.join(repo, ".claude/hooks/scope_guard.py")

      File.write!(hook, old_hook_source())
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "downgrade hook"])

      {:ok, _} = TargetPack.install(repo)

      assert {:error, {:pack_outdated, ".claude/hooks/scope_guard.py", _hint}} =
               TargetPack.check_pack_contract(repo)
    end

    test "check_pack_contract/1 passes once the upgrade is committed" do
      repo = committed_target()
      assert :ok = TargetPack.check_pack_contract(repo)
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
        refute File.exists?(Path.join(repo, ".claude/hooks/scope_guard.py"))
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

    test "permissive preflight refuses a contract 3 pack, accepts 4; strict unchanged" do
      repo = committed_target()
      assert :ok = TargetPack.verify(repo, profile: "permissive")

      hook = Path.join(repo, ".claude/hooks/scope_guard.py")

      File.write!(
        hook,
        String.replace(File.read!(hook), "PACK_CONTRACT = 5", "PACK_CONTRACT = 3")
      )

      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "contract 3"])

      assert {:error, [{:pack_outdated, ".claude/hooks/scope_guard.py", hint}]} =
               TargetPack.verify(repo, profile: "permissive")

      assert hint =~ "TargetPack.install/2"
      assert :ok = TargetPack.verify(repo, profile: "strict")
    end
  end

  describe "pack contract 5 (037)" do
    defp commit_contract(repo, n) do
      hook = Path.join(repo, ".claude/hooks/scope_guard.py")

      File.write!(
        hook,
        String.replace(File.read!(hook), "PACK_CONTRACT = 5", "PACK_CONTRACT = #{n}")
      )

      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "contract #{n}"])
    end

    test "install/2 writes a hook that reports contract 5" do
      repo = committed_target()

      {out, 0} =
        System.cmd("python3", [Path.join(repo, ".claude/hooks/scope_guard.py"), "--contract"])

      assert String.trim(out) == "5"
    end

    test "permissive check passes at contract 4 and 5" do
      repo = committed_target()
      assert :ok = TargetPack.check_pack_contract(repo)
      commit_contract(repo, 4)
      assert :ok = TargetPack.check_pack_contract(repo)
      assert :ok = TargetPack.verify(repo, profile: "permissive")
    end

    test "agent_root_warning/1: ok at 5, warning at 4, unknown on probe failure" do
      repo = committed_target()
      assert :ok = TargetPack.agent_root_warning(repo)

      commit_contract(repo, 4)

      assert {:warning, {:pack_below_agent_root_contract, 4, 5}} =
               TargetPack.agent_root_warning(repo)

      empty = Path.join(System.tmp_dir!(), "no_repo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)

      assert {:warning, {:pack_below_agent_root_contract, :unknown, 5}} =
               TargetPack.agent_root_warning(empty)
    end
  end
end
