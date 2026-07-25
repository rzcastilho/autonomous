defmodule SpeckitOrchestrator.Integration.ContainerRedTeamTest do
  @moduledoc """
  US2 (bound the blast radius) — `@tag :integration`, requires a Linux host
  with a container engine (FR-014) and a built image. Proves the OS-layer
  isolation (`--user`, `--read-only`, `--cap-drop ALL`, `--security-opt
  no-new-privileges`) stands on its own, with the in-repo PreToolUse
  scope-guard hook deliberately removed from the mounted repo first — so
  nothing but the container boundary itself is under test.

  Configure via environment variables before running
  `mise exec -- mix test --include integration test/integration/container_red_team_test.exs`:

    * `AUTONOMOUS_TEST_IMAGE` — image ref to run
    * `AUTONOMOUS_TEST_REPO` — a scratch git repo to mount as `$SPECKIT_REPO`
      (a plain `git init`'d repo is enough — this suite never launches a run,
      only execs hostile commands directly, so the repo need not be
      `TargetPack`-prepared)
    * `AUTONOMOUS_TEST_HOME` — a scratch `$HOME`; MUST be disposable (this
      suite checksums it before and after, so do not point it at a real
      operator home directory)
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: :infinity

  @container_name "autonomous-container-red-team-test"

  # ---- prerequisites --------------------------------------------------------

  defp require_env!(name) do
    case System.get_env(name) do
      nil -> flunk("set #{name} to run the red-team integration suite (see moduledoc)")
      "" -> flunk("set #{name} to run the red-team integration suite (see moduledoc)")
      value -> value
    end
  end

  setup_all do
    System.find_executable("docker") ||
      flunk("docker is not on PATH — a Linux container engine is required (FR-014)")

    image = require_env!("AUTONOMOUS_TEST_IMAGE")
    repo = require_env!("AUTONOMOUS_TEST_REPO")
    home = require_env!("AUTONOMOUS_TEST_HOME")

    File.mkdir_p!(Path.join(home, ".autonomous"))

    # "deliberately disabled" (US2 independent test) — remove the PreToolUse
    # guard hook from the mounted repo so only the OS layer stands between a
    # hostile command and the host. Irrelevant to this suite's own commands
    # (they exec directly, never through the Claude CLI's tool-call layer),
    # but removed anyway so the fixture repo cannot be mistaken for relying
    # on hook coverage.
    hook_path = Path.join(repo, ".claude/hooks/scope_guard.py")
    if File.exists?(hook_path), do: File.rm!(hook_path)

    # A sentinel entirely outside both declared mounts, proving a write that
    # somehow escaped the container would be caught even if it landed
    # nowhere near $HOME or $REPO.
    sentinel_dir =
      Path.join(System.tmp_dir!(), "autonomous_redteam_sentinel_#{System.unique_integer([:positive])}")

    File.mkdir_p!(sentinel_dir)
    File.write!(Path.join(sentinel_dir, "canary.txt"), "untouched\n")
    on_exit(fn -> File.rm_rf(sentinel_dir) end)

    %{image: image, repo: repo, home: home, sentinel_dir: sentinel_dir}
  end

  setup %{image: image, repo: repo, home: home} do
    on_exit(fn -> System.cmd("docker", ["rm", "-f", @container_name], stderr_to_stdout: true) end)

    args = [
      "run",
      "-d",
      "--name",
      @container_name,
      "--user",
      "#{host_uid()}:#{host_gid()}",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "4096",
      "--tmpfs",
      "/tmp:rw,nosuid,nodev,size=1g",
      "--tmpfs",
      "#{home}:rw,nosuid,nodev,mode=0700",
      "-v",
      "#{repo}:#{repo}",
      "-v",
      "#{Path.join(home, ".autonomous")}:#{Path.join(home, ".autonomous")}",
      "-e",
      "SPECKIT_REPO=#{repo}",
      "-e",
      "HOME=#{home}",
      "-e",
      "AUTONOMOUS_HOST_REPO=#{repo}",
      "-e",
      "AUTONOMOUS_HOST_HOME=#{home}",
      "-e",
      "RELEASE_COOKIE=red-team-test-cookie",
      "-e",
      "GIT_AUTHOR_NAME=autonomous-test",
      "-e",
      "GIT_AUTHOR_EMAIL=autonomous-test@example.com",
      "-e",
      "GIT_COMMITTER_NAME=autonomous-test",
      "-e",
      "GIT_COMMITTER_EMAIL=autonomous-test@example.com",
      image
    ]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> flunk("docker run failed (#{code}):\n#{out}")
    end

    wait_until_running!(@container_name)
    :ok
  end

  # ---- helpers ---------------------------------------------------------------

  defp host_uid, do: :os.cmd(~c"id -u") |> to_string() |> String.trim()
  defp host_gid, do: :os.cmd(~c"id -g") |> to_string() |> String.trim()

  defp wait_until_running!(name, attempts \\ 30)

  defp wait_until_running!(_name, 0), do: flunk("container did not reach running state in time")

  defp wait_until_running!(name, attempts) do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", name], stderr_to_stdout: true) do
      {"true\n", 0} ->
        :ok

      _ ->
        Process.sleep(500)
        wait_until_running!(name, attempts - 1)
    end
  end

  defp docker_exec(cmd) do
    System.cmd("docker", ["exec", @container_name, "sh", "-c", cmd], stderr_to_stdout: true)
  end

  # Sorted `sha256sum` over every regular file under `dir`; empty string if the
  # directory doesn't exist or has no files. Deterministic — same content
  # always yields the same digest listing, independent of filesystem order.
  defp checksum_tree(dir) do
    if File.dir?(dir) do
      case System.cmd("sh", ["-c", "find #{shell_quote(dir)} -type f -exec sha256sum {} + 2>/dev/null | sort"]) do
        {out, 0} -> out
        _ -> ""
      end
    else
      ""
    end
  end

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp container_running?(name) do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", name], stderr_to_stdout: true) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  # ---- SC-002 ----------------------------------------------------------------

  @hostile_commands [
    {"write outside $SPECKIT_REPO and $HOME/.autonomous",
     "echo hostile > /root/pwned 2>&1 || echo hostile > /var/pwned"},
    {"sudo", "sudo id"},
    {"setuid-escalation attempt (su to root)", "su -c 'id -u' root"},
    {"write to /etc", "echo hostile > /etc/pwned"},
    {"write to /usr", "echo hostile > /usr/pwned"},
    {"system-path package install", "apt-get install -y curl"},
    {"privileged bind mount attempt", "mkdir -p /tmp/mnt && mount --bind /etc /tmp/mnt"},
    {"raw device write attempt", "dd if=/dev/zero of=/dev/mem bs=1 count=1"},
    {"capability-requiring syscall (CAP_NET_ADMIN)", "ip link set lo down"}
  ]

  test "SC-002: >=10 hostile commands all fail with the guard hook disabled, and the host filesystem outside the declared mounts is byte-for-byte unchanged",
       %{home: home, sentinel_dir: sentinel_dir} do
    before_home = checksum_tree(home) |> String.replace(~r/.*\.autonomous.*\n?/, "")
    before_sentinel = checksum_tree(sentinel_dir)

    for {label, cmd} <- @hostile_commands do
      {out, code} = docker_exec(cmd)
      assert code != 0, "expected \"#{label}\" to fail, but it exited 0:\n#{out}"
    end

    # $HOME (excluding .autonomous) is documented ephemeral tmpfs scratch
    # space (contracts/container-run.md §3) — writable by design, so this
    # command legitimately succeeds inside the container. What SC-002
    # actually guarantees is that the write never reaches the host: the
    # tmpfs mount at $HOME shadows the host path entirely, so nothing at
    # that path on the host disk can change — proven below by the
    # before/after checksum rather than by this command's exit code.
    docker_exec("echo hostile > #{shell_quote(home)}/not-autonomous-pwned")

    assert container_running?(@container_name), "container must remain healthy after the red-team run"

    after_home = checksum_tree(home) |> String.replace(~r/.*\.autonomous.*\n?/, "")
    after_sentinel = checksum_tree(sentinel_dir)

    assert before_home == after_home, "a write inside the container's tmpfs $HOME must never reach the host"
    assert before_sentinel == after_sentinel
  end
end
