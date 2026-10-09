defmodule Autonomous.ContainerTrustStepTest do
  @moduledoc "Runs the real `container-entrypoint.sh trust-config` step against a temp HOME (feature 036)."
  use ExUnit.Case, async: true

  @entrypoint Path.expand("../../scripts/container-entrypoint.sh", __DIR__)

  setup do
    base = Path.join(System.tmp_dir!(), "trust_step_#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    repo = Path.join(base, "my repo")
    root = Path.join(base, "worktrees")
    File.mkdir_p!(home)
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, home: home, repo: repo, root: root, config: Path.join(home, ".claude.json")}
  end

  defp run_step(ctx, overrides \\ %{}) do
    env =
      %{
        "HOME" => ctx.home,
        "AUTONOMOUS_REPO" => ctx.repo,
        "AUTONOMOUS_WORKTREE_ROOT" => ctx.root,
        "AUTONOMOUS_CLI_CONFIG_SEED" => Path.join(ctx.home, "no-seed.json")
      }
      |> Map.merge(overrides)
      |> Enum.to_list()

    System.cmd("sh", [@entrypoint, "trust-config"], env: env, stderr_to_stdout: true)
  end

  defp real(path), do: path |> Path.expand() |> real_path()

  defp real_path(path) do
    {out, 0} =
      System.cmd("python3", ["-c", "import os,sys;print(os.path.realpath(sys.argv[1]))", path])

    String.trim(out)
  end

  test "no config: creates the file with exactly the two records, mode 0600", ctx do
    assert {_, 0} = run_step(ctx)
    cfg = ctx.config |> File.read!() |> Jason.decode!()

    assert cfg["projects"] == %{
             real(ctx.repo) => %{"hasTrustDialogAccepted" => true},
             real(ctx.root) => %{"hasTrustDialogAccepted" => true}
           }

    assert File.stat!(ctx.config).mode |> Bitwise.band(0o777) == 0o600
  end

  test "second run is a no-op: bytes and mtime unchanged", ctx do
    assert {_, 0} = run_step(ctx)
    before = {File.read!(ctx.config), File.stat!(ctx.config).mtime}
    Process.sleep(1100)
    assert {out, 0} = run_step(ctx)
    assert out =~ "already trusted"
    assert {File.read!(ctx.config), File.stat!(ctx.config).mtime} == before
  end

  test "missing or empty AUTONOMOUS_WORKTREE_ROOT fails naming the variable", ctx do
    assert {out, code} = run_step(ctx, %{"AUTONOMOUS_WORKTREE_ROOT" => ""})
    assert code != 0
    assert out =~ "AUTONOMOUS_WORKTREE_ROOT"
    refute File.exists?(ctx.config)
  end

  describe "scope (US2)" do
    test "trusts exactly the repo and worktree root, nothing broader", ctx do
      assert {_, 0} = run_step(ctx)

      keys =
        ctx.config
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("projects")
        |> Map.keys()
        |> Enum.sort()

      assert keys == Enum.sort([real(ctx.repo), real(ctx.root)])

      for broad <- [real(ctx.home), "/", Path.dirname(ctx.repo), "/workspace"] do
        refute broad in keys
      end
    end

    test "pre-seeded entries carried over unchanged", ctx do
      File.write!(
        ctx.config,
        Jason.encode!(%{
          "projects" => %{
            "/other/true" => %{"hasTrustDialogAccepted" => true},
            "/other/false" => %{"hasTrustDialogAccepted" => false}
          }
        })
      )

      assert {_, 0} = run_step(ctx)
      projects = ctx.config |> File.read!() |> Jason.decode!() |> Map.fetch!("projects")
      assert projects["/other/true"] == %{"hasTrustDialogAccepted" => true}
      assert projects["/other/false"] == %{"hasTrustDialogAccepted" => false}
      assert map_size(projects) == 4
    end

    test "separate instances trust only their own pair", ctx do
      base = Path.dirname(ctx.home)
      home2 = Path.join(base, "home2")
      repo2 = Path.join(base, "repo2")
      File.mkdir_p!(home2)
      File.mkdir_p!(repo2)
      root2 = Path.join(base, "worktrees2")

      assert {_, 0} = run_step(ctx)

      assert {_, 0} =
               run_step(ctx, %{
                 "HOME" => home2,
                 "AUTONOMOUS_REPO" => repo2,
                 "AUTONOMOUS_WORKTREE_ROOT" => root2
               })

      keys2 =
        Path.join(home2, ".claude.json")
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("projects")
        |> Map.keys()
        |> Enum.sort()

      assert keys2 == Enum.sort([real(repo2), real(root2)])
    end

    test "host seed file is never written; only $HOME/.claude.json is", ctx do
      seed = Path.join(ctx.home, "host.json")
      File.write!(seed, ~s({"userID":"abc"}))
      before = File.read!(seed)
      File.chmod!(seed, 0o444)

      assert {_, 0} = run_step(ctx, %{"AUTONOMOUS_CLI_CONFIG_SEED" => seed})
      assert File.read!(seed) == before
      cfg = ctx.config |> File.read!() |> Jason.decode!()
      assert cfg["userID"] == "abc"
      assert map_size(cfg["projects"]) == 2
    end
  end

  describe "preservation, safety, idempotence (US3)" do
    test "unrelated keys and key order preserved; explicit false becomes true", ctx do
      raw =
        ~s({"oauthAccount":{"email":"a@b"},"zeta":1,"projects":{"#{real(ctx.repo)}":{"hasTrustDialogAccepted":false,"allowedTools":["Bash"],"history":[1,2]}},"alpha":[true]})

      File.write!(ctx.config, raw)
      assert {_, 0} = run_step(ctx)
      after_cfg = ctx.config |> File.read!() |> Jason.decode!()
      before_cfg = Jason.decode!(raw)

      assert after_cfg["oauthAccount"] == before_cfg["oauthAccount"]
      assert after_cfg["zeta"] == 1
      assert after_cfg["alpha"] == [true]
      entry = after_cfg["projects"][real(ctx.repo)]
      assert entry["hasTrustDialogAccepted"] == true
      assert entry["allowedTools"] == ["Bash"]
      assert entry["history"] == [1, 2]

      top_keys =
        ctx.config
        |> File.read!()
        |> then(&Regex.scan(~r/^  "([^"]+)":/m, &1))
        |> Enum.map(&List.last/1)

      assert top_keys == ["oauthAccount", "zeta", "projects", "alpha"]
    end

    for {label, bad} <- [
          {"truncated", "{"},
          {"array", "[]"},
          {"string", ~s("x")},
          {"projects array", ~s({"projects": []})}
        ] do
      test "invalid config (#{label}) refuses, names the file, leaves it untouched", ctx do
        File.write!(ctx.config, unquote(bad))
        assert {out, code} = run_step(ctx)
        assert code != 0
        assert out =~ ".claude.json"
        assert File.read!(ctx.config) == unquote(bad)
      end
    end

    test "repeated runs converge: identical bytes after the first", ctx do
      assert {_, 0} = run_step(ctx)
      first = File.read!(ctx.config)

      for _ <- 1..4 do
        assert {_, 0} = run_step(ctx)
        assert File.read!(ctx.config) == first
      end

      assert map_size(Jason.decode!(first)["projects"]) == 2
    end

    test "atomic replace: no temp file left, inode changes on a modifying run", ctx do
      File.write!(ctx.config, ~s({"k":1}))
      %{inode: ino} = File.stat!(ctx.config)
      assert {_, 0} = run_step(ctx)
      assert File.stat!(ctx.config).inode != ino
      assert Path.wildcard(Path.join(ctx.home, ".claude.json.tmp.*")) == []
    end
  end
end
