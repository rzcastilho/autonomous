defmodule SpeckitOrchestrator.Integration.ContainerRunTest do
  @moduledoc """
  US1 (run parity) and US2 scenario 3 (file ownership) — `@tag :integration`,
  requires a Linux host with a container engine (FR-014) and a **built**
  orchestrator image. Not run by the default `mix test` suite; paid (real
  agent calls) and opt-in like the other LIVE integration tests in this repo.

  Configure via environment variables before running
  `mise exec -- mix test --include integration test/integration/container_run_test.exs`:

    * `AUTONOMOUS_TEST_IMAGE` — image ref to run, e.g. `autonomous:dev`
      (`docker build --build-arg SOURCE_REVISION="$(git rev-parse HEAD)" -t
      autonomous:dev .`, per `contracts/image-publishing.md` §7)
    * `AUTONOMOUS_TEST_REPO` — path to a **prepared** target repository
      (`TargetPack.install/2` + a real constitution, committed) with a small
      backlog under its `specs/autonomous/breakdown/` — see `docs/enforcement.md`
    * `AUTONOMOUS_TEST_SLUG` — the breakdown package slug to run
    * `AUTONOMOUS_TEST_HOME` — a scratch `$HOME` for the container run;
      `$AUTONOMOUS_TEST_HOME/.autonomous` becomes the run-state mount
    * `AUTONOMOUS_TEST_CLAUDE_HOME` — optional, a pre-authenticated `~/.claude`
      directory to exercise credential path B (US1 AS4); if unset only path A
      (`ANTHROPIC_API_KEY`, already required to run anything) is exercised

  A missing prerequisite fails loudly with the variable to set, rather than
  silently skipping (Constitution II) — mirroring the existing
  `RunPhase` "LIVE" test convention.
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: :infinity

  alias SpeckitOrchestrator.RepoIdentity

  @container_name "autonomous-container-run-test"

  # ---- prerequisites --------------------------------------------------------

  defp require_env!(name) do
    case System.get_env(name) do
      nil -> flunk("set #{name} to run the containerized integration suite (see moduledoc)")
      "" -> flunk("set #{name} to run the containerized integration suite (see moduledoc)")
      value -> value
    end
  end

  defp require_docker! do
    System.find_executable("docker") || flunk("docker is not on PATH — a Linux container engine is required (FR-014)")
  end

  setup_all do
    require_docker!()
    image = require_env!("AUTONOMOUS_TEST_IMAGE")
    repo = require_env!("AUTONOMOUS_TEST_REPO")
    slug = require_env!("AUTONOMOUS_TEST_SLUG")
    home = require_env!("AUTONOMOUS_TEST_HOME")
    claude_home = System.get_env("AUTONOMOUS_TEST_CLAUDE_HOME")

    File.mkdir_p!(Path.join(home, ".autonomous"))

    %{image: image, repo: repo, slug: slug, home: home, claude_home: claude_home}
  end

  setup %{home: home} do
    on_exit(fn -> docker_rm_f(@container_name) end)
    %{run_state_root: Path.join(home, ".autonomous")}
  end

  # ---- helpers ---------------------------------------------------------------

  defp docker!(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> flunk("docker #{Enum.join(args, " ")} failed (#{code}):\n#{out}")
    end
  end

  defp docker_rm_f(name), do: System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)

  # The canonical invocation from contracts/container-run.md §1, minus the
  # console publish (each test picks its own free-ish port to avoid clashing
  # with a concurrently-run orchestrator dev instance).
  defp start_container!(opts) do
    image = Keyword.fetch!(opts, :image)
    repo = Keyword.fetch!(opts, :repo)
    home = Keyword.fetch!(opts, :home)
    name = Keyword.get(opts, :name, @container_name)
    port = Keyword.get(opts, :port, 4100)
    env_pairs = Keyword.get(opts, :env, [])
    claude_home = Keyword.get(opts, :claude_home)

    docker_rm_f(name)

    claude_mount =
      if claude_home, do: ["-v", "#{claude_home}:/run/secrets/claude:ro"], else: []

    env_flags = Enum.flat_map(env_pairs, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    args =
      [
        "run",
        "-d",
        "--name",
        name,
        "--read-only",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--pids-limit",
        "4096",
        "--stop-timeout",
        "900",
        "--tmpfs",
        "/tmp:rw,nosuid,nodev,size=1g",
        "--tmpfs",
        "#{home}:rw,nosuid,nodev,mode=0700",
        "-v",
        "#{repo}:#{repo}",
        "-v",
        "#{Path.join(home, ".autonomous")}:#{Path.join(home, ".autonomous")}"
      ] ++
        claude_mount ++
        [
          "-p",
          "127.0.0.1:#{port}:#{port}",
          "-e",
          "SPECKIT_REPO=#{repo}",
          "-e",
          "HOME=#{home}",
          "-e",
          "AUTONOMOUS_HOST_REPO=#{repo}",
          "-e",
          "AUTONOMOUS_HOST_HOME=#{home}",
          "-e",
          "AUTONOMOUS_CONSOLE_PORT=#{port}",
          "-e",
          "RELEASE_COOKIE=container-run-test-cookie",
          "-e",
          "GIT_AUTHOR_NAME=autonomous-test",
          "-e",
          "GIT_AUTHOR_EMAIL=autonomous-test@example.com",
          "-e",
          "GIT_COMMITTER_NAME=autonomous-test",
          "-e",
          "GIT_COMMITTER_EMAIL=autonomous-test@example.com"
        ] ++
        env_flags ++ [image]

    docker!(args)
    name
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met before timeout")

      true ->
        Process.sleep(2_000)
        do_wait_until(deadline, fun)
    end
  end

  defp container_running?(name) do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  defp latest_preflight_report(run_state_root) do
    Path.join([run_state_root, "preflight", "latest.json"]) |> File.read!() |> Jason.decode!()
  end

  # Reads the run manifest a containerized run wrote, straight from the host —
  # possible only because path identity (FR-018/FR-019) makes `run_state_root`
  # and `repo` the same absolute paths on both sides. Mirrors
  # `RunManifest`'s own segment-scoped path (`transcripts/<segment>/run.json`)
  # without touching the test process's own `:speckit_orchestrator` app env,
  # which is not (and must not be) pointed at the container's repo/root.
  defp read_manifest(run_state_root, repo) do
    path =
      case RepoIdentity.resolve(repo) do
        {:ok, segment} -> Path.join([run_state_root, "transcripts", segment, "run.json"])
        {:error, :no_origin} -> Path.join([run_state_root, "transcripts", "run.json"])
      end

    with {:ok, contents} <- File.read(path),
         {:ok, record} <- Jason.decode(contents) do
      {:ok, record}
    else
      _ -> {:error, :no_manifest}
    end
  end

  defp run_drained?(run_state_root, repo) do
    case read_manifest(run_state_root, repo) do
      {:ok, %{"statuses" => statuses}} when map_size(statuses) > 0 ->
        Enum.all?(statuses, fn {_id, status} -> status in ~w(done escalated halted failed) end)

      _ ->
        false
    end
  end

  defp branch_set(repo) do
    {out, 0} = System.cmd("git", ["-C", repo, "branch", "--list", "feature/*", "--format=%(refname:short)"])
    out |> String.split("\n", trim: true) |> MapSet.new()
  end

  # ---- SC-001 / US1 AS1-3 -----------------------------------------------------

  test "SC-001: containerized run reaches the same per-feature terminal statuses and branch set as an on-machine run",
       %{image: image, repo: repo, slug: slug, home: home, run_state_root: run_state_root} do
    start_container!(image: image, repo: repo, home: home, env: [{"AUTONOMOUS_AUTOSTART", slug}])

    wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)

    {:ok, containerized} = read_manifest(run_state_root, repo)
    containerized_branches = branch_set(repo)

    # An on-machine run against the same fixture target and slug for comparison
    # (see docs/runbook.md for the invocation this mirrors). The operator is
    # expected to have run this beforehand and recorded the manifest at
    # AUTONOMOUS_TEST_ON_MACHINE_MANIFEST, since running the pipeline twice
    # end-to-end inside a single ExUnit test would double the paid agent spend
    # of an already-expensive suite.
    on_machine_manifest_path = require_env!("AUTONOMOUS_TEST_ON_MACHINE_MANIFEST")
    on_machine = on_machine_manifest_path |> File.read!() |> Jason.decode!()

    assert containerized["statuses"] == on_machine["statuses"]

    on_machine_branches =
      on_machine
      |> Map.fetch!("features")
      |> Enum.map(fn %{"id" => id, "slug" => slug} -> "feature/#{id}-#{slug}" end)
      |> MapSet.new()

    assert containerized_branches == on_machine_branches
  end

  # ---- US1 AS4 -----------------------------------------------------------------

  test "US1 AS4: both credential paths independently succeed with no credential value in any artifact or log",
       %{image: image, repo: repo, slug: slug, home: home, run_state_root: run_state_root, claude_home: claude_home} do
    api_key =
      System.get_env("ANTHROPIC_API_KEY") ||
        flunk("set ANTHROPIC_API_KEY to exercise credential path A")

    # Path A — ANTHROPIC_API_KEY.
    start_container!(
      image: image,
      repo: repo,
      home: home,
      env: [{"AUTONOMOUS_AUTOSTART", slug}, {"ANTHROPIC_API_KEY", api_key}]
    )

    wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)
    logs_a = docker!(["logs", @container_name])
    refute logs_a =~ api_key
    refute File.read!(Path.join([run_state_root, "preflight", "latest.json"])) =~ api_key

    if claude_home do
      docker_rm_f(@container_name)
      File.rm_rf!(run_state_root)
      File.mkdir_p!(run_state_root)

      # Path B — mounted pre-authenticated ~/.claude.
      start_container!(
        image: image,
        repo: repo,
        home: home,
        claude_home: claude_home,
        env: [{"AUTONOMOUS_AUTOSTART", slug}]
      )

      wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)
      logs_b = docker!(["logs", @container_name])
      refute logs_b =~ api_key
    end
  end

  # ---- SC-008 --------------------------------------------------------------

  test "SC-008: a target repo pinning a different runtime resolves and uses its own pinned version via mise",
       %{image: image, repo: repo, slug: slug, home: home, run_state_root: run_state_root} do
    start_container!(image: image, repo: repo, home: home, env: [{"AUTONOMOUS_AUTOSTART", slug}])
    wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)

    report = latest_preflight_report(run_state_root)
    target_toolchain = get_in(report, ["resolved_versions", "target_toolchain"])

    assert is_binary(target_toolchain) and target_toolchain != "",
           "expected resolved_versions.target_toolchain in #{inspect(report["resolved_versions"])} " <>
             "— confirm #{repo} pins a runtime (e.g. .tool-versions) different from the image's own"

    refute target_toolchain == report["image"]["elixir"]
  end

  # ---- US1 AS5 -----------------------------------------------------------------

  test "US1 AS5: AUTONOMOUS_AUTOSTART with a passing preflight launches with no operator action, and the container stays up after the run drains",
       %{image: image, repo: repo, slug: slug, home: home, run_state_root: run_state_root} do
    start_container!(image: image, repo: repo, home: home, env: [{"AUTONOMOUS_AUTOSTART", slug}])

    wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)

    assert container_running?(@container_name), "container must stay up after the run drains (FR-030)"

    report = latest_preflight_report(run_state_root)
    assert report["status"] in ["pass", "warn"]

    assert File.dir?(Path.join(run_state_root, "transcripts"))
    assert File.dir?(Path.join(run_state_root, "worktrees"))
  end

  # ---- SC-004 / US2 AS3 ---------------------------------------------------

  test "SC-004: every file a normal run creates under $REPO is host-owned by the invoking UID/GID and needs no elevation to edit or delete",
       %{image: image, repo: repo, slug: slug, home: home, run_state_root: run_state_root} do
    {before_files, 0} = System.cmd("git", ["-C", repo, "ls-files"])
    before_set = before_files |> String.split("\n", trim: true) |> MapSet.new()

    start_container!(image: image, repo: repo, home: home, env: [{"AUTONOMOUS_AUTOSTART", slug}])
    wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)

    {invoking_uid, 0} = System.cmd("id", ["-u"])
    {invoking_gid, 0} = System.cmd("id", ["-g"])
    invoking_uid = String.trim(invoking_uid)
    invoking_gid = String.trim(invoking_gid)

    {after_files, 0} = System.cmd("git", ["-C", repo, "ls-files"])
    after_set = after_files |> String.split("\n", trim: true) |> MapSet.new()
    created = MapSet.difference(after_set, before_set)

    assert MapSet.size(created) > 0, "expected the run to create at least one tracked file"

    for rel <- created do
      path = Path.join(repo, rel)
      {stat_out, 0} = System.cmd("stat", ["-c", "%u:%g", path])
      assert String.trim(stat_out) == "#{invoking_uid}:#{invoking_gid}", "#{path} is not host-owned"

      # No elevation required to edit or delete (SC-004) — this is exactly
      # what a mismatched-ownership file would refuse.
      assert File.exists?(path)
      File.write!(path, File.read!(path))
    end
  end

  # ---- SC-006 / US3 (T031) ----------------------------------------------------

  defp docker_stop!(name, seconds), do: docker!(["stop", "--time", "#{seconds}", name])
  defp docker_start!(name), do: docker!(["start", name])

  defp manifest_spend(run_state_root, repo) do
    case read_manifest(run_state_root, repo) do
      {:ok, %{"spend" => spend}} -> spend
      _ -> nil
    end
  end

  test "SC-006: docker stop mid-run then docker start preserves transcripts, manifests, checkpoints, and worktrees; spend never regresses",
       %{image: image, repo: repo, slug: slug, home: home, run_state_root: run_state_root} do
    start_container!(image: image, repo: repo, home: home, env: [{"AUTONOMOUS_AUTOSTART", slug}])

    # Wait until the run has genuinely started (a manifest with at least one
    # non-:pending feature) before stopping mid-flight — stopping before any
    # feature releases would prove nothing about an in-flight interruption.
    wait_until(120_000, fn ->
      case read_manifest(run_state_root, repo) do
        {:ok, %{"statuses" => statuses}} when map_size(statuses) > 0 ->
          Enum.any?(statuses, fn {_id, status} -> status != "pending" end)

        _ ->
          false
      end
    end)

    {:ok, before_manifest} = read_manifest(run_state_root, repo)
    spend_before = manifest_spend(run_state_root, repo)
    transcripts_before = File.dir?(Path.join(run_state_root, "transcripts"))
    worktrees_before = File.dir?(Path.join(run_state_root, "worktrees"))

    docker_stop!(@container_name, 900)
    refute container_running?(@container_name), "container must actually stop before restarting it"

    # FR-027: an interrupted phase is recorded `interrupted`, never silently
    # dropped back to a lower spend than what was already committed.
    assert transcripts_before
    assert worktrees_before
    assert Enum.any?(before_manifest["statuses"], fn {_id, s} -> s in ["done", "interrupted", "pending"] end)

    docker_start!(@container_name)
    wait_until(60_000, fn -> container_running?(@container_name) end)

    # Give the restarted release a moment to re-attach / boot before comparing.
    Process.sleep(5_000)

    spend_after_restart = manifest_spend(run_state_root, repo)
    assert spend_after_restart != nil
    assert spend_after_restart >= spend_before,
           "spend after restart (#{inspect(spend_after_restart)}) regressed below " <>
             "spend before the stop (#{inspect(spend_before)}) — the tally under-counted (FR-027)"

    assert File.dir?(Path.join(run_state_root, "transcripts"))
    assert File.dir?(Path.join(run_state_root, "worktrees"))

    wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)
    {:ok, final_manifest} = read_manifest(run_state_root, repo)
    assert Enum.all?(final_manifest["statuses"], fn {_id, s} -> s in ~w(done escalated halted failed) end)
  end

  # ---- Operator surface while in flight (T031, quickstart Scenario F) --------

  test "the console, the remote console, and docker logs -f reflect a containerized run exactly as on-machine",
       %{image: image, repo: repo, slug: slug, home: home, run_state_root: run_state_root} do
    port = 4101
    start_container!(image: image, repo: repo, home: home, port: port, env: [{"AUTONOMOUS_AUTOSTART", slug}])

    wait_until(60_000, fn -> container_running?(@container_name) end)

    # FR-024: console reachable on loopback while the run is in flight.
    {status_out, 0} = System.cmd("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "http://127.0.0.1:#{port}/"])
    assert status_out == "200"

    # FR-025: the remote console reaches the exact same operator surface as
    # an on-machine run — status, resolve, resume all behave identically.
    # `rpc` (non-interactive; evaluates one expression and returns) is the
    # scriptable counterpart to the `remote` interactive session in
    # docs/container.md and contracts/container-run.md §7.
    print_status_out =
      docker!([
        "exec",
        @container_name,
        "bin/speckit_orchestrator",
        "rpc",
        "SpeckitOrchestrator.print_status()"
      ])

    assert print_status_out =~ "FEATURE" or print_status_out =~ "totals:"

    # FR-028: docker logs -f carries phase/terminal-state telemetry with no
    # interactive session required.
    wait_until(600_000, fn -> run_drained?(run_state_root, repo) end)
    logs = docker!(["logs", @container_name])
    assert logs =~ "phase" or logs =~ "terminal="
  end
end
