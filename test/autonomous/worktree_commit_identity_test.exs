defmodule Autonomous.WorktreeCommitIdentityTest do
  # 031 R8 / FR-014: the container sets GIT_AUTHOR_* / GIT_COMMITTER_* from .env.
  # Git gives those env vars precedence over the `-c user.*` that
  # `Worktree.commit/2` passes, so the operator's identity wins and the
  # orchestrator default applies only when the env is unset.
  #
  # Not async: it mutates the process-wide OS environment.
  use ExUnit.Case, async: false

  alias Autonomous.Worktree

  @vars ~w(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL)

  setup do
    saved = Map.new(@vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    dir = Path.join(System.tmp_dir!(), "wt_identity_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    git!(dir, ["init", "-q", "-b", "main"])
    File.write!(Path.join(dir, "README.md"), "base\n")

    # The base commit uses an explicit identity so only the commit under test
    # depends on the env.
    Enum.each(@vars, &System.delete_env/1)
    git!(dir, ["-c", "user.name=Base", "-c", "user.email=base@example.com", "add", "-A"])
    git!(dir, ["-c", "user.name=Base", "-c", "user.email=base@example.com", "commit", "-q", "-m", "base"])

    File.write!(Path.join(dir, "change.txt"), "change\n")

    {:ok, dir: dir, wt: %Worktree{path: dir, branch: "main", repo: dir, feature_id: "001"}}
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(out)
  end

  test "GIT_* env takes precedence over the orchestrator's -c user.*", %{dir: dir, wt: wt} do
    System.put_env("GIT_AUTHOR_NAME", "Operator")
    System.put_env("GIT_AUTHOR_EMAIL", "operator@example.com")
    System.put_env("GIT_COMMITTER_NAME", "Operator")
    System.put_env("GIT_COMMITTER_EMAIL", "operator@example.com")

    assert :ok = Worktree.commit(wt, "feat: change")

    assert git!(dir, ["log", "-1", "--format=%an <%ae>|%cn <%ce>"]) ==
             "Operator <operator@example.com>|Operator <operator@example.com>"
  end

  test "without GIT_* env the orchestrator identity applies", %{dir: dir, wt: wt} do
    assert :ok = Worktree.commit(wt, "feat: change")

    assert git!(dir, ["log", "-1", "--format=%an <%ae>"]) ==
             "autonomous <orchestrator@speckit.local>"
  end
end
