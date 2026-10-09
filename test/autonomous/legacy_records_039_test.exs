defmodule Autonomous.LegacyRecords039Test do
  @moduledoc """
  039 (T053, SC-004, FR-017): records written before 039 still load. A run
  whose captured settings carry `budget_usd`/`containment_profile`, a feature
  that ended `{:needs_human, :breaker}` or `{:untrusted_workspace, …}`, and a
  clarify round closed `:breaker` all open through `Report`, Run Detail,
  `resume/2` and `continue_run/1` without error — and none of them reinstates
  the removed behaviour (no budget, no profile lock, no re-park).
  """

  use Autonomous.StoreCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Autonomous.{Config, Feature, RepoIdentity, Report, RunContext}
  alias Autonomous.Web.RunSettingsView

  @endpoint Autonomous.Web.Endpoint
  @coordinator Autonomous.Coordinator
  @stack_tracker Autonomous.StackTracker

  @legacy_settings %{
    "budget_usd" => 74.0,
    "containment_profile" => "strict",
    budget_usd: 12.5,
    containment_profile: :permissive,
    plan_stack: true
  }

  @breaker {:needs_human, :breaker}
  @untrusted {:untrusted_workspace, :implement, %{workspace: "/work/001", kinds: ["permissions"]}}

  defp feat(id, number),
    do: %Feature{id: id, number: number, slug: "f#{id}", path: "#{id}.md"}

  defp features, do: [feat("001", 1), feat("002", 2)]
  defp repo_id, do: RepoIdentity.partition(Config.repo())

  defp stop_named(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  setup do
    on_exit(fn ->
      stop_named(@coordinator)
      stop_named(@stack_tracker)
    end)

    :ok
  end

  defp attempt(feature_id, phase) do
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
      outcome: :ok,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # 001 finishes; 002 stops with `reason` and a checkpoint, as a pre-039
  # FeatureRunner would have recorded it.
  defp fake_runner(test_pid, outcomes) do
    fn feature, notify ->
      run_key = {repo_id(), Autonomous.current_run_id()}

      case Map.fetch!(outcomes, feature.id) do
        :done ->
          Writer.record_feature_terminal(run_key, feature.id, :done, nil)
          notify.(feature.id, :done, nil)

        {status, reason} ->
          Writer.record_phase_attempt(run_key, %{
            attempt: attempt(feature.id, :clarify),
            checkpoint: %{
              phase: :clarify,
              last_completed_phase: :specify,
              status: status,
              reason: reason,
              session_id: "s1"
            }
          })

          Writer.record_feature_terminal(run_key, feature.id, status, reason)
          notify.(feature.id, status, reason)
      end

      send(test_pid, {:ran, feature.id})
      :ok
    end
  end

  # Parks a real run, then rewrites its settings row to the pre-039 shape and
  # adds a clarify round closed `:breaker` — the bytes a pre-039 run left.
  defp park_legacy(reason) do
    me = self()

    {:ok, _pid} =
      Autonomous.run(
        features: features(),
        runner: fake_runner(me, %{"001" => :done, "002" => {:escalated, reason}}),
        owner: me
      )

    assert_receive {:ran, "002"}, 2_000
    assert_receive {:run_complete, _report}, 2_000
    assert {:ok, %{state: :parked, run_id: run_id}} = Store.parked_run(repo_id())
    stop_named(@coordinator)
    stop_named(@stack_tracker)
    run_key = {repo_id(), run_id}

    {:ok, :ok} =
      Mnesia.transaction(fn ->
        Mnesia.write(
          Records.encode(%Records.RunSettings{
            run_key: run_key,
            settings: @legacy_settings,
            captured_at: DateTime.utc_now()
          })
        )
      end)

    {:ok, seq} =
      Writer.record_feature_awaiting(run_key, "001", %{
        round: 1,
        max_rounds: 3,
        questions_raw: "## NEEDS HUMAN\n- Q1?",
        questions: {:freeform, "Q1?"},
        answer_timeout_s: 600
      })

    assert :ok = Writer.close_round(run_key, "001", %{seq: seq, outcome: :breaker})
    :ok = Writer.record_feature_terminal(run_key, "001", :done, nil)
    run_key
  end

  defp continue_opts do
    me = self()
    [features: features(), runner: fake_runner(me, %{"002" => :done}), owner: me]
  end

  describe "Report" do
    test "renders the historical reasons" do
      assert Report.format_reason(@breaker) ==
               "needs human — breaker tripped while awaiting answers"

      assert Report.format_reason(@untrusted) =~ "untrusted_workspace in"
      assert Report.format_reason(@untrusted) =~ "/work/001"
    end
  end

  describe "settings" do
    test "RunContext reads a legacy map without carrying the removed keys" do
      ctx = RunContext.from_map(@legacy_settings)
      refute Map.has_key?(Map.from_struct(ctx), :budget_usd)
      refute Map.has_key?(Map.from_struct(ctx), :containment_profile)

      {merged, _fell_back} = RunContext.merge([], ctx)
      refute Keyword.has_key?(merged, :budget_usd)
      refute Keyword.has_key?(merged, :containment_profile)
    end

    test "RunSettingsView hides both legacy keys" do
      keys = @legacy_settings |> RunSettingsView.rows() |> inspect()
      refute keys =~ "budget"
      refute keys =~ "containment"
    end
  end

  describe "Writer" do
    test "close_round still accepts the historical :breaker outcome" do
      run_key = park_legacy(@breaker)
      assert {:ok, detail} = Store.run(run_key)
      assert detail.settings == @legacy_settings
    end
  end

  describe "Run Detail" do
    test "opens a pre-039 run: keys hidden, :breaker round labelled, reasons rendered" do
      run_key = park_legacy(@breaker)
      {_repo, run_id} = run_key
      :ok = Writer.record_feature_terminal(run_key, "002", :failed, @untrusted)

      {:ok, _view, html} = live(build_conn(), "/runs/#{run_id}")

      assert html =~ run_id
      assert html =~ "data-clarify-rounds"
      assert html =~ "breaker"
      assert html =~ "untrusted_workspace in"
      refute html =~ "budget_usd"
      refute html =~ "containment_profile"
    end
  end

  describe "resume/2 and continue_run/1" do
    test "continue_run/1 continues a legacy parked run without a profile lock or re-park" do
      run_key = park_legacy(@breaker)

      assert {:ok, pid} = Autonomous.continue_run(continue_opts())
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:ran, "002"}, 2_000
      assert_receive {:run_complete, report}, 2_000
      refute Map.has_key?(report, :breaker_tripped)
      refute Map.has_key?(report, :containment_profile)
      assert Store.parked_run(repo_id()) == :none
      assert {:ok, %{run: %{state: state}}} = Store.run(run_key)
      refute state == :parked
    end

    # resume/2 targets the current (in-flight) run, so the legacy run here is
    # an in-flight orphan opened with pre-039 settings — not a parked one.
    test "resume/2 re-runs a {:needs_human, :breaker} feature of a legacy run" do
      rows =
        for f <- features(),
            do: %{
              feature_id: f.id,
              slug: f.slug,
              path: f.path,
              number: f.number,
              group: :backlog,
              created_at: nil
            }

      {:ok, run_id} =
        Writer.open_run(repo_id(), %{
          features: rows,
          settings: @legacy_settings,
          scope: :ad_hoc,
          layout: nil
        })

      run_key = {repo_id(), run_id}

      :ok =
        Writer.record_phase_attempt(run_key, %{
          attempt: attempt("002", :clarify),
          checkpoint: %{
            phase: :clarify,
            last_completed_phase: :specify,
            status: :escalated,
            reason: @breaker,
            session_id: "s1"
          }
        })

      :ok = Writer.record_feature_terminal(run_key, "001", :done, nil)
      :ok = Writer.record_feature_terminal(run_key, "002", :escalated, @breaker)
      me = self()

      assert {:ok, pid} =
               Autonomous.resume("002",
                 features: features(),
                 runner: fake_runner(me, %{"002" => :done}),
                 owner: me
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert_receive {:ran, "002"}, 2_000
      assert {:ok, %{run: %{state: state}}} = Store.run(run_key)
      refute state == :parked
    end
  end
end
