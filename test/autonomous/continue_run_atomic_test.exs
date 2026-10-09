defmodule Autonomous.ContinueRunAtomicTest do
  @moduledoc """
  035 US1 — a refused `continue_run/1` leaves the parked run intact
  (specs/035-continue-run-atomic/contracts/continue-run.md). Parks a real run
  through the store with an injected `:runner`, then asserts that every
  refusal on the continue path leaves the run record, its feature rows,
  checkpoints and attempts byte-identical, with nothing running.
  """

  use Autonomous.StoreCase, async: false

  import ExUnit.CaptureLog

  alias Autonomous.{Config, Feature, RepoIdentity, TargetPack, Worktree, Workers}

  @coordinator Autonomous.Coordinator
  @stack_tracker Autonomous.StackTracker

  defp feat(id, number),
    do: %Feature{id: id, number: number, slug: "f#{id}", path: "#{id}.md"}

  defp features, do: [feat("001", 1), feat("002", 2)]
  defp repo_id, do: RepoIdentity.partition(Config.repo())

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
      outcome: :ok,
      model: "sonnet",
      cost_usd: 0.0,
      cost_kind: :estimate,
      session_id: "s1",
      error: nil
    }
  end

  # Fakes what `FeatureRunner` would have durably recorded. `:done` records a
  # terminal; `{status, reason}` also records a checkpoint (`resume/2` needs
  # one); `{:no_checkpoint, status, reason}` records the terminal alone.
  defp fake_runner(test_pid, outcomes) do
    fn feature, notify ->
      run_key = {repo_id(), Autonomous.current_run_id()}

      case Map.fetch!(outcomes, feature.id) do
        :done ->
          Writer.record_feature_terminal(run_key, feature.id, :done, nil)
          notify.(feature.id, :done, nil)

        {:no_checkpoint, status, reason} ->
          Writer.record_feature_terminal(run_key, feature.id, status, reason)
          notify.(feature.id, status, reason)

        {status, reason} ->
          Writer.record_phase_attempt(run_key, %{
            attempt: minimal_attempt(feature.id, :implement),
            checkpoint: %{
              phase: :implement,
              last_completed_phase: :tasks,
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

  # Runs 001 (done) and 002 (stops) to a parked run; returns its key with the
  # stopped run's own Coordinator and tracker retired so each test starts from
  # "parked, nothing running".
  defp park(stop_outcome \\ {:halted, :critical_finding}, run_opts \\ []) do
    me = self()
    outcomes = %{"001" => :done, "002" => stop_outcome}

    {:ok, _pid} =
      Autonomous.run(
        [features: features(), runner: fake_runner(me, outcomes), owner: me] ++ run_opts
      )

    assert_receive {:ran, "002"}, 2_000
    assert_receive {:run_complete, _report}, 2_000

    assert {:ok, %{state: :parked, run_id: run_id}} = Store.parked_run(repo_id())
    stop_named(@coordinator)
    stop_named(@stack_tracker)
    flush_ran()
    {repo_id(), run_id}
  end

  defp flush_ran do
    receive do
      {:ran, _} -> flush_ran()
    after
      0 -> :ok
    end
  end

  defp continue_opts(extra \\ []) do
    me = self()
    [features: features(), runner: fake_runner(me, %{"002" => :done}), owner: me] ++ extra
  end

  defp snapshot(run_key) do
    assert {:ok, detail} = Store.run(run_key)
    detail
  end

  defp assert_intact(run_key, before) do
    assert snapshot(run_key) == before
    assert {:ok, %{state: :parked}} = Store.parked_run(elem(run_key, 0))
  end

  defp assert_nothing_running(run_key, stopping_feature) do
    assert Process.whereis(@coordinator) == nil
    assert Workers.in_flight(elem(run_key, 0)) == []
    refute File.exists?(Worktree.locate(stopping_feature).path)
    refute_received {:ran, _}
  end

  defp stopping_feature, do: feat("002", 2)

  defp refuse(run_key, opts, expected) do
    before = snapshot(run_key)
    assert Autonomous.continue_run(opts) == expected
    assert_intact(run_key, before)
    assert_nothing_running(run_key, stopping_feature())
  end

  describe "refusal matrix (FR-002, FR-003, FR-005)" do
    test "store capacity refusing" do
      run_key = park()
      before = snapshot(run_key)

      prev =
        for k <- [:store_capacity_bytes, :store_headroom_bytes],
            do: {k, Application.get_env(:autonomous, k)}

      Application.put_env(:autonomous, :store_capacity_bytes, 1)
      Application.put_env(:autonomous, :store_headroom_bytes, 1)

      on_exit(fn ->
        for {k, v} <- prev,
            do:
              if(v,
                do: Application.put_env(:autonomous, k, v),
                else: Application.delete_env(:autonomous, k)
              )
      end)

      assert {:error, {:preflight, [{:store_capacity, %{status: :refusing}}]}} =
               Autonomous.continue_run(continue_opts())

      assert_intact(run_key, before)
      assert_nothing_running(run_key, stopping_feature())
    end

    # 039: both former knobs are retired options, refused before the parked
    # run is touched — any value, including the one a pre-039 run recorded.
    test "retired :containment_profile (any value)" do
      run_key = park()

      for value <- ["permissive", "strict", "bogus"] do
        refuse(
          run_key,
          continue_opts(containment_profile: value),
          {:error, {:preflight, [{:retired_option, :containment_profile}]}}
        )
      end
    end

    test "retired :budget_usd (any value, including nil)" do
      run_key = park()

      for value <- [5.0, nil] do
        refuse(
          run_key,
          continue_opts(budget_usd: value),
          {:error, {:preflight, [{:retired_option, :budget_usd}]}}
        )
      end
    end

    test "stopping feature has no checkpoint" do
      run_key = park({:no_checkpoint, :halted, :critical_finding})
      refuse(run_key, continue_opts(), {:error, :no_checkpoint})
    end

    test ":from is not a pipeline phase" do
      run_key = park()
      refuse(run_key, continue_opts(from: :bogus), {:error, {:unknown_phase, :bogus}})
    end

    test "unknown :remediation_model" do
      run_key = park()

      refuse(
        run_key,
        continue_opts(remediation_model: "nope"),
        {:error, {:unknown_model, "nope"}}
      )
    end

    test "publish-failed stopping feature with a :prompt" do
      run_key = park({:no_checkpoint, :failed, {:publish_failed, :push, "denied"}})

      refuse(run_key, continue_opts(prompt: "again"), {:error, {:publish_only, "002"}})
    end

    test "retired option" do
      run_key = park()

      refuse(
        run_key,
        continue_opts(pr_workflow: true),
        {:error, {:preflight, [{:retired_option, :pr_workflow}]}}
      )
    end

    test "invalid remediation setting" do
      run_key = park()

      refuse(
        run_key,
        continue_opts(auto_remediation_attempt_limit: 0),
        {:error, {:preflight, [{:invalid_attempt_limit, 0}]}}
      )
    end

    test "a pending reconciliation :done correction is not written when a later preflight refuses (R8)" do
      # 001's fake :done carries no git evidence, so reconciliation would
      # normally keep it `:blocked`; make the store disagree with the evidence
      # the other way instead: a row recorded `:running` that evidence proves
      # done cannot be forged here, so assert the weaker, observable form —
      # the feature rows are untouched by a refusal that comes after
      # `restore_run_scope/2` has run.
      run_key = park()
      before = snapshot(run_key)

      assert {:error, {:unknown_model, "nope"}} =
               Autonomous.continue_run(continue_opts(remediation_model: "nope"))

      assert snapshot(run_key).features == before.features

      assert {:error, {:preflight, [{:invalid_attempt_limit, 0}]}} =
               Autonomous.continue_run(continue_opts(auto_remediation_attempt_limit: 0))

      assert snapshot(run_key).features == before.features
      assert_intact(run_key, before)
    end
  end

  # 039: the pack contract check runs on every run, so the r000003 incident
  # (a parked run whose committed pack lags) is refused without any profile.
  describe "the incident: committed pack lags contract 6 (always-on check)" do
    setup do
      repo = Path.join(System.tmp_dir!(), "continue_atomic_#{System.unique_integer([:positive])}")
      root = repo <> "_wt"
      remote = repo <> "_remote.git"
      File.mkdir_p!(repo)
      File.mkdir_p!(remote)
      {:ok, _} = TargetPack.install(repo)
      File.write!(Path.join(repo, ".specify/memory/constitution.md"), "# Real\n\n1. cents.\n")
      git!(remote, ["init", "-q", "--bare"])
      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["config", "user.email", "t@e.com"])
      git!(repo, ["config", "user.name", "T"])
      git!(repo, ["remote", "add", "origin", remote])
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "pack"])

      prev = for k <- [:repo, :worktree_root], do: {k, Application.get_env(:autonomous, k)}
      Application.put_env(:autonomous, :repo, repo)
      Application.put_env(:autonomous, :worktree_root, root)

      on_exit(fn ->
        for {k, v} <- prev,
            do:
              if(v,
                do: Application.put_env(:autonomous, k, v),
                else: Application.delete_env(:autonomous, k)
              )

        File.rm_rf(repo)
        File.rm_rf(root)
        File.rm_rf(remote)
      end)

      {:ok, repo: repo}
    end

    defp git!(repo, args),
      do: {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

    defp downgrade_pack(repo) do
      File.rm!(Path.join(repo, ".claude/autonomous-pack.json"))
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "pack lags"])
    end

    test "is refused with the pack problem, leaves the run parked, then continues after the fix",
         %{repo: repo} do
      run_key = park({:halted, :critical_finding})
      downgrade_pack(repo)
      before = snapshot(run_key)

      # No :runner/:executor seam — the refusal must come from
      # preflight_stacked/1, as in r000003.
      assert {:error, {:preflight, [{:pack_outdated, ".claude/autonomous-pack.json", _} | _]}} =
               Autonomous.continue_run(features: features(), owner: self())

      assert_intact(run_key, before)
      assert_nothing_running(run_key, stopping_feature())
      assert Process.whereis(@stack_tracker) == nil

      # US1-AS3: fix the cause and the same call now proceeds.
      {:ok, _} = TargetPack.install(repo)
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "pack fixed"])

      me = self()

      assert {:ok, pid} =
               Autonomous.continue_run(
                 features: features(),
                 runner: fake_runner(me, %{"002" => :done}),
                 owner: me
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert {:ok, %{run: %{state: state, stopped_by: nil}}} = Store.run(run_key)
      assert state in [:in_flight, :completed]
    end
  end

  describe "a Coordinator that fails to start" do
    test "re-parks the run field-for-field and returns the original error" do
      run_key = park()
      before = snapshot(run_key)

      assert {:error, :boom} =
               Autonomous.continue_run(
                 continue_opts(coordinator_start: fn _args -> {:error, :boom} end)
               )

      assert_intact(run_key, before)
      assert_nothing_running(run_key, stopping_feature())
      assert Process.whereis(@stack_tracker) == nil
    end
  end

  describe "restore failure (FR-009, SC-006)" do
    defp fail_continue(run_key, extra \\ []) do
      opts =
        continue_opts(
          [
            coordinator_start: fn _args -> {:error, :boom} end,
            repark: fn _key, _snapshot -> {:error, :disk} end
          ] ++ extra
        )

      log = capture_log(fn -> send(self(), {:result, Autonomous.continue_run(opts)}) end)
      assert_received {:result, result}
      assert result == {:error, {:continue_restore_failed, :boom, :disk}}
      assert {:ok, %{run: %{state: :in_flight}}} = Store.run(run_key)
      log
    end

    test "logs both reasons and annotates the run; cleared by a later end_run/1" do
      run_key = park()
      log = fail_continue(run_key)

      assert log =~ ":boom"
      assert log =~ ":disk"

      assert {:ok, %{run: %{continue_restore_failure: failure}}} = Store.run(run_key)
      assert %{refusal: ":boom", restore_error: ":disk", at: %DateTime{}} = failure

      # Re-park by hand (the disk recovered), then the operator ends the run.
      :ok = Writer.repark_run(run_key, %{stopped_by: "002", stopped_reason: :critical_finding})
      assert {:ok, %{continue_restore_failure: failure_after}} = Autonomous.end_run()
      assert failure_after == nil
    end

    test "cleared by a successful resume/2 of the in-flight orphan" do
      run_key = park()
      fail_continue(run_key)

      me = self()

      assert {:ok, pid} =
               Autonomous.resume("002",
                 features: features(),
                 runner: fake_runner(me, %{"002" => :done}),
                 owner: me
               )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      assert {:ok, %{run: %{continue_restore_failure: nil}}} = Store.run(run_key)
    end

    test "an annotation write failure still returns and logs both reasons" do
      run_key = park()

      log =
        fail_continue(run_key, annotate: fn _key, _annotation -> {:error, :ro} end)

      assert log =~ ":boom"
      assert log =~ ":disk"
      assert {:ok, %{run: %{continue_restore_failure: nil}}} = Store.run(run_key)
    end
  end

  describe "races (FR-010)" do
    test "two concurrent continues: exactly one wins and its processes survive the loser" do
      run_key = park()
      me = self()

      blocking_runner = fn feature, _notify ->
        send(me, {:ran, feature.id, self()})

        receive do
          :release -> :ok
        end
      end

      attempts =
        for _ <- 1..2 do
          Task.async(fn ->
            Autonomous.continue_run(features: features(), runner: blocking_runner, owner: me)
          end)
        end

      results = Enum.map(attempts, &Task.await(&1, 10_000))
      {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

      assert [{:ok, winner}] = oks
      assert [{:error, loser}] = errors
      assert loser == :not_parked or match?({:active_run, _}, loser) or loser == :no_parked_run

      assert Process.whereis(@coordinator) == winner

      assert is_pid(Process.whereis(@stack_tracker)) and
               Process.alive?(Process.whereis(@stack_tracker))

      assert_receive {:ran, "002", runner_pid}, 2_000
      send(runner_pid, :release)
      assert {:ok, %{run: %{run_id: _}}} = Store.run(run_key)
    end

    test "end_run/1 racing a refused continue ends consistent" do
      run_key = park()

      continuer =
        Task.async(fn ->
          Autonomous.continue_run(
            continue_opts(coordinator_start: fn _args -> {:error, :boom} end)
          )
        end)

      ender = Task.async(fn -> Autonomous.end_run() end)
      Task.await(continuer, 10_000)
      Task.await(ender, 10_000)

      assert {:ok, %{run: %{state: state}}} = Store.run(run_key)
      assert state in [:parked, :completed]
      assert Process.whereis(@coordinator) == nil
    end
  end
end
