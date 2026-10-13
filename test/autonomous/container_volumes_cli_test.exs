defmodule Autonomous.ContainerVolumesCliTest do
  @moduledoc "Runs the real `scripts/autonomous` against a stub `docker` (feature 041, wrapper-cli.md)."
  use ExUnit.Case, async: true

  alias Autonomous.StubDocker

  @wrapper Path.expand("../../scripts/autonomous", __DIR__)
  @segment "t-1a2b"
  @parent "/var/lib/autonomous/volumes"
  @segment_vols_a "autonomous-#{@segment}_vol-a"
  @segment_vols_b "autonomous-#{@segment}_vol-b"

  defp setup_env(opts \\ []) do
    base = Path.join(System.tmp_dir!(), "vol_cli_#{System.unique_integer([:positive])}")
    home = Path.join(base, "home")
    xdg = Path.join(base, "xdg")
    repo = Path.join(base, "repo")
    File.mkdir_p!(home)
    File.mkdir_p!(xdg)
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", repo])
    on_exit(fn -> File.rm_rf!(base) end)

    docker = StubDocker.install(base, opts)
    %{base: base, home: home, xdg: xdg, repo: repo, docker: docker}
  end

  defp declaration(ctx), do: Path.join([ctx.xdg, "autonomous", "targets", @segment, "volumes.toml"])

  defp write_declaration(ctx, text) do
    File.mkdir_p!(Path.dirname(declaration(ctx)))
    File.write!(declaration(ctx), text)
  end

  defp run(ctx, args) do
    env = [
      {"PATH", ctx.docker.bin <> ":" <> System.get_env("PATH")},
      {"HOME", ctx.home},
      {"XDG_CONFIG_HOME", ctx.xdg}
    ]

    System.cmd("sh", [@wrapper | args], env: env, stderr_to_stdout: true)
  end

  defp shell(ctx), do: run(ctx, ["shell", "--target", ctx.repo])

  @one_volume """
  [[volume]]
  name = "cargo-target"
  path = "#{@parent}/cargo-target"
  env = { CARGO_TARGET_DIR = "#{@parent}/cargo-target" }
  """

  describe "start with a declaration" do
    setup do
      {:ok, setup_env(image_env: ~s(["PATH=/usr/bin","MISE_DATA_DIR=/opt/mise"]))}
    end

    test "creates labelled volumes, provisions once, appends the overlay", ctx do
      write_declaration(ctx, """
      #{@one_volume}
      [[volume]]
      name = "mise-data"
      path = "#{@parent}/mise-data"
      env = { MISE_DATA_DIR = "#{@parent}/mise-data" }
      """)

      assert {out, 0} = shell(ctx)
      calls = StubDocker.calls(ctx.docker)

      for name <- ["cargo-target", "mise-data"] do
        assert calls =~ "volume create"
        assert calls =~ "--label dev.autonomous.kind=user-volume"
        assert calls =~ "--label dev.autonomous.segment=#{@segment}"
        assert calls =~ "--label dev.autonomous.volume=#{name}"
        assert calls =~ "autonomous-#{@segment}_vol-#{name}"
      end

      assert length(Regex.scan(~r/args=run --rm --user 0:0 --entrypoint \/bin\/sh/, calls)) == 1
      assert calls =~ "-v autonomous-t-1a2b_vol-cargo-target:/v/cargo-target"
      assert calls =~ "-v autonomous-t-1a2b_vol-mise-data:/v/mise-data"

      overlay = Path.join(Path.dirname(declaration(ctx)), "applied.compose.json")
      assert File.exists?(overlay)
      assert calls =~ ~r/compose -p autonomous-t-1a2b .*applied\.compose\.json run --rm/

      assert out =~ "autonomous: volumes  "
      assert out =~ "volumes.toml"
      assert out =~ "autonomous: volume cargo-target -> #{@parent}/cargo-target (1 variable, 0 path dirs)"
      assert out =~ "autonomous: volume mise-data: MISE_DATA_DIR overrides image value /opt/mise with #{@parent}/mise-data"
    end

    test "volume lines come after the summary", ctx do
      write_declaration(ctx, @one_volume)
      assert {out, 0} = shell(ctx)
      {summary, _} = :binary.match(out, "autonomous: console")
      {volumes, _} = :binary.match(out, "autonomous: volumes")
      assert summary < volumes
    end
  end

  describe "start without a declaration" do
    test "absent file: no extra docker calls, no overlay, no new output" do
      ctx = setup_env()
      assert {out, 0} = shell(ctx)
      calls = StubDocker.calls(ctx.docker)

      refute calls =~ "volume create"
      refute calls =~ "--user 0:0"
      refute calls =~ "image inspect -f"
      refute calls =~ "applied.compose.json"
      refute out =~ "volume"
      refute File.exists?(declaration(ctx))
    end

    test "zero-entry file behaves identically" do
      ctx = setup_env()
      baseline = shell(ctx) |> elem(0) |> String.replace(~r/127\.0\.0\.1:\d+/, "PORT")
      calls_baseline = StubDocker.calls(ctx.docker) |> String.replace(~r/\d{4,5}/, "N")
      File.rm!(ctx.docker.log)

      write_declaration(ctx, "# nothing declared\n")
      assert {out, 0} = shell(ctx)
      calls = StubDocker.calls(ctx.docker)

      refute calls =~ "volume create"
      refute calls =~ "applied.compose.json"
      assert String.replace(out, ~r/127\.0\.0\.1:\d+/, "PORT") == baseline
      assert String.replace(calls, ~r/\d{4,5}/, "N") =~ String.slice(calls_baseline, 0, 40)
      refute File.exists?(Path.join(Path.dirname(declaration(ctx)), "applied.compose.json"))
    end
  end

  describe "refusing an invalid declaration" do
    test "violations exit 2 before anything exists" do
      ctx = setup_env()

      write_declaration(ctx, """
      [[volume]]
      name = "a"
      path = "/workspace/x"
      env = { PATH = "x" }
      """)

      assert {out, 2} = shell(ctx)
      assert out =~ "volumes.toml: 2 problems"
      assert out =~ "entry a: path /workspace/x is inside /workspace"
      assert out =~ "entry a: PATH is reserved"
      assert out =~ "nothing was started; fix the declaration and retry"

      calls = StubDocker.calls(ctx.docker)
      refute calls =~ "volume create"
      refute calls =~ "args=run"
      refute calls =~ " up "
      refute calls =~ "--user 0:0"
      refute calls =~ "-p autonomous-#{@segment}"
      refute out =~ "autonomous: console"
    end

    test "console start is refused the same way" do
      ctx = setup_env()
      write_declaration(ctx, "[[volume]]\nname = \"Bad\"\npath = \"/x\"\n")
      assert {_, 2} = run(ctx, ["console", "--target", ctx.repo])
      refute StubDocker.calls(ctx.docker) =~ " up "
    end

    test "a malformed file names the file and the parser message" do
      ctx = setup_env()
      write_declaration(ctx, "[[volume]\nname = ")
      assert {out, 2} = shell(ctx)
      assert out =~ "volumes.toml: not valid TOML:"
      refute StubDocker.calls(ctx.docker) =~ "volume create"
    end

    test "an XDG_CONFIG_HOME inside the target repo is refused" do
      ctx = setup_env()
      ctx = %{ctx | xdg: Path.join(ctx.repo, "cfg")}
      File.mkdir_p!(ctx.xdg)
      assert {out, 2} = shell(ctx)
      assert out =~ "set XDG_CONFIG_HOME outside"
    end

    test "python3 older than 3.11 is refused only when a declaration exists" do
      ctx = setup_env()
      shim = Path.join(ctx.base, "py")
      File.mkdir_p!(shim)
      real = System.find_executable("python3")

      File.write!(Path.join(shim, "python3"), """
      #!/bin/sh
      case "$1" in
        *volumes.py) echo "autonomous: $1 needs python3 >= 3.11 (tomllib); found 3.9.1" >&2; exit 2 ;;
      esac
      exec #{real} "$@"
      """)

      File.chmod!(Path.join(shim, "python3"), 0o755)
      env = [{"PATH", shim <> ":" <> ctx.docker.bin <> ":" <> System.get_env("PATH")}, {"HOME", ctx.home}, {"XDG_CONFIG_HOME", ctx.xdg}]

      assert {_, 0} = System.cmd("sh", [@wrapper, "shell", "--target", ctx.repo], env: env, stderr_to_stdout: true)

      write_declaration(ctx, @one_volume)
      assert {out, 2} = System.cmd("sh", [@wrapper, "shell", "--target", ctx.repo], env: env, stderr_to_stdout: true)
      assert out =~ "needs python3 >= 3.11"
    end
  end

  describe "reset-cache" do
    @dn "autonomous-#{@segment}_vol-"
    @labels "user-volume #{@segment} "
    @two_volumes """
    [[volume]]
    name = "a"
    path = "#{@parent}/a"

    [[volume]]
    name = "b"
    path = "#{@parent}/b"
    """

    defp reset(ctx, extra \\ []), do: run(ctx, ["reset-cache", "--target", ctx.repo | extra])

    defp present_env(extra \\ []) do
      setup_env(
        Keyword.merge(
          [
            volumes: [@dn <> "a", @dn <> "b"],
            labels: %{(@dn <> "a") => @labels <> "a", (@dn <> "b") => @labels <> "b"}
          ],
          extra
        )
      )
    end

    test "removes the named volume only" do
      ctx = present_env()
      write_declaration(ctx, @two_volumes)
      assert {out, 0} = reset(ctx, ["--volume", "a"])
      assert out =~ "autonomous: a removed"
      calls = StubDocker.calls(ctx.docker)
      assert calls =~ "volume rm #{@dn}a"
      refute calls =~ "volume rm #{@dn}b"
    end

    test "--volume=<name> form and removing all when none named" do
      ctx = present_env()
      write_declaration(ctx, @two_volumes)
      assert {out, 0} = reset(ctx, ["--volume=b"])
      assert out =~ "b removed"
      refute out =~ "a removed"

      assert {out, 0} = reset(ctx)
      assert out =~ "a removed"
      assert out =~ "b removed"
    end

    test "any container of the project, even exited, refuses with 75" do
      ctx = present_env(containers: ["autonomous-#{@segment}-console-1"])
      write_declaration(ctx, @two_volumes)
      assert {out, 75} = reset(ctx)
      assert out =~ "autonomous-#{@segment}-console-1"
      assert out =~ "stop it first: scripts/autonomous stop --target "
      refute StubDocker.calls(ctx.docker) =~ "volume rm"
    end

    test "an unknown name exits 2 listing the declared names, nothing removed" do
      ctx = present_env()
      write_declaration(ctx, @two_volumes)
      assert {out, 2} = reset(ctx, ["--volume", "nope"])
      assert out =~ "volume nope is not declared; declared: a, b"
      refute StubDocker.calls(ctx.docker) =~ "volume rm"
    end

    test "an absent volume is reported and exits 0 (idempotent)" do
      ctx = setup_env()
      write_declaration(ctx, @two_volumes)
      assert {out, 0} = reset(ctx)
      assert out =~ "autonomous: a not present"
      assert out =~ "autonomous: b not present"
      refute StubDocker.calls(ctx.docker) =~ "volume rm"
    end

    test "a volume without our labels is never removed" do
      ctx =
        setup_env(volumes: [@dn <> "a"], labels: %{(@dn <> "a") => "  "})

      write_declaration(ctx, @two_volumes)
      assert {out, 1} = reset(ctx, ["--volume", "a"])
      assert out =~ "#{@dn}a"
      assert out =~ "not removed"
      refute StubDocker.calls(ctx.docker) =~ "volume rm"
    end

    test "no declaration, or zero entries: no declared volumes" do
      ctx = setup_env()
      assert {out, 0} = reset(ctx)
      assert out =~ "no declared volumes"

      write_declaration(ctx, "# none\n")
      assert {out, 0} = reset(ctx)
      assert out =~ "no declared volumes"
    end

    test "--volume is rejected on other commands" do
      ctx = setup_env()
      assert {out, 2} = run(ctx, ["stop", "--target", ctx.repo, "--volume", "a"])
      assert out =~ "unknown option '--volume'"
    end

    test "another segment's volumes are never matched" do
      ctx =
        setup_env(
          volumes: ["autonomous-other_vol-a"],
          labels: %{"autonomous-other_vol-a" => "user-volume other a"}
        )

      write_declaration(ctx, @two_volumes)
      assert {out, 0} = reset(ctx)
      assert out =~ "a not present"
      refute StubDocker.calls(ctx.docker) =~ "autonomous-other_vol-a"
    end
  end

  describe "stop --purge" do
    test "removes exactly the labelled user volumes of the segment and prints each" do
      ctx = setup_env(ls: [@segment_vols_a, @segment_vols_b])
      assert {out, 0} = run(ctx, ["stop", "--target", ctx.repo, "--purge"])
      calls = StubDocker.calls(ctx.docker)

      assert calls =~ "volume ls -q --filter label=dev.autonomous.kind=user-volume --filter label=dev.autonomous.segment=#{@segment}"
      assert calls =~ "volume rm #{@segment_vols_a}"
      assert calls =~ "volume rm #{@segment_vols_b}"
      assert out =~ "autonomous: #{@segment_vols_a} removed"
      assert out =~ "autonomous: #{@segment_vols_b} removed"
    end

    test "plain stop touches no user volume" do
      ctx = setup_env(ls: [@segment_vols_a])
      assert {_, 0} = run(ctx, ["stop", "--target", ctx.repo])
      calls = StubDocker.calls(ctx.docker)
      refute calls =~ "volume ls"
      refute calls =~ "volume rm"
    end
  end
end
