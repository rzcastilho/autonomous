defmodule SpeckitOrchestrator.Web.EscalationsLiveTest do
  # Starts the real named Coordinator and mutates transcript_root/worktree_root
  # app env — must not run concurrently with another test claiming that name.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Checkpoint, Config, Coordinator, Feature, RunContext}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  setup do
    prior = %{
      transcript_root: Application.get_env(:speckit_orchestrator, :transcript_root),
      worktree_root: Application.get_env(:speckit_orchestrator, :worktree_root),
      console_test_runner: Application.get_env(:speckit_orchestrator, :console_test_runner)
    }

    root = Path.join(System.tmp_dir!(), "esc_cp_#{System.unique_integer([:positive])}")
    wt_root = Path.join(System.tmp_dir!(), "esc_wt_#{System.unique_integer([:positive])}")

    Application.put_env(:speckit_orchestrator, :transcript_root, root)
    Application.put_env(:speckit_orchestrator, :worktree_root, wt_root)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(wt_root)

      Enum.each(prior, fn
        {k, nil} -> Application.delete_env(:speckit_orchestrator, k)
        {k, v} -> Application.put_env(:speckit_orchestrator, k, v)
      end)

      if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp feat(id, slug), do: %Feature{id: id, slug: slug, path: "#{id}.md"}

  # `outcomes` maps feature id -> {status, reason}; any feature without an
  # entry just releases and stays :running (no-op runner, same trick
  # mission_control_live_test.exs uses).
  defp start_coordinator(features, outcomes) do
    runner = fn feature, notify ->
      case Map.fetch(outcomes, feature.id) do
        {:ok, {status, reason}} -> notify.(feature.id, status, reason)
        :error -> :ok
      end
    end

    {:ok, pid} =
      Coordinator.start_link(name: Coordinator, features: features, runner: runner, owner: self())

    pid
  end

  test "lists every diverted feature with divert reason + checkpoint pointer", %{conn: conn} do
    Checkpoint.write(%{
      feature_id: "e1",
      last_phase: :clarify,
      status: :escalated,
      reason: "needs human",
      session_id: "sess-1",
      slug: "slug-e1",
      path: "e1.md"
    })

    Checkpoint.write(%{
      feature_id: "e2",
      last_phase: :analyze,
      status: :halted,
      reason: "critical finding",
      session_id: "sess-2",
      slug: "slug-e2",
      path: "e2.md"
    })

    Checkpoint.write(%{
      feature_id: "e3",
      last_phase: :implement,
      status: :failed,
      reason: :timeout,
      session_id: nil,
      slug: "slug-e3",
      path: "e3.md"
    })

    pid =
      start_coordinator(
        [feat("e1", "slug-e1"), feat("e2", "slug-e2"), feat("e3", "slug-e3")],
        %{
          "e1" => {:escalated, "needs human"},
          "e2" => {:halted, "critical finding"},
          "e3" => {:failed, :timeout}
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-escalation="e1")
    assert html =~ "needs human"
    assert html =~ "clarify"
    assert html =~ "sess-1"

    assert html =~ ~s(data-escalation="e2")
    assert html =~ "critical finding"
    assert html =~ "analyze"
    assert html =~ "sess-2"

    assert html =~ ~s(data-escalation="e3")
    assert html =~ "implement"
  end

  test "escalated feature shows clarify questions/options and the recorded run context", %{
    conn: conn
  } do
    spec_dir =
      [Application.fetch_env!(:speckit_orchestrator, :worktree_root), "e4-slug-e4", "specs", "004-slug-e4"]
      |> Path.join()

    File.mkdir_p!(spec_dir)

    File.write!(Path.join(spec_dir, "spec.md"), """
    # Spec

    ## NEEDS HUMAN

    Which database backend should feature 004 use?

    - SQLite
    - Postgres

    ## Next Section

    unrelated content
    """)

    ctx = %RunContext{
      pr_workflow: false,
      max_concurrency: 2,
      budget_usd: 10.0,
      plan_stack: [],
      pr_base: "main",
      pr_remote: "origin"
    }

    Checkpoint.write(%{
      feature_id: "e4",
      last_phase: :clarify,
      status: :escalated,
      reason: "needs human",
      session_id: "sess-4",
      slug: "slug-e4",
      path: "e4.md",
      run_context: ctx
    })

    pid = start_coordinator([feat("e4", "slug-e4")], %{"e4" => {:escalated, "needs human"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ "Which database backend should feature 004 use?"
    assert html =~ "SQLite"
    assert html =~ "Postgres"
    refute html =~ "unrelated content"

    assert html =~ "pr_workflow"
    assert html =~ "main"
  end

  test "guidance + start-phase override submit calls resume/2 and clears the escalation on success",
       %{conn: conn} do
    Checkpoint.write(%{
      feature_id: "e5",
      last_phase: :clarify,
      status: :escalated,
      reason: "needs human",
      session_id: "sess-5",
      slug: "slug-e5",
      path: "e5.md"
    })

    pid = start_coordinator([feat("e5", "slug-e5")], %{"e5" => {:escalated, "needs human"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Application.put_env(:speckit_orchestrator, :console_test_runner, fn _feature, _notify ->
      :ok
    end)

    {:ok, view, html} = live(conn, "/escalations")
    assert html =~ ~s(data-escalation="e5")
    assert html =~ ~s(data-form="resume")

    html =
      render_submit(view, "resume", %{
        "feature_id" => "e5",
        "prompt" => "try again",
        "from" => "plan"
      })

    assert html =~ "Feature e5 resumed"
    refute html =~ ~s(data-escalation="e5")
    assert Process.whereis(Coordinator)
  end

  test "full-restart action calls resolve/2 then run/1, restarting from phase 1 and freeing the worktree",
       %{conn: conn} do
    Checkpoint.write(%{
      feature_id: "e6",
      last_phase: :tasks,
      status: :halted,
      reason: "budget",
      session_id: "sess-6",
      slug: "slug-e6",
      path: "e6.md"
    })

    pid = start_coordinator([feat("e6", "slug-e6")], %{"e6" => {:halted, "budget"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Application.put_env(:speckit_orchestrator, :console_test_runner, fn _feature, _notify ->
      :ok
    end)

    {:ok, view, html} = live(conn, "/escalations")
    assert html =~ ~s(data-escalation="e6")

    html = render_click(view, "full_restart", %{"id" => "e6"})

    assert html =~ "restarted from phase 1"
    assert html =~ "worktree freed"
    refute html =~ ~s(data-escalation="e6")
    assert Process.whereis(Coordinator)
  end

  test "missing checkpoint steers to full restart only, no resume option offered", %{conn: conn} do
    pid = start_coordinator([feat("e7", "slug-e7")], %{"e7" => {:halted, "boom"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-escalation="e7")
    assert html =~ "No usable checkpoint (no_checkpoint)"
    refute html =~ ~s(data-form="resume")
    assert html =~ ~s(data-action="full-restart-e7")
  end

  test "corrupt checkpoint steers to full restart only, no resume option offered", %{conn: conn} do
    path = Path.join([Config.transcript_root(), "e8", "checkpoint.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not valid json{")

    pid = start_coordinator([feat("e8", "slug-e8")], %{"e8" => {:failed, :timeout}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-escalation="e8")
    assert html =~ "No usable checkpoint (corrupt)"
    refute html =~ ~s(data-form="resume")
    assert html =~ ~s(data-action="full-restart-e8")
  end

  test "empty escalation set renders the all-clear empty state", %{conn: conn} do
    refute Process.whereis(Coordinator)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-state="all-clear")
  end
end
