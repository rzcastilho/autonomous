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
      [
        Application.fetch_env!(:speckit_orchestrator, :worktree_root),
        "e4-slug-e4",
        "specs",
        "004-slug-e4"
      ]
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
    assert html =~ ~s(data-field="remediation-prompt")
    assert html =~ ~s(data-field="remediation-model")
    assert html =~ "Default (clarify"

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

  test "remediation prompt + model submit alongside guidance calls resume/2 and clears the escalation",
       %{conn: conn} do
    Checkpoint.write(%{
      feature_id: "e9",
      last_phase: :analyze,
      status: :halted,
      reason: "critical finding",
      session_id: "sess-9",
      slug: "slug-e9",
      path: "e9.md"
    })

    pid = start_coordinator([feat("e9", "slug-e9")], %{"e9" => {:halted, "critical finding"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Application.put_env(:speckit_orchestrator, :console_test_runner, fn _feature, _notify ->
      :ok
    end)

    {:ok, view, html} = live(conn, "/escalations")
    assert html =~ ~s(data-escalation="e9")

    html =
      render_submit(view, "resume", %{
        "feature_id" => "e9",
        "prompt" => "",
        "from" => "analyze",
        "remediation_prompt" => "Fix the money-type Critical.",
        "remediation_model" => "opus"
      })

    assert html =~ "Feature e9 resumed"
    refute html =~ ~s(data-escalation="e9")
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

  # ---- task-phase picker (US2, checkpoint-implement-chunk.md §4) ----------

  defp write_tasks_md(id, slug, content) do
    spec_dir =
      [
        Application.fetch_env!(:speckit_orchestrator, :worktree_root),
        "#{id}-#{slug}",
        "specs",
        "#{id}-#{slug}"
      ]
      |> Path.join()

    File.mkdir_p!(spec_dir)
    File.write!(Path.join(spec_dir, "tasks.md"), content)
  end

  test "task-phase picker rendered for a structured implement checkpoint, defaulting to the recorded position",
       %{conn: conn} do
    write_tasks_md("e10", "slug-e10", """
    # Tasks

    ## Phase 1: Setup

    - [X] T001 first thing

    ## Phase 2: Core

    - [ ] T002 second thing

    ## Phase 3: Polish

    - [ ] T003 third thing
    """)

    Checkpoint.write(%{
      feature_id: "e10",
      last_phase: :implement,
      status: :failed,
      reason: "stuck",
      session_id: "sess-10",
      slug: "slug-e10",
      path: "e10.md",
      implement_chunk: %{
        ordinal: 2,
        number: "2",
        title: "Core",
        total: 3,
        sessions_used: 1,
        ceiling: 10,
        scope: :task_phase
      }
    })

    pid = start_coordinator([feat("e10", "slug-e10")], %{"e10" => {:failed, "stuck"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-field="task-phase")
    assert html =~ "1/3 · 1: Setup ✓"
    assert html =~ "2/3 · 2: Core"
    assert html =~ "3/3 · 3: Polish"
    assert html =~ ~r/<option value="2"[^>]*selected/
    refute html =~ "data-weak-match"
  end

  test "task-phase picker absent when the recorded task list is unstructured", %{conn: conn} do
    Checkpoint.write(%{
      feature_id: "e11",
      last_phase: :implement,
      status: :failed,
      reason: "stuck",
      session_id: "sess-11",
      slug: "slug-e11",
      path: "e11.md"
    })

    pid = start_coordinator([feat("e11", "slug-e11")], %{"e11" => {:failed, "stuck"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-escalation="e11")
    refute html =~ ~s(data-field="task-phase")
  end

  test "task-phase picker absent when the checkpoint's last_phase isn't implement", %{conn: conn} do
    write_tasks_md("e12", "slug-e12", """
    # Tasks

    ## Phase 1: Setup

    - [ ] T001 first thing
    """)

    Checkpoint.write(%{
      feature_id: "e12",
      last_phase: :analyze,
      status: :halted,
      reason: "critical finding",
      session_id: "sess-12",
      slug: "slug-e12",
      path: "e12.md"
    })

    pid = start_coordinator([feat("e12", "slug-e12")], %{"e12" => {:halted, "critical finding"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-escalation="e12")
    refute html =~ ~s(data-field="task-phase")
  end

  test "submitted task-phase ordinal is accepted by the resume form and resume/2 still succeeds",
       %{conn: conn} do
    write_tasks_md("e13", "slug-e13", """
    # Tasks

    ## Phase 1: Setup

    - [X] T001 first thing

    ## Phase 2: Core

    - [ ] T002 second thing
    """)

    Checkpoint.write(%{
      feature_id: "e13",
      last_phase: :implement,
      status: :failed,
      reason: "stuck",
      session_id: "sess-13",
      slug: "slug-e13",
      path: "e13.md",
      implement_chunk: %{
        ordinal: 2,
        number: "2",
        title: "Core",
        total: 2,
        sessions_used: 1,
        ceiling: 8,
        scope: :task_phase
      }
    })

    pid = start_coordinator([feat("e13", "slug-e13")], %{"e13" => {:failed, "stuck"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Application.put_env(:speckit_orchestrator, :console_test_runner, fn _feature, _notify ->
      :ok
    end)

    {:ok, view, html} = live(conn, "/escalations")
    assert html =~ ~s(data-escalation="e13")

    html =
      render_submit(view, "resume", %{
        "feature_id" => "e13",
        "prompt" => "",
        "from" => "implement",
        "from_task_phase" => "2"
      })

    assert html =~ "Feature e13 resumed"
    refute html =~ ~s(data-escalation="e13")
  end
end
