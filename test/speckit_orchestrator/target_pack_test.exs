defmodule SpeckitOrchestrator.TargetPackTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias SpeckitOrchestrator.TargetPack

  defp tmp_repo do
    dir = Path.join(System.tmp_dir!(), "tp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp git!(repo, args), do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  test "install/2 lays down settings, executable hook, and template constitution" do
    repo = tmp_repo()
    assert {:ok, summary} = TargetPack.install(repo)
    refute summary.constitution_skipped

    assert File.regular?(Path.join(repo, ".claude/settings.json"))
    hook = Path.join(repo, ".claude/hooks/scope_guard.py")
    assert File.regular?(hook)
    stat = File.stat!(hook)
    assert (stat.mode &&& 0o100) != 0, "hook should be executable"
    assert File.read!(Path.join(repo, ".specify/memory/constitution.md")) =~ "SPECKIT_ORCHESTRATOR_TEMPLATE"
  end

  test "install/2 never clobbers an existing constitution" do
    repo = tmp_repo()
    File.mkdir_p!(Path.join(repo, ".specify/memory"))
    File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Real constitution\n")

    assert {:ok, summary} = TargetPack.install(repo)
    assert summary.constitution_skipped
    assert File.read!(Path.join(repo, ".specify/memory/constitution.md")) == "# Real constitution\n"
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
end
