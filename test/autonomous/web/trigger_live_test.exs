defmodule Autonomous.Web.TriggerLiveTest do
  # Overrides global Config app env (repo/breakdown_dir) and may start the
  # real named Coordinator via a successful Start — must not run concurrently
  # with another test claiming that name or mutating Config.
  use Autonomous.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Config, ConsoleProjection, Coordinator, Feature, RepoIdentity}

  @endpoint Autonomous.Web.Endpoint

  @valid_dir Path.expand("../../fixtures/breakdown", __DIR__)

  setup do
    prior = %{
      repo: Application.get_env(:autonomous, :repo),
      breakdown_dir: Application.get_env(:autonomous, :breakdown_dir),
      console_test_runner: Application.get_env(:autonomous, :console_test_runner)
    }

    on_exit(fn ->
      Enum.each(prior, fn
        {k, nil} -> Application.delete_env(:autonomous, k)
        {k, v} -> Application.put_env(:autonomous, k, v)
      end)

      if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)
    end)

    Application.put_env(:autonomous, :console_test_runner, fn _feature, _notify ->
      :ok
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp point_backlog_at(dir) do
    Application.put_env(:autonomous, :repo, dir)
    Application.put_env(:autonomous, :breakdown_dir, "")
  end

  test "Backlog mode shows source/count/DAG-validated; Start enabled on a valid DAG",
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
    Application.put_env(:autonomous, :repo, repo)

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

  test "Backlog mode disables Start and surfaces the reason when Backlog.load!/1 raises (duplicate numbers)",
       %{conn: conn} do
    point_backlog_at(Path.expand("../../fixtures/breakdown_duplicate", __DIR__))

    {:ok, _view, html} = live(conn, "/trigger")

    assert html =~ ~s(data-dag-valid="false")
    assert html =~ ~s(data-action="start-backlog" disabled)
  end

  test "Backlog mode with no packages names the standard specs/autonomous/breakdown location",
       %{conn: conn} do
    tmp = System.tmp_dir!() |> Path.join("trigger-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    # No specs/autonomous/breakdown packages and no legacy breakdown dir — the
    # fallback also finds nothing, so the empty-state hint must lead the operator
    # to the standardized location rather than the legacy docs/breakdown path.
    Application.put_env(:autonomous, :repo, tmp)
    Application.put_env(:autonomous, :breakdown_dir, "docs/breakdown")

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
    Application.put_env(:autonomous, :repo, tmp)
    Application.put_env(:autonomous, :breakdown_dir, "docs/breakdown")

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
      :autonomous,
      :console_test_runner,
      fn _feature, _notify -> raise "run_spec/2 must not be called for a blank description" end
    )

    {:ok, view, _html} = live(conn, "/trigger")
    render_click(view, "set_mode", %{"mode" => "single_spec"})

    html = render_submit(view, "start_single_spec", %{"description" => "   "})

    assert html =~ "Description is required"
    refute Process.whereis(Coordinator)
  end

  # 019, SC-001: no run-mode or concurrency decision exists anywhere on this
  # form — the trigger screen only describes the one run shape there is.
  test "the trigger screen renders zero run-shape inputs", %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, _view, html} = live(conn, "/trigger")

    refute html =~ ~s(phx-click="toggle_pr_workflow")
    refute html =~ "data-pr-workflow"
    refute html =~ "effective concurrency"
    refute html =~ ~s(name="max_concurrency")
    assert html =~ "stacked sequential"
  end

  test "successful backlog Start navigates to / and shows a toast confirmation", %{conn: conn} do
    point_backlog_at(@valid_dir)

    {:ok, view, _html} = live(conn, "/trigger")

    result = render_click(view, "start_backlog", %{})
    {:ok, _mc_view, mc_html} = follow_redirect(result, conn)

    assert mc_html =~ "Backlog run started"
    assert Process.whereis(Coordinator)
  end

  # ---- 017-analyze-auto-remediation launch controls (contracts/telemetry-console.md §4)

  describe "auto-remediation launch controls" do
    setup do
      prior = %{
        auto_remediation: Application.get_env(:autonomous, :auto_remediation),
        auto_remediation_threshold: Application.get_env(:autonomous, :auto_remediation_threshold),
        auto_remediation_attempt_limit:
          Application.get_env(:autonomous, :auto_remediation_attempt_limit)
      }

      on_exit(fn ->
        Enum.each(prior, fn
          {k, nil} -> Application.delete_env(:autonomous, k)
          {k, v} -> Application.put_env(:autonomous, k, v)
        end)
      end)

      :ok
    end

    test "the three controls are pre-filled from Config (AS-8)", %{conn: conn} do
      point_backlog_at(@valid_dir)
      Application.put_env(:autonomous, :auto_remediation, true)
      Application.put_env(:autonomous, :auto_remediation_threshold, :high)
      Application.put_env(:autonomous, :auto_remediation_attempt_limit, 2)

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
      assert html =~ ~s(controls-disabled)
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
      Application.put_env(:autonomous, :auto_remediation, true)

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

  # ---- 021-analyze-exhaustion-policy launch control (T032, contracts/exhaustion-policy.md §5)

  describe "exhaustion policy launch control" do
    setup do
      prior = %{
        auto_remediation: Application.get_env(:autonomous, :auto_remediation),
        auto_remediation_exhaustion_policy:
          Application.get_env(:autonomous, :auto_remediation_exhaustion_policy)
      }

      on_exit(fn ->
        Enum.each(prior, fn
          {k, nil} -> Application.delete_env(:autonomous, k)
          {k, v} -> Application.put_env(:autonomous, k, v)
        end)
      end)

      :ok
    end

    test "the control is pre-filled from Config's default (escalate)", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, _view, html} = live(conn, "/trigger")

      assert html =~ ~s(data-exhaustion-policy)
      assert html =~ ~s(<option value="escalate" selected)
    end

    test "an unrecognized exhaustion policy is refused before the run starts, naming the setting",
         %{conn: conn} do
      point_backlog_at(@valid_dir)
      Application.put_env(:autonomous, :auto_remediation, true)

      {:ok, view, _html} = live(conn, "/trigger")

      render_change(view, "update_remediation", %{"exhaustion_policy" => "urgent"})

      html = render_click(view, "start_backlog", %{})

      assert html =~ ~s(data-error="auto-remediation-exhaustion-policy")
      refute Process.whereis(Coordinator)
    end

    test "choosing proceed captures it into the started run's opts", %{conn: conn} do
      point_backlog_at(@valid_dir)
      Application.put_env(:autonomous, :auto_remediation, true)

      {:ok, view, _html} = live(conn, "/trigger")

      render_change(view, "update_remediation", %{"exhaustion_policy" => "proceed"})

      result = render_click(view, "start_backlog", %{})
      {:ok, _mc_view, mc_html} = follow_redirect(result, conn)

      assert mc_html =~ "auto_remediation_exhaustion_policy: :proceed"
    end
  end

  # ---- 029 US4 launch controls (contracts/operator-surfaces.md Trigger form) ----

  describe "interactive clarify launch controls" do
    setup do
      prior = %{
        interactive_clarify: Application.get_env(:autonomous, :interactive_clarify),
        clarify_answer_timeout_s: Application.get_env(:autonomous, :clarify_answer_timeout_s),
        clarify_max_rounds: Application.get_env(:autonomous, :clarify_max_rounds)
      }

      on_exit(fn ->
        Enum.each(prior, fn
          {k, nil} -> Application.delete_env(:autonomous, k)
          {k, v} -> Application.put_env(:autonomous, k, v)
        end)
      end)

      :ok
    end

    test "the switch and its two fields are pre-filled from Config", %{conn: conn} do
      point_backlog_at(@valid_dir)
      Application.put_env(:autonomous, :interactive_clarify, true)
      Application.put_env(:autonomous, :clarify_answer_timeout_s, 120)
      Application.put_env(:autonomous, :clarify_max_rounds, 2)

      {:ok, _view, html} = live(conn, "/trigger")

      assert html =~ ~s(data-interactive-clarify="true")
      assert html =~ ~s(data-clarify-timeout)
      assert html =~ ~s(value="2")
    end

    test "the timeout and rounds inputs are absent while the switch is off, present with defaults once toggled on",
         %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, view, html} = live(conn, "/trigger")
      assert html =~ ~s(data-interactive-clarify="false")
      refute html =~ "data-clarify-timeout"
      refute html =~ "data-clarify-rounds"
      refute html =~ ~s(name="answer_timeout_min")
      refute html =~ ~s(name="max_rounds")

      html = render_click(view, "toggle_interactive_clarify", %{})

      assert html =~ ~s(data-interactive-clarify="true")
      assert html =~ ~s(name="answer_timeout_min")
      assert html =~ ~s(name="max_rounds")
      assert html =~ ~s(data-clarify-timeout)
      assert html =~ ~s(data-clarify-rounds)
      refute html =~ ~s(data-clarify-timeout="" disabled)
    end

    test "an out-of-range timeout is refused before the run starts", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, view, _html} = live(conn, "/trigger")

      render_click(view, "toggle_interactive_clarify", %{})
      render_change(view, "update_clarify", %{"answer_timeout_min" => "0", "max_rounds" => "2"})

      html = render_click(view, "start_backlog", %{})

      assert html =~ ~s(data-error="clarify-timeout")
      refute Process.whereis(Coordinator)
    end

    test "an out-of-range round limit is refused before the run starts", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, view, _html} = live(conn, "/trigger")

      render_click(view, "toggle_interactive_clarify", %{})
      render_change(view, "update_clarify", %{"answer_timeout_min" => "30", "max_rounds" => "9"})

      html = render_click(view, "start_backlog", %{})

      assert html =~ ~s(data-error="clarify-rounds")
      refute Process.whereis(Coordinator)
    end

    test "start_opts/1 converts minutes to clarify_answer_timeout_s", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, view, _html} = live(conn, "/trigger")

      render_click(view, "toggle_interactive_clarify", %{})
      render_change(view, "update_clarify", %{"answer_timeout_min" => "2", "max_rounds" => "1"})

      result = render_click(view, "start_backlog", %{})
      {:ok, _mc_view, mc_html} = follow_redirect(result, conn)

      assert mc_html =~ "interactive_clarify: true"
      assert mc_html =~ "clarify_answer_timeout_s: 120"
      assert mc_html =~ "clarify_max_rounds: 1"
    end
  end

  # ---- 033 US2: grouped options, honest summary

  describe "option groups and summary (033)" do
    test "options sit in two labelled fieldsets, one control per row (039: no containment)", %{
      conn: conn
    } do
      point_backlog_at(@valid_dir)

      {:ok, _view, html} = live(conn, "/trigger")
      doc = LazyHTML.from_document(html)

      groups =
        doc
        |> LazyHTML.query("fieldset[data-option-group]")
        |> LazyHTML.attribute("data-option-group")

      assert groups == ["auto_remediation", "interactive_clarify"]

      for g <- groups do
        fieldset = LazyHTML.query(doc, ~s(fieldset[data-option-group="#{g}"]))
        assert fieldset |> LazyHTML.query(".config-toggle-title") |> Enum.count() == 1
      end

      assert html =~ "auto_remediation_threshold"
      assert html =~ "auto_remediation_exhaustion_policy"
      refute html =~ "containment_profile"
      refute html =~ "data-containment"
    end

    test "the container notice shows when not containerized (039, test config)", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, _view, html} = live(conn, "/trigger")

      assert html =~ "data-container-notice"
      assert html =~ "OUTSIDE the container"
      assert html =~ "scripts/autonomous"
    end

    test "the backlog summary uses statement labels and a repo-relative source", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, _view, html} = live(conn, "/trigger")

      for label <- ["Source", "Feature count", "DAG validated", "Run shape"],
          do: assert(html =~ "<dt>#{label}</dt>")

      refute html =~ "<dt>Budget</dt>"

      refute html =~ "DAG validated?"
      refute html =~ "…/autonomous"
      assert html =~ ~s(title="#{@valid_dir}")
    end

    test "every select and text-like input carries console-input", %{conn: conn} do
      point_backlog_at(@valid_dir)

      {:ok, view, _html} = live(conn, "/trigger")
      html = render_click(view, "toggle_interactive_clarify", %{})
      doc = LazyHTML.from_document(html)

      controls = LazyHTML.query(doc, "select, input[type=number], input[type=text]")
      assert Enum.count(controls) >= 5

      for el <- controls do
        assert el |> LazyHTML.attribute("class") |> Enum.join(" ") =~ "console-input"
      end
    end

    test "no data-confirm attribute exists anywhere", %{conn: conn} do
      point_backlog_at(@valid_dir)
      {:ok, _view, html} = live(conn, "/trigger")
      refute html =~ "data-confirm="
    end
  end

  # ---- 033 US2: two-step start while a run is in flight

  describe "two-step start (033)" do
    setup do
      src = Path.expand("../../fixtures/breakdown_packages", __DIR__)
      repo = Path.join(System.tmp_dir!(), "trigger_confirm_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(repo, "specs/autonomous/breakdown"))
      File.cp_r!(src, Path.join(repo, "specs/autonomous/breakdown"))
      {_, 0} = System.cmd("git", ["init", "-q", repo])

      {_, 0} =
        System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@example.com:test/t.git"])

      on_exit(fn -> File.rm_rf(repo) end)
      Application.put_env(:autonomous, :repo, repo)
      Application.put_env(:autonomous, :breakdown_dir, "docs/breakdown")

      {:ok, repo: repo, repo_id: RepoIdentity.partition(repo)}
    end

    # An in-flight run: a store row (what `current_run_id/0` reads) plus a live,
    # unfinished Coordinator (what makes it "active").
    defp start_active_run(repo_id) do
      {:ok, run_id} =
        Writer.open_run(repo_id, %{
          features: [
            %{
              feature_id: "001",
              slug: "f",
              path: "specs/001",
              number: 1,
              group: :backlog,
              created_at: nil
            }
          ],
          settings: %{},
          scope: :ad_hoc,
          layout: %{}
        })

      feature = %Feature{id: "001", number: 1, slug: "f", path: "001.md"}

      {:ok, pid} =
        Coordinator.start_link(
          name: Coordinator,
          features: [feature],
          runner: fn _feature, _notify -> :ok end,
          owner: self()
        )

      {run_id, pid}
    end

    test "with a run in flight the first click arms and names the run; nothing starts", %{
      conn: conn,
      repo_id: repo_id
    } do
      {run_id, pid} = start_active_run(repo_id)

      {:ok, view, html} = live(conn, "/trigger")
      refute html =~ "data-confirm-armed"
      refute html =~ "Supersede"

      html = render_click(view, "start_backlog", %{})

      assert html =~ "Supersede #{run_id} and start"
      assert html =~ "data-confirm-armed"
      assert html =~ "drains and supersedes #{run_id}"
      assert html =~ ~s(data-action="cancel-start-backlog")
      refute html =~ "data-confirm="
      assert Process.whereis(Coordinator) == pid
    end

    test "Cancel returns the button to its normal state", %{conn: conn, repo_id: repo_id} do
      {run_id, _pid} = start_active_run(repo_id)
      {:ok, view, _html} = live(conn, "/trigger")
      render_click(view, "start_backlog", %{})

      html = render_click(view, "cancel_start", %{"action" => "backlog"})

      refute html =~ "Supersede #{run_id}"
      refute html =~ "data-confirm-armed"
      assert html =~ "Start run"
    end

    test "the second click dispatches exactly as today", %{conn: conn, repo_id: repo_id} do
      {_run_id, old} = start_active_run(repo_id)
      {:ok, view, _html} = live(conn, "/trigger")
      render_click(view, "start_backlog", %{})

      result = render_click(view, "start_backlog", %{})

      {:ok, _mc_view, mc_html} = follow_redirect(result, conn)
      assert mc_html =~ "Backlog run started: Autonomous.run/1"
      refute Process.alive?(old)
    end

    test "with no run in flight one click dispatches", %{conn: conn} do
      {:ok, view, html} = live(conn, "/trigger")
      refute html =~ "Supersede"

      result = render_click(view, "start_backlog", %{})

      {:ok, _mc_view, mc_html} = follow_redirect(result, conn)
      assert mc_html =~ "Backlog run started"
    end

    test "single-spec start follows the same two steps", %{conn: conn, repo_id: repo_id} do
      {run_id, _pid} = start_active_run(repo_id)
      {:ok, view, _html} = live(conn, "/trigger")
      render_click(view, "set_mode", %{"mode" => "single_spec"})

      html = render_submit(view, "start_single_spec", %{"description" => "Add a health check"})

      assert html =~ "Supersede #{run_id} and start"
      assert html =~ ~s(data-action="cancel-start-single_spec")

      result = render_submit(view, "start_single_spec", %{"description" => "Add a health check"})
      {:ok, _mc_view, mc_html} = follow_redirect(result, conn)
      assert mc_html =~ "Feature started"
    end

    test "an invalid description never arms the button", %{conn: conn, repo_id: repo_id} do
      start_active_run(repo_id)
      {:ok, view, _html} = live(conn, "/trigger")
      render_click(view, "set_mode", %{"mode" => "single_spec"})

      html = render_submit(view, "start_single_spec", %{"description" => "   "})

      assert html =~ "Description is required"
      refute html =~ "data-confirm-armed"
    end

    test "switching tabs disarms", %{conn: conn, repo_id: repo_id} do
      {run_id, _pid} = start_active_run(repo_id)
      {:ok, view, _html} = live(conn, "/trigger")
      render_click(view, "start_backlog", %{})

      render_click(view, "set_mode", %{"mode" => "single_spec"})
      html = render_click(view, "set_mode", %{"mode" => "backlog"})

      refute html =~ "Supersede #{run_id}"
      refute html =~ "data-confirm-armed"
    end

    test "the in-flight run ending while armed returns the button to normal", %{
      conn: conn,
      repo_id: repo_id
    } do
      {run_id, pid} = start_active_run(repo_id)
      {:ok, view, _html} = live(conn, "/trigger")
      assert render_click(view, "start_backlog", %{}) =~ "Supersede #{run_id}"

      GenServer.stop(pid)
      :ok = Writer.close_run({repo_id, run_id}, :all_done, [])

      Phoenix.PubSub.broadcast(
        Autonomous.PubSub,
        ConsoleProjection.topic(),
        {:console, :reconciled, %{}}
      )

      html = render(view)
      refute html =~ "Supersede"
      refute html =~ "data-confirm-armed"
    end
  end
end
