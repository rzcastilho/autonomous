defmodule SpeckitOrchestrator.RetiredSettingsTest do
  @moduledoc """
  019 (T029): `:pr_workflow`/`:max_concurrency` are retired — every run is a
  stacked sequential run, so there is no run-shape decision left to make.
  These are refused, not silently ignored, at every entry point that starts
  or continues a run (contracts/run-start.md § Refused options), and the
  application refuses to boot at all against a config that still names one
  (contracts/run-start.md § 3).
  """

  use ExUnit.Case, async: false

  alias SpeckitOrchestrator.Feature

  defp feat(id),
    do: %Feature{id: id, number: String.to_integer(id), slug: "f#{id}", path: "#{id}.md"}

  describe "run/1 refuses retired options before any side effect" do
    test "refuses :pr_workflow" do
      assert SpeckitOrchestrator.run(pr_workflow: true, features: [feat("001")]) ==
               {:error, {:preflight, [{:retired_option, :pr_workflow}]}}

      refute Process.whereis(SpeckitOrchestrator.Coordinator)
    end

    test "refuses :max_concurrency" do
      assert SpeckitOrchestrator.run(max_concurrency: 3, features: [feat("001")]) ==
               {:error, {:preflight, [{:retired_option, :max_concurrency}]}}

      refute Process.whereis(SpeckitOrchestrator.Coordinator)
    end

    test "refuses both at once, naming both" do
      {:error, {:preflight, problems}} =
        SpeckitOrchestrator.run(pr_workflow: false, max_concurrency: 1, features: [feat("001")])

      assert {:retired_option, :pr_workflow} in problems
      assert {:retired_option, :max_concurrency} in problems
    end
  end

  describe "run_spec/2 refuses retired options (delegates to run/1)" do
    test "refuses :pr_workflow" do
      assert SpeckitOrchestrator.run_spec("Add a health-check endpoint", pr_workflow: true) ==
               {:error, {:preflight, [{:retired_option, :pr_workflow}]}}
    end

    test "refuses :max_concurrency" do
      assert SpeckitOrchestrator.run_spec("Add a health-check endpoint", max_concurrency: 4) ==
               {:error, {:preflight, [{:retired_option, :max_concurrency}]}}
    end
  end

  describe "resume/2 and resume_run/1 refuse retired options" do
    test "resume/2 refuses before touching the store" do
      assert SpeckitOrchestrator.resume("001", pr_workflow: true) ==
               {:error, {:preflight, [{:retired_option, :pr_workflow}]}}
    end

    test "resume_run/1 refuses before touching the store" do
      assert SpeckitOrchestrator.resume_run(max_concurrency: 2) ==
               {:error, {:preflight, [{:retired_option, :max_concurrency}]}}
    end
  end

  describe "Application.start/2 aborts boot when a retired app-env key is present" do
    @tag :boot_subprocess
    test "aborts naming :pr_workflow" do
      output = boot_script("Application.put_env(:speckit_orchestrator, :pr_workflow, true)")

      assert output =~ "pr_workflow"
      refute output =~ "APP_BOOT_OK"
    end

    @tag :boot_subprocess
    test "aborts naming :max_concurrency" do
      output = boot_script("Application.put_env(:speckit_orchestrator, :max_concurrency, 3)")

      assert output =~ "max_concurrency"
      refute output =~ "APP_BOOT_OK"
    end

    @tag :boot_subprocess
    test "boots clean with neither key set" do
      output = boot_script("")

      assert output =~ "APP_BOOT_OK"
    end
  end

  # ---- helpers --------------------------------------------------------------

  # Isolated subprocess (mirrors Store.BootTest's `boot_script/2`): the real
  # `Application.start/2` mutates process-global OTP application state, so
  # exercising a boot abort in-process would tear down the shared,
  # already-booted app the rest of the suite depends on.
  defp boot_script(extra_config) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "speckit_retired_settings_test_#{System.unique_integer([:positive])}"
      )

    script = """
    Application.put_env(:speckit_orchestrator, :store_dir, #{inspect(dir)})
    #{extra_config}

    case Application.ensure_all_started(:speckit_orchestrator) do
      {:ok, _apps} -> IO.puts("APP_BOOT_OK")
      {:error, reason} -> IO.puts("APP_BOOT_ERROR " <> inspect(reason))
    end
    """

    {output, _exit_status} =
      System.cmd("mix", ["run", "--no-start", "-e", script],
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    File.rm_rf(dir)
    output
  end
end
