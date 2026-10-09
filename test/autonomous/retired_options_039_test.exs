defmodule Autonomous.RetiredOptions039Test do
  @moduledoc """
  039 (T011, SC-005): `:budget_usd` (cost is informational) and
  `:containment_profile` (one containment behaviour) join 019's retired
  settings. Refused by name — any value, including `nil` — first, before any
  side effect, at every entry point that starts or continues a run
  (contracts/run-start.md § 1); refused at boot as app env (§ 2); refused by
  `LiveConfig` as a retired field. The rendered message names the key and why
  it is gone. The parked-run-stays-parked half of `continue_run/1` lives in
  `continue_run_atomic_test.exs` with the rest of 035's refusal matrix.
  """

  use Autonomous.StoreCase, async: false

  alias Autonomous.{Config, Feature, LiveConfig, RepoIdentity, Report, Worktree}

  @both [budget_usd: 10.0, containment_profile: "strict"]
  @both_refused {:error,
                 {:preflight,
                  [{:retired_option, :budget_usd}, {:retired_option, :containment_profile}]}}

  defp feat(id),
    do: %Feature{id: id, number: String.to_integer(id), slug: "f#{id}", path: "#{id}.md"}

  defp refused(key), do: {:error, {:preflight, [{:retired_option, key}]}}

  defp repo_id, do: RepoIdentity.partition(Config.repo())

  defp assert_nothing_started do
    refute Process.whereis(Autonomous.Coordinator)
    assert {:ok, []} = Store.runs(repo_id())
    refute File.exists?(Worktree.locate(feat("001")).path)
  end

  describe "run/1" do
    test "refuses :budget_usd, any value including nil" do
      for value <- [5.0, 0, nil] do
        assert Autonomous.run(budget_usd: value, features: [feat("001")]) ==
                 refused(:budget_usd)
      end

      assert_nothing_started()
    end

    test "refuses :containment_profile, any value including an invalid one" do
      for value <- ["strict", "permissive", :permissive, "bogus", nil] do
        assert Autonomous.run(containment_profile: value, features: [feat("001")]) ==
                 refused(:containment_profile)
      end

      assert_nothing_started()
    end

    test "refuses both at once, in @retired_opts order" do
      assert Autonomous.run(@both ++ [features: [feat("001")]]) == @both_refused
      assert_nothing_started()
    end
  end

  describe "run_spec/2" do
    test "refuses each key, and both together" do
      assert Autonomous.run_spec("Add a health-check endpoint", budget_usd: nil) ==
               refused(:budget_usd)

      assert Autonomous.run_spec("Add a health-check endpoint", containment_profile: "strict") ==
               refused(:containment_profile)

      assert Autonomous.run_spec("Add a health-check endpoint", @both) == @both_refused
      assert_nothing_started()
    end
  end

  describe "resume/2 and resume_run/1" do
    test "refuse each key before touching the store" do
      assert Autonomous.resume("001", budget_usd: nil) == refused(:budget_usd)

      assert Autonomous.resume("001", containment_profile: "permissive") ==
               refused(:containment_profile)

      assert Autonomous.resume("001", @both) == @both_refused

      assert Autonomous.resume_run(budget_usd: 1.0) == refused(:budget_usd)
      assert Autonomous.resume_run(containment_profile: "strict") == refused(:containment_profile)
      assert Autonomous.resume_run(@both) == @both_refused
      assert_nothing_started()
    end
  end

  describe "continue_run/1" do
    test "with no parked run, still the retired-option error — not :no_parked_run" do
      assert Store.parked_run(repo_id()) == :none

      assert Autonomous.continue_run(budget_usd: nil) == refused(:budget_usd)

      assert Autonomous.continue_run(containment_profile: "strict") ==
               refused(:containment_profile)

      assert Autonomous.continue_run(@both) == @both_refused
      assert_nothing_started()
    end
  end

  describe "LiveConfig" do
    test "budget_usd is a retired-field error naming the key; nothing applied" do
      assert {:error, %{budget_usd: message}} = LiveConfig.apply(%{budget_usd: 50})
      assert message =~ "budget_usd"
      assert message =~ "retired"
    end
  end

  describe "rendered reason" do
    test "names the key and why it is gone" do
      assert Report.format_reason({:retired_option, :budget_usd}) =~ "budget_usd"
      assert Report.format_reason({:retired_option, :budget_usd}) =~ "runs never stop on spend"

      assert Report.format_reason({:retired_option, :containment_profile}) =~
               "containment_profile"

      assert Report.format_reason({:retired_option, :containment_profile}) =~
               "one containment behaviour"

      {:error, preflight} = @both_refused
      rendered = Report.format_reason(preflight)
      assert rendered =~ "budget_usd"
      assert rendered =~ "containment_profile"
    end
  end

  describe "Application.start/2 aborts boot when a retired app-env key is present" do
    @tag :boot_subprocess
    test "aborts naming :budget_usd" do
      output = boot_script("Application.put_env(:autonomous, :budget_usd, 25.0)")

      assert output =~ "budget_usd"
      refute output =~ "APP_BOOT_OK"
    end

    @tag :boot_subprocess
    test "aborts naming :containment_profile" do
      output = boot_script("Application.put_env(:autonomous, :containment_profile, :strict)")

      assert output =~ "containment_profile"
      refute output =~ "APP_BOOT_OK"
    end
  end

  # Isolated subprocess, as in RetiredSettingsTest: a real boot abort would
  # tear down the shared app the rest of the suite depends on.
  defp boot_script(extra_config) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "speckit_retired_039_test_#{System.unique_integer([:positive])}"
      )

    script = """
    Application.put_env(:autonomous, :store_dir, #{inspect(dir)})
    #{extra_config}

    case Application.ensure_all_started(:autonomous) do
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

defmodule Autonomous.ContainerNoticeRun039Test do
  @moduledoc """
  039 (FR-014, contracts/run-start.md § 3–4): a run started outside the
  container (always the case under the test config) logs the container
  notice and still starts — the notice is never an error.
  """

  use Autonomous.StoreCase, async: false

  import ExUnit.CaptureLog

  alias Autonomous.Feature

  test "a run outside the container logs the notice and proceeds" do
    me = self()
    feature = %Feature{id: "001", number: 1, slug: "f001", path: "001.md"}

    runner = fn f, notify ->
      send(me, {:ran, f.id})
      notify.(f.id, :done, nil)
    end

    log =
      capture_log(fn ->
        assert {:ok, pid} = Autonomous.run(features: [feature], runner: runner, owner: me)
        assert_receive {:run_complete, report}, 2_000
        assert report.done == ["001"]
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

    assert_received {:ran, "001"}
    assert log =~ "OUTSIDE the container"
    assert log =~ "The run proceeds"
  end
end
