defmodule SpeckitOrchestrator.BootTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.Boot
  alias SpeckitOrchestrator.Container.Env

  setup do
    repo = Path.join(System.tmp_dir!(), "boot_test_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, ".git"))

    state_root =
      Path.join(System.tmp_dir!(), "boot_test_state_#{System.unique_integer([:positive])}")

    File.mkdir_p!(state_root)

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(state_root)
    end)

    %{repo: repo, state_root: state_root}
  end

  defp unique_name, do: :"boot_test_#{System.unique_integer([:positive])}"

  defp base_preflight_opts(repo, state_root) do
    [
      repo: repo,
      run_state_root: state_root,
      tool_probe: fn _tool -> {:ok, "1.0.0"} end,
      mountinfo_read: fn -> {:error, :enoent} end,
      writable?: fn _path -> true end,
      target_pack_verify: fn _repo -> :ok end,
      image_read: fn -> {:error, :not_containerized} end,
      containerized?: fn -> false end,
      euid: fn -> 1000 end,
      home_env: "/home/alice",
      claude_config_present?: fn -> false end,
      gh_token_present?: true,
      anthropic_key_present?: true
    ]
  end

  defp failing_preflight_opts(repo, state_root) do
    Keyword.put(base_preflight_opts(repo, state_root), :euid, fn -> 0 end)
  end

  test "idle by default: no AUTONOMOUS_AUTOSTART, no run started", %{
    repo: repo,
    state_root: state_root
  } do
    env = %Env{repo: repo}
    test_pid = self()
    runner = fn opts -> send(test_pid, {:runner_called, opts}) end

    {:ok, pid} =
      Boot.start_link(
        name: unique_name(),
        env: env,
        preflight_opts: base_preflight_opts(repo, state_root) ++ [env: env],
        runner: runner
      )

    refute_receive {:runner_called, _}, 200
    assert Process.alive?(pid)
  end

  test "autostart launches the named breakdown run once preflight passes", %{
    repo: repo,
    state_root: state_root
  } do
    env = %Env{repo: repo, autostart: {:breakdown, "003-recovery-reconciliation"}}
    test_pid = self()
    runner = fn opts -> send(test_pid, {:runner_called, opts}) end

    {:ok, _pid} =
      Boot.start_link(
        name: unique_name(),
        env: env,
        preflight_opts: base_preflight_opts(repo, state_root) ++ [env: env],
        runner: runner
      )

    assert_receive {:runner_called, opts}, 500
    assert opts[:slug] == "003-recovery-reconciliation"
  end

  test "ad-hoc autostart launches with scope: :ad_hoc", %{repo: repo, state_root: state_root} do
    env = %Env{repo: repo, autostart: :ad_hoc}
    test_pid = self()
    runner = fn opts -> send(test_pid, {:runner_called, opts}) end

    {:ok, _pid} =
      Boot.start_link(
        name: unique_name(),
        env: env,
        preflight_opts: base_preflight_opts(repo, state_root) ++ [env: env],
        runner: runner
      )

    assert_receive {:runner_called, opts}, 500
    assert opts[:scope] == :ad_hoc
  end

  test "a failing preflight leaves the container idle with no run and no success signal", %{
    repo: repo,
    state_root: state_root
  } do
    env = %Env{repo: repo, autostart: {:breakdown, "003-recovery-reconciliation"}}
    test_pid = self()
    runner = fn opts -> send(test_pid, {:runner_called, opts}) end

    {:ok, pid} =
      Boot.start_link(
        name: unique_name(),
        env: env,
        preflight_opts: failing_preflight_opts(repo, state_root) ++ [env: env],
        runner: runner
      )

    refute_receive {:runner_called, _}, 200
    assert Process.alive?(pid)
  end

  test "never blocks its supervisor's init — start_link returns before a slow runner completes",
       %{repo: repo, state_root: state_root} do
    env = %Env{repo: repo, autostart: {:breakdown, "003-recovery-reconciliation"}}
    test_pid = self()

    runner = fn opts ->
      Process.sleep(150)
      send(test_pid, {:runner_called, opts})
    end

    {elapsed_us, {:ok, _pid}} =
      :timer.tc(fn ->
        Boot.start_link(
          name: unique_name(),
          env: env,
          preflight_opts: base_preflight_opts(repo, state_root) ++ [env: env],
          runner: runner
        )
      end)

    assert elapsed_us < 50_000
    assert_receive {:runner_called, _}, 500
  end
end
