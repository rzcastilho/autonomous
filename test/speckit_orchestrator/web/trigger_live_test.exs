defmodule SpeckitOrchestrator.Web.TriggerLiveTest do
  # Overrides global Config app env (repo/breakdown_dir/pr_workflow) and may
  # start the real named Coordinator via a successful Start — must not run
  # concurrently with another test claiming that name or mutating Config.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Config, Coordinator}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  @valid_dir Path.expand("../../fixtures/breakdown", __DIR__)
  @cyclic_dir Path.expand("../../fixtures/breakdown_cyclic", __DIR__)

  setup do
    prior = %{
      repo: Application.get_env(:speckit_orchestrator, :repo),
      breakdown_dir: Application.get_env(:speckit_orchestrator, :breakdown_dir),
      pr_workflow: Application.get_env(:speckit_orchestrator, :pr_workflow),
      console_test_runner: Application.get_env(:speckit_orchestrator, :console_test_runner)
    }

    on_exit(fn ->
      Enum.each(prior, fn
        {k, nil} -> Application.delete_env(:speckit_orchestrator, k)
        {k, v} -> Application.put_env(:speckit_orchestrator, k, v)
      end)

      if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)
    end)

    Application.put_env(:speckit_orchestrator, :console_test_runner, fn _feature, _notify ->
      :ok
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp point_backlog_at(dir) do
    Application.put_env(:speckit_orchestrator, :repo, dir)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "")
  end

  test "Backlog mode shows source/count/DAG-validated/max-concurrency/budget; Start enabled on a valid DAG",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, _view, html} = live(conn, "/trigger")

    assert html =~ ~s(data-mode-panel="backlog")
    assert html =~ @valid_dir
    assert html =~ ">7<"
    assert html =~ ~s(data-dag-valid="true")
    refute html =~ ~s(data-action="start-backlog" disabled)
  end

  test "Backlog mode: changing the breakdown package recalculates the preview (count + source)",
       %{conn: conn} do
    src = Path.expand("../../fixtures/breakdown_packages", __DIR__)
    repo = Path.join(System.tmp_dir!(), "trigger_waves_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(repo, "specs/autonomous/breakdown"))
    File.cp_r!(src, Path.join(repo, "specs/autonomous/breakdown"))
    on_exit(fn -> File.rm_rf(repo) end)
    Application.put_env(:speckit_orchestrator, :repo, repo)

    {:ok, view, html} = live(conn, "/trigger")

    # Defaults to the first alphabetical package (alpha), 1 feature.
    assert html =~ "alpha"
    assert html =~ ">1<"

    # Switching the wrapped-in-a-form select delivers %{"slug" => ...} and the
    # preview recomputes for beta (also 1 feature, different source path).
    html =
      view
      |> element(~s(form[data-form="package-picker"]))
      |> render_change(%{"slug" => "beta"})

    assert html =~ "breakdown/beta"
    assert html =~ ~s(data-dag-valid="true")
  end

  test "Backlog mode disables Start and surfaces the reason when Backlog.load!/1 raises (cycle)",
       %{conn: conn} do
    point_backlog_at(@cyclic_dir)

    {:ok, _view, html} = live(conn, "/trigger")

    assert html =~ ~s(data-dag-valid="false")
    assert html =~ ~s(data-action="start-backlog" disabled)
    assert html =~ "cycle"
  end

  test "Backlog mode with no packages names the standard specs/autonomous/breakdown location",
       %{conn: conn} do
    tmp = System.tmp_dir!() |> Path.join("trigger-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    # No specs/autonomous/breakdown packages and no legacy breakdown dir — the
    # fallback also finds nothing, so the empty-state hint must lead the operator
    # to the standardized location rather than the legacy docs/breakdown path.
    Application.put_env(:speckit_orchestrator, :repo, tmp)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "docs/breakdown")

    {:ok, _view, html} = live(conn, "/trigger")

    assert html =~ ~s(data-hint="no-packages")
    assert html =~ "specs/autonomous/breakdown"
    assert html =~ ~s(data-action="start-backlog" disabled)
  end

  test "Single-spec mode previews auto-assigned id + derived slug as the operator types",
       %{conn: conn} do
    tmp = System.tmp_dir!() |> Path.join("trigger-preview-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    Application.put_env(:speckit_orchestrator, :repo, tmp)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "docs/breakdown")

    {:ok, view, _html} = live(conn, "/trigger")

    html = render_click(view, "set_mode", %{"mode" => "single_spec"})
    assert html =~ ~s(data-mode-panel="single-spec")

    html = render_change(view, "update_description", %{"description" => "Add CSV export"})
    assert html =~ ~s(data-preview="id-slug")
    assert html =~ "001"
    assert html =~ "add-csv-export"
  end

  test "Single-spec mode: empty description shows a field error and does not call run_spec/2",
       %{conn: conn} do
    Application.put_env(
      :speckit_orchestrator,
      :console_test_runner,
      fn _feature, _notify -> raise "run_spec/2 must not be called for a blank description" end
    )

    {:ok, view, _html} = live(conn, "/trigger")
    render_click(view, "set_mode", %{"mode" => "single_spec"})

    html = render_submit(view, "start_single_spec", %{"description" => "   "})

    assert html =~ "Description is required"
    refute Process.whereis(Coordinator)
  end

  test "enabling the stacked PR toggle before Start reflects PR-workflow mode + effective concurrency 1",
       %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, view, html} = live(conn, "/trigger")
    refute html =~ "effective concurrency: 1"

    html = render_click(view, "toggle_pr_workflow", %{})

    assert html =~ ~s(data-pr-workflow="true")
    assert html =~ "effective concurrency: 1"
  end

  test "successful backlog Start navigates to / and shows a toast confirmation", %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, view, _html} = live(conn, "/trigger")

    result = render_click(view, "start_backlog", %{})
    {:ok, _mc_view, mc_html} = follow_redirect(result, conn)

    assert mc_html =~ "Backlog run started"
    assert Process.whereis(Coordinator)
  end

  # Start used to mirror the toggle into app env, so one start with the toggle
  # off permanently overwrote the node's configured default (including one set
  # from SPECKIT_PR_WORKFLOW) for every later run and every later mount here.
  test "Start does not write the toggle into app env — the configured default survives", %{
    conn: conn
  } do
    point_backlog_at(@valid_dir)
    Application.put_env(:speckit_orchestrator, :pr_workflow, true)

    {:ok, view, html} = live(conn, "/trigger")
    # Mount seeds the toggle from the configured default...
    assert html =~ ~s(data-pr-workflow="true")

    # ...the operator turns it off for this one run...
    html = render_click(view, "toggle_pr_workflow", %{})
    assert html =~ ~s(data-pr-workflow="false")

    result = render_click(view, "start_backlog", %{})
    {:ok, _mc_view, _mc_html} = follow_redirect(result, conn)

    # ...and the node-wide default is untouched, so the next run/mount is
    # still stacked.
    assert Config.pr_workflow?() == true

    {:ok, _view2, html2} = live(conn, "/trigger")
    assert html2 =~ ~s(data-pr-workflow="true")
  end

  # ---- 017-analyze-auto-remediation launch controls (contracts/telemetry-console.md §4)

  describe "auto-remediation launch controls" do
    setup do
      prior = %{
        auto_remediation: Application.get_env(:speckit_orchestrator, :auto_remediation),
        auto_remediation_threshold:
          Application.get_env(:speckit_orchestrator, :auto_remediation_threshold),
        auto_remediation_attempt_limit:
          Application.get_env(:speckit_orchestrator, :auto_remediation_attempt_limit)
      }

      on_exit(fn ->
        Enum.each(prior, fn
          {k, nil} -> Application.delete_env(:speckit_orchestrator, k)
          {k, v} -> Application.put_env(:speckit_orchestrator, k, v)
        end)
      end)

      :ok
    end

    test "the three controls are pre-filled from Config (AS-8)", %{conn: conn} do
      point_backlog_at(@valid_dir)
      Application.put_env(:speckit_orchestrator, :auto_remediation, true)
      Application.put_env(:speckit_orchestrator, :auto_remediation_threshold, :high)
      Application.put_env(:speckit_orchestrator, :auto_remediation_attempt_limit, 2)

      {:ok, _view, html} = live(conn, "/trigger")

      assert html =~ ~s(data-auto-remediation="true")
      assert html =~ ~s(<option value="high" selected)
      assert html =~ ~s(data-remediation-limit)
      assert html =~ ~s(value="2")
    end

    test "threshold and limit are disabled while the switch is off", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, view, html} = live(conn, "/trigger")
      refute html =~ ~s(data-remediation-threshold="" disabled)
      refute html =~ ~s(data-remediation-limit="" disabled)

      html = render_click(view, "toggle_auto_remediation", %{})

      assert html =~ ~s(data-auto-remediation="false")
      assert html =~ ~s(data-remediation-threshold="" disabled="")
      assert html =~ ~s(data-remediation-limit="" disabled="")
      assert html =~ ~s(class="controls-disabled")
    end

    test "an out-of-range attempt limit is refused before the run starts (AS-9, FR-010e)", %{
      conn: conn
    } do
      point_backlog_at(@valid_dir)

      {:ok, view, _html} = live(conn, "/trigger")

      render_change(
        view,
        "update_remediation",
        %{"threshold" => "high", "attempt_limit" => "7"}
      )

      html = render_click(view, "start_backlog", %{})

      assert html =~ ~s(data-error="auto-remediation-limit")
      refute Process.whereis(Coordinator)
    end

    test "an unrecognized threshold is refused before the run starts (FR-010e)", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, view, _html} = live(conn, "/trigger")

      render_change(
        view,
        "update_remediation",
        %{"threshold" => "urgent", "attempt_limit" => "2"}
      )

      html = render_click(view, "start_backlog", %{})

      assert html =~ ~s(data-error="auto-remediation-threshold")
      refute Process.whereis(Coordinator)
    end

    test "a run launched with the loop off leaves the next mount's defaults untouched (FR-010f)",
         %{conn: conn} do
      point_backlog_at(@valid_dir)
      Application.put_env(:speckit_orchestrator, :auto_remediation, true)

      {:ok, view, html} = live(conn, "/trigger")
      assert html =~ ~s(data-auto-remediation="true")

      html = render_click(view, "toggle_auto_remediation", %{})
      assert html =~ ~s(data-auto-remediation="false")

      result = render_click(view, "start_backlog", %{})
      {:ok, _mc_view, _mc_html} = follow_redirect(result, conn)

      assert Config.auto_remediation?() == true

      {:ok, _view2, html2} = live(conn, "/trigger")
      assert html2 =~ ~s(data-auto-remediation="true")
    end
  end
end
