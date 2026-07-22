defmodule SpeckitOrchestrator.Web.ReconcileTest do
  @moduledoc """
  Phase 9 cross-cutting fidelity (`specs/008-control-plane/tasks.md`
  T071-T073): the reconcile tick converges an outside state change (FR-033,
  SC-005), a tripped breaker never depicts a mid-phase kill (SC-007,
  Constitution IV), and every coherent-empty-state requirement (SC-006) holds
  across views.
  """
  # Starts the real named Coordinator and mutates the app-supervised default
  # Ledger's budget / global repo+breakdown_dir app env — must not run
  # concurrently with another test claiming those globals.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SpeckitOrchestrator.{Coordinator, ConsoleProjection, Feature, Ledger}

  @endpoint SpeckitOrchestrator.Web.Endpoint

  @valid_dir Path.expand("../../fixtures/breakdown", __DIR__)
  @cyclic_dir Path.expand("../../fixtures/breakdown_cyclic", __DIR__)

  setup do
    prior = %{
      repo: Application.get_env(:speckit_orchestrator, :repo),
      breakdown_dir: Application.get_env(:speckit_orchestrator, :breakdown_dir),
      budget_usd: Ledger.snapshot().budget
    }

    on_exit(fn ->
      Enum.each([repo: prior.repo, breakdown_dir: prior.breakdown_dir], fn
        {k, nil} -> Application.delete_env(:speckit_orchestrator, k)
        {k, v} -> Application.put_env(:speckit_orchestrator, k, v)
      end)

      Ledger.set_budget(prior.budget_usd)
      if pid = Process.whereis(Coordinator), do: GenServer.stop(pid)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp point_backlog_at(dir) do
    Application.put_env(:speckit_orchestrator, :repo, dir)
    Application.put_env(:speckit_orchestrator, :breakdown_dir, "")
  end

  defp feat(id), do: %Feature{id: id, slug: "slug-#{id}", path: "#{id}.md"}

  # Forces an immediate reconcile instead of waiting up to the 2s tick — the
  # projection's :reconcile handler is the same code the timer fires.
  defp force_reconcile do
    send(Process.whereis(ConsoleProjection), :reconcile)
    # `handle_info(:reconcile, ...)` broadcasts synchronously off the
    # ConsoleProjection mailbox; a :sys.get_state round-trip guarantees it
    # has processed our message before we render.
    :sys.get_state(ConsoleProjection)
  end

  # ---- T071: outside state change converges within the reconcile tick -----

  test "a raw Coordinator.notify/4 call (outside actor) converges on the mounted LiveView via reconcile" do
    # A second, never-notified feature keeps the run alive after "rc1"
    # diverts, so Mission Control keeps rendering the live table (not the
    # drained/finished screen) — this test is about state convergence, not
    # the run-finished transition (covered elsewhere).
    pid =
      elem(
        Coordinator.start_link(
          name: Coordinator,
          features: [feat("rc1"), feat("rc1b")],
          runner: fn _f, _n -> :ok end,
          owner: self()
        ),
        1
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ ~s(data-status="running")

    # Change state directly against the Coordinator — not through telemetry,
    # not through the projection's own fold — simulating an outside actor
    # (e.g. an `iex` session) driving the same run.
    Coordinator.notify(pid, "rc1", :escalated, :needs_human)
    assert %{status: :escalated} = Coordinator.status(pid).per_feature["rc1"]

    force_reconcile()

    html = render(view)
    row = Regex.run(~r/<tr[^>]*data-feature-row="rc1".*?<\/tr>/s, html) |> hd()
    assert row =~ ~s(data-status="escalated")
  end

  # ---- T072: drain, don't kill — never a depicted mid-phase kill ----------

  test "a tripped breaker shows tripped in the status bar without forcing an in-flight feature to a diverted status" do
    # A second, never-notified feature keeps the run alive after "rc2"
    # halts, so Mission Control keeps rendering the live table.
    pid =
      elem(
        Coordinator.start_link(
          name: Coordinator,
          features: [feat("rc2"), feat("rc2b")],
          runner: fn _f, _n -> :ok end,
          owner: self()
        ),
        1
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert %{status: :running} = Coordinator.status(pid).per_feature["rc2"]

    # Trip the breaker directly on the Ledger (committed 0 >= budget 0).
    Ledger.set_budget(0.0)
    assert Ledger.breaker_tripped?()

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ ~s(data-tripped)
    assert html =~ "(tripped)"

    # The console never flips an in-flight feature's displayed status on its
    # own account — only an explicit notify (the runner finishing its phase
    # then halting, per Constitution IV) does.
    row = Regex.run(~r/<tr[^>]*data-feature-row="rc2".*?<\/tr>/s, html) |> hd()
    assert row =~ ~s(data-status="running")

    # The runner drains: finishes the in-flight phase, then halts between
    # phases — an explicit notify, never a display-layer kill.
    Coordinator.notify(pid, "rc2", :halted, :breaker_tripped)
    force_reconcile()

    html = render(view)
    row = Regex.run(~r/<tr[^>]*data-feature-row="rc2".*?<\/tr>/s, html) |> hd()
    assert row =~ ~s(data-status="halted")
  end

  # ---- T073: coherent empty/error states across views (SC-006) ------------

  test "no-active-run, empty backlog, invalid DAG, missing transcript, and missing checkpoint each render a coherent state" do
    conn = build_conn()

    refute Process.whereis(Coordinator)
    {:ok, _view, html} = live(conn, "/")
    assert html =~ ~s(data-state="no-active-run")

    empty_dir = Path.join(System.tmp_dir!(), "reconcile_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty_dir)
    on_exit(fn -> File.rm_rf(empty_dir) end)
    point_backlog_at(empty_dir)
    {:ok, _view, html} = live(conn, "/dag")
    assert html =~ ~s(data-state="empty-backlog")

    point_backlog_at(@cyclic_dir)
    {:ok, _view, html} = live(conn, "/dag")
    assert html =~ ~s(data-state="dag-invalid")

    point_backlog_at(@valid_dir)

    root = Path.join(System.tmp_dir!(), "reconcile_tr_#{System.unique_integer([:positive])}")
    prior_root = Application.get_env(:speckit_orchestrator, :transcript_root)
    Application.put_env(:speckit_orchestrator, :transcript_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      case prior_root do
        nil -> Application.delete_env(:speckit_orchestrator, :transcript_root)
        v -> Application.put_env(:speckit_orchestrator, :transcript_root, v)
      end
    end)

    {:ok, _view, html} = live(conn, "/transcripts")
    assert html =~ ~s(data-state="no-transcripts")

    refute Process.whereis(Coordinator)
    {:ok, _view, html} = live(conn, "/escalations")
    assert html =~ ~s(data-state="all-clear")
  end
end
