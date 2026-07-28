defmodule SpeckitOrchestrator.Web.EscalationsLiveTest do
  # Starts the real named Coordinator and mutates transcript_root/worktree_root
  # app env — must not run concurrently with another test claiming that name.
  # StoreCase (018) clears every store table before each test, so an earlier
  # test's (in this file or another) in-flight run never leaks into this
  # file's checkpoint/escalation assertions.
  use SpeckitOrchestrator.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Config, Coordinator, Feature, Layout, RepoIdentity, RunContext}

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

  # 018: `resume/2` and `EscalationsLive` both read the target's checkpoint
  # and the run's state from the store — every fixture below seeds a
  # store-backed run via `seed_store_checkpoint/4` (or `seed_store_run/1` for
  # several features at once).
  defp minimal_attempt(feature_id, phase) do
    now = DateTime.utc_now()

    %{
      feature_id: feature_id,
      phase: phase,
      ordinal: 1,
      step: 1,
      label: Atom.to_string(phase),
      started_at: now,
      ended_at: now,
      duration_ms: 0,
      outcome: :error,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # One store run carrying every entry's feature + checkpoint, so a test
  # exercising several diverted features at once (the Escalations list) sees
  # them all from a single `run_detail/1` read — three separate `open_run/2`
  # calls would each supersede the last, leaving only the final feature's
  # checkpoint visible (018, FR-034).
  defp seed_store_run(entries) do
    repo_id = RepoIdentity.partition(Config.repo())
    {:ok, segment} = RepoIdentity.resolve(Config.repo())
    {:ok, layout} = Layout.build(Config.repo(), segment, :ad_hoc)

    features =
      Enum.map(entries, fn {feature, _phase, _status, _opts} ->
        %{feature_id: feature.id, slug: feature.slug, path: feature.path, prereqs: []}
      end)

    settings =
      entries
      |> List.first()
      |> elem(3)
      |> Keyword.get(
        :run_context,
        %RunContext{pr_workflow: false, max_concurrency: 2, budget_usd: 100.0}
      )
      |> RunContext.to_map()

    {:ok, run_id} =
      Writer.open_run(repo_id, %{
        features: features,
        settings: settings,
        scope: :ad_hoc,
        layout: layout
      })

    run_key = {repo_id, run_id}

    Enum.each(entries, fn {feature, phase, status, opts} ->
      reason = Keyword.get(opts, :reason, "test fixture")

      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: minimal_attempt(feature.id, phase),
          checkpoint: %{
            phase: phase,
            last_completed_phase: phase,
            status: status,
            reason: reason,
            session_id: Keyword.get(opts, :session_id, "s1"),
            implement_chunk: Keyword.get(opts, :implement_chunk),
            analyze_remediation: Keyword.get(opts, :analyze_remediation)
          }
        })

      :ok = Writer.record_feature_terminal(run_key, feature.id, status, reason, [])
    end)

    run_key
  end

  defp seed_store_checkpoint(feature, phase, status, opts \\ []) do
    seed_store_run([{feature, phase, status, opts}])
  end

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
    seed_store_run([
      {feat("e1", "slug-e1"), :clarify, :escalated, reason: "needs human", session_id: "sess-1"},
      {feat("e2", "slug-e2"), :analyze, :halted,
       reason: "critical finding", session_id: "sess-2"},
      {feat("e3", "slug-e3"), :implement, :failed, reason: :timeout}
    ])

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

    seed_store_checkpoint(feat("e4", "slug-e4"), :clarify, :escalated,
      reason: "needs human",
      session_id: "sess-4",
      run_context: ctx
    )

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
    seed_store_checkpoint(feat("e5", "slug-e5"), :clarify, :escalated)
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
    seed_store_checkpoint(feat("e9", "slug-e9"), :analyze, :halted)
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
    assert html =~ "No usable checkpoint — full restart only."
    refute html =~ ~s(data-form="resume")
    assert html =~ ~s(data-action="full-restart-e7")
  end

  # ---- 016 T038: resume panel states whole-run continuation + active-run refusal (S7) ----

  test "resume panel copy states that resuming continues the whole run, not only the selected feature",
       %{conn: conn} do
    seed_store_checkpoint(feat("e14", "slug-e14"), :clarify, :escalated,
      reason: "needs human",
      session_id: "sess-14"
    )

    pid = start_coordinator([feat("e14", "slug-e14")], %{"e14" => {:escalated, "needs human"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-resume-scope-note)
    assert html =~ "Resuming continues the whole run"
  end

  test "a resume attempted while another run is live renders the active-run refusal instead of starting work",
       %{conn: conn} do
    # A blocker feature with no outcome entry never notifies — the Coordinator
    # this starts stays unfinished for the duration of the test, matching
    # `guard_active_run/1`'s `finished?` check (FR-010a).
    pid =
      start_coordinator(
        [feat("e15", "slug-e15"), feat("blocker", "slug-blocker")],
        %{"e15" => {:escalated, "needs human"}}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(conn, "/escalations")
    assert html =~ ~s(data-escalation="e15")

    html =
      render_submit(view, "resume", %{
        "feature_id" => "e15",
        "prompt" => "",
        "from" => "clarify"
      })

    assert html =~ "Resume failed:"
    assert html =~ "a run is already live for this repository"
    # refused, not started — the escalation is still open.
    assert html =~ ~s(data-escalation="e15")
    assert Process.whereis(Coordinator) == pid
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

    seed_store_checkpoint(feat("e10", "slug-e10"), :implement, :failed,
      reason: "stuck",
      session_id: "sess-10",
      implement_chunk: %{
        ordinal: 2,
        number: "2",
        title: "Core",
        total: 3,
        sessions_used: 1,
        ceiling: 10,
        scope: :task_phase
      }
    )

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
    seed_store_checkpoint(feat("e11", "slug-e11"), :implement, :failed, reason: "stuck")

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

    seed_store_checkpoint(feat("e12", "slug-e12"), :analyze, :halted, reason: "critical finding")

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

    seed_store_checkpoint(feat("e13", "slug-e13"), :implement, :failed,
      implement_chunk: %{
        ordinal: 2,
        number: "2",
        title: "Core",
        total: 2,
        sessions_used: 1,
        ceiling: 8,
        scope: :task_phase
      }
    )

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

  # ---- auto-remediation attempt history (017, SC-005) ------------------------

  test "renders the exhausted-attempts summary above the resume controls", %{conn: conn} do
    seed_store_checkpoint(feat("e14", "slug-e14"), :analyze, :escalated,
      reason: "{:high_findings, :auto_remediation_exhausted}",
      session_id: "sess-14",
      analyze_remediation: %{attempts_used: 2, limit: 2, threshold: "high", enabled: true}
    )

    pid = start_coordinator([feat("e14", "slug-e14")], %{"e14" => {:escalated, "exhausted"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-auto-remediation)
    assert html =~ "auto-remediation: 2/2 attempts exhausted (threshold high)"
  end

  test "a partial attempt budget reads as spent, not exhausted", %{conn: conn} do
    seed_store_checkpoint(feat("e15", "slug-e15"), :analyze, :failed,
      reason: "{:failed, :remediation_failed}",
      session_id: "sess-15",
      analyze_remediation: %{attempts_used: 1, limit: 4, threshold: "critical", enabled: true}
    )

    pid =
      start_coordinator([feat("e15", "slug-e15")], %{"e15" => {:failed, "remediation failed"}})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ "auto-remediation: 1/4 attempts spent (threshold critical)"
  end

  test "a pre-017 checkpoint renders no auto-remediation line at all", %{conn: conn} do
    seed_store_checkpoint(feat("e16", "slug-e16"), :analyze, :halted, reason: "critical finding")

    pid = start_coordinator([feat("e16", "slug-e16")], %{"e16" => {:halted, "critical finding"}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, _view, html} = live(conn, "/escalations")

    assert html =~ ~s(data-escalation="e16")
    refute html =~ ~s(data-auto-remediation)
  end
end
