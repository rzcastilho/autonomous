defmodule SpeckitOrchestrator.AnalyzeRunnerTest do
  # async: false — swaps the global :jido_claude sdk_module + scenario env.
  use ExUnit.Case, async: false

  alias Jido.{AgentServer, Signal}
  alias SpeckitOrchestrator.{AnalyzeRunner, Feature, FeatureAgent, Ledger}
  alias SpeckitOrchestrator.Remediation.Settings

  # Scripted fake agent: analyze runs replay a fixture's passes in order, one
  # per call; the corrective step succeeds or fails per scenario. Each
  # dispatched action runs in its own process (not the test process), so the
  # call log lives in a shared `Agent` named through app env — the same channel
  # `chunk_runner_test.exs` uses.
  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    # Checked *before* the analyze branch and matched on a phrase unique to the
    # pack: `priv/prompts/analyze_remediation.md` deliberately mentions
    # `/speckit.analyze` (telling the step not to re-run it), so a naive
    # analyze-first match would classify a corrective step as an analyze run.
    @remediation_marker "analyze auto-remediation loop"

    def query(prompt, _options) do
      cond do
        String.contains?(prompt, @remediation_marker) ->
          record(:remediation, prompt)
          if remediation_fails?(), do: error_messages(), else: success_messages("Fixed.")

        String.contains?(prompt, "/speckit.analyze") ->
          record(:analyze, prompt)
          success_messages(next_pass())

        true ->
          success_messages("Phase completed.")
      end
    end

    # The next unconsumed pass of the configured fixture; the last pass repeats
    # if the loop asks for more than the fixture scripts.
    defp next_pass do
      passes = passes()
      index = Agent.get_and_update(state_agent(), fn s -> {s.pass, %{s | pass: s.pass + 1}} end)
      pass = Enum.at(passes, index, List.last(passes))

      if is_binary(pass), do: pass, else: Jason.encode!(pass)
    end

    defp passes do
      Application.fetch_env!(:speckit_orchestrator, :analyze_runner_test_passes)
    end

    defp remediation_fails? do
      Application.get_env(:speckit_orchestrator, :analyze_runner_test_remediation, :ok) == :error
    end

    defp record(kind, prompt) do
      Agent.update(state_agent(), fn s -> %{s | calls: s.calls ++ [{kind, prompt}]} end)
    end

    defp state_agent do
      Application.fetch_env!(:speckit_orchestrator, :analyze_runner_test_state)
    end

    defp success_messages(text) do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: text, is_error: false, total_cost_usd: 0.10},
          raw: %{}
        }
      ]
    end

    # A deterministic (non-transient) failure, so `PhaseStep`'s retry ladder
    # does not mask it as a retryable server drop.
    defp error_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error,
          data: %{
            session_id: "s",
            result: "Refused: the finding needs a product decision.",
            is_error: true,
            total_cost_usd: 0.10
          },
          raw: %{}
        }
      ]
    end
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)

    {:ok, agent} = Agent.start_link(fn -> %{pass: 0, calls: []} end)
    Application.put_env(:speckit_orchestrator, :analyze_runner_test_state, agent)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:speckit_orchestrator, :analyze_runner_test_state)
      Application.delete_env(:speckit_orchestrator, :analyze_runner_test_passes)
      Application.delete_env(:speckit_orchestrator, :analyze_runner_test_remediation)
    end)

    %{agent: agent}
  end

  # ---- harness --------------------------------------------------------------

  defp script(fixture) do
    passes =
      ["test", "fixtures", "analyze", "#{fixture}.json"]
      |> Path.join()
      |> File.read!()
      |> Jason.decode!()

    Application.put_env(:speckit_orchestrator, :analyze_runner_test_passes, passes)
  end

  defp remediation_fails!,
    do: Application.put_env(:speckit_orchestrator, :analyze_runner_test_remediation, :error)

  defp calls(agent), do: Agent.get(agent, & &1.calls)
  defp calls(agent, kind), do: agent |> calls() |> Enum.filter(&(elem(&1, 0) == kind))

  defp feature,
    do: %Feature{id: "017", slug: "auto-remediation", path: "docs/breakdown/017.md"}

  defp start_agent!(ledger \\ nil) do
    {:ok, pid} =
      AgentServer.start_link(
        agent: FeatureAgent,
        id: "analyze-runner-#{System.unique_integer([:positive])}",
        register_global: false
      )

    {:ok, _agent} =
      AgentServer.call(
        pid,
        Signal.new!(
          "feature.init",
          %{feature: feature(), phase: :analyze, ledger: ledger},
          source: "/test"
        ),
        5_000
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    pid
  end

  defp settings(opts \\ []) do
    {:ok, settings} =
      Settings.validate(%{
        enabled?: Keyword.get(opts, :enabled?, true),
        threshold: Keyword.get(opts, :threshold, :high),
        attempt_limit: Keyword.get(opts, :attempt_limit, 2)
      })

    settings
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "analyze_runner_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp run(opts) do
    AnalyzeRunner.run(%{
      pid: Keyword.fetch!(opts, :pid),
      feature: feature(),
      worktree: Keyword.get(opts, :worktree),
      layout: nil,
      timeout: 5_000,
      step: 5,
      ledger: Keyword.get(opts, :ledger),
      settings: Keyword.get(opts, :settings) || settings()
    })
  end

  defp logs(dir), do: dir |> Path.join(".speckit_logs") |> File.ls!() |> Enum.sort()

  # ---- US1: self-heal without waking a human --------------------------------

  test "converges: remediates the first pass and advances on a clean second", %{agent: agent} do
    script("high-then-clean")
    pid = start_agent!()
    dir = tmp_dir()

    result = run(pid: pid, worktree: dir)

    assert result.state.last_outcome == :ok
    assert result.state.last_signals == %{critical?: false, high?: false}
    assert result.state.terminal_reason == nil

    assert result.state.analyze_remediation == %{
             attempts_used: 1,
             limit: 2,
             threshold: "high",
             enabled: true
           }

    assert length(calls(agent, :analyze)) == 2
    assert length(calls(agent, :remediation)) == 1
  end

  test "records every attempt without consuming a pipeline step number" do
    script("high-then-clean")
    pid = start_agent!()
    dir = tmp_dir()

    run(pid: pid, worktree: dir)

    assert logs(dir) == [
             "05-analyze-a1.md",
             "05-analyze-a2.md",
             "05-analyze.md",
             "05-remediation-a1.md"
           ]
  end

  test "the roll-up 05-analyze.md carries the FINAL analyze run (FR-005)" do
    script("high-then-clean")
    pid = start_agent!()
    dir = tmp_dir()

    run(pid: pid, worktree: dir)

    rollup = dir |> Path.join(".speckit_logs/05-analyze.md") |> File.read!()
    assert rollup =~ ~s("summary":"Clean — no findings.")
    refute rollup =~ "tasks.md has no task for FR-004"
  end

  test "the remediation record carries the instruction and the triggering findings verbatim" do
    script("high-then-clean")
    pid = start_agent!()
    dir = tmp_dir()

    run(pid: pid, worktree: dir)

    record = dir |> Path.join(".speckit_logs/05-remediation-a1.md") |> File.read!()

    assert record =~ "Attempt 1 of 2. Severity threshold: high."
    assert record =~ "tasks.md has no task for FR-004"
    # below-threshold findings are not part of what triggered the attempt
    refute record =~ "plan.md wording nit"
    assert record =~ "### step output"
  end

  test "the corrective instruction is scoped to at-or-above-threshold findings", %{agent: agent} do
    script("high-then-clean")
    pid = start_agent!()

    run(pid: pid)

    [{:remediation, prompt}] = calls(agent, :remediation)
    assert prompt =~ "tasks.md has no task for FR-004"
    refute prompt =~ "plan.md wording nit"
  end

  test "disabled: one analyze run, no second harness call, no extra record (FR-016/SC-004)", %{
    agent: agent
  } do
    script("high-then-clean")
    pid = start_agent!()
    dir = tmp_dir()

    result = run(pid: pid, worktree: dir, settings: settings(enabled?: false))

    assert result.state.last_signals == %{critical?: false, high?: true}
    assert result.state.analyze_remediation == nil
    assert length(calls(agent, :analyze)) == 1
    assert calls(agent, :remediation) == []
    assert logs(dir) == ["05-analyze.md"]
  end

  test "below-threshold findings make no harness call beyond the first analyze run", %{
    agent: agent
  } do
    script("medium-only")
    pid = start_agent!()
    dir = tmp_dir()

    result = run(pid: pid, worktree: dir)

    assert result.state.last_outcome == :ok
    assert result.state.analyze_remediation == nil
    assert length(calls(agent, :analyze)) == 1
    assert calls(agent, :remediation) == []
    assert logs(dir) == ["05-analyze.md"]
  end

  test "an unrecognized severity matches no threshold, so no attempt runs (research R3)", %{
    agent: agent
  } do
    script("unknown-severity")
    pid = start_agent!()

    result = run(pid: pid)

    assert result.state.last_outcome == :ok
    assert calls(agent, :remediation) == []
  end

  test "a malformed analyze report is a phase failure, never a loop entry", %{agent: agent} do
    script("malformed")
    pid = start_agent!()

    result = run(pid: pid)

    assert result.state.last_outcome == :error
    assert result.state.terminal_reason == nil
    assert result.state.analyze_remediation == nil
    assert calls(agent, :remediation) == []
  end

  # ---- US2: give up safely, with a full history -----------------------------

  test "spends exactly `attempt_limit` attempts, never one more (SC-003)", %{agent: agent} do
    script("persistent-high")
    pid = start_agent!()
    dir = tmp_dir()

    result = run(pid: pid, worktree: dir, settings: settings(attempt_limit: 2))

    assert length(calls(agent, :remediation)) == 2
    assert length(calls(agent, :analyze)) == 3

    assert Enum.count(logs(dir), &String.starts_with?(&1, "05-remediation-a")) == 2

    assert result.state.last_signals[:remediation] == %{attempts: 2, limit: 2, exhausted?: true}

    assert result.state.analyze_remediation == %{
             attempts_used: 2,
             limit: 2,
             threshold: "high",
             enabled: true
           }
  end

  test "the same bound holds at a different attempt limit", %{agent: agent} do
    script("persistent-high")
    pid = start_agent!()

    run(pid: pid, settings: settings(attempt_limit: 4))

    assert length(calls(agent, :remediation)) == 4
    assert length(calls(agent, :analyze)) == 5
  end

  test "exhaustion still hands the gate the final run's own signals" do
    script("persistent-high")
    pid = start_agent!()

    result = run(pid: pid)

    assert result.state.last_outcome == :ok
    assert result.state.last_signals[:critical?] == false
    assert result.state.last_signals[:high?] == true
    assert result.state.terminal_reason == nil
  end

  test "a failed remediation step stops immediately without consuming the rest (FR-008)", %{
    agent: agent
  } do
    script("persistent-high")
    remediation_fails!()
    pid = start_agent!()
    dir = tmp_dir()

    result = run(pid: pid, worktree: dir, settings: settings(attempt_limit: 4))

    assert result.state.terminal_reason == {:failed, :remediation_failed}
    assert result.state.last_outcome == :error
    assert result.state.last_signals == %{}

    # one attempt burned, three left unspent
    assert length(calls(agent, :remediation)) == 1
    assert length(calls(agent, :analyze)) == 1
    assert Enum.count(logs(dir), &String.starts_with?(&1, "05-remediation-a")) == 1

    assert result.state.analyze_remediation.attempts_used == 1
  end

  test "a breaker trip between steps halts after the in-flight step finishes", %{agent: agent} do
    script("persistent-high")

    # 0.10 per fake call: analyze run 1 leaves committed 0.10 (< 0.15, so the
    # loop still dispatches an attempt); the attempt commits 0.10 more and trips
    # the breaker, which is only consulted *between* steps.
    {:ok, ledger} = Ledger.start_link(budget: 0.15, name: nil)
    pid = start_agent!(ledger)

    result = run(pid: pid, ledger: ledger, settings: settings(attempt_limit: 4))

    assert result.state.terminal_reason == {:halted, :breaker}
    assert result.state.last_outcome == :error
    assert result.state.last_signals == %{}

    assert length(calls(agent, :remediation)) == 1
    assert length(calls(agent, :analyze)) == 1
    assert Ledger.breaker_tripped?(ledger)
  end

  test "worsening findings are decided by the FINAL run only (High -> Critical)", %{agent: agent} do
    script("worsening")
    pid = start_agent!()

    result = run(pid: pid, settings: settings(attempt_limit: 2))

    # the gate sees pass 3's Critical, not pass 1's High
    assert result.state.last_signals[:critical?] == true
    assert result.state.last_signals[:high?] == false
    assert length(calls(agent, :analyze)) == 3
    assert length(calls(agent, :remediation)) == 2
  end

  test "every attempt is Ledger-accounted, with no exemption (FR-009)" do
    script("persistent-high")
    {:ok, ledger} = Ledger.start_link(budget: 100.0, name: nil)
    pid = start_agent!(ledger)

    run(pid: pid, ledger: ledger, settings: settings(attempt_limit: 2))

    # 3 analyze runs + 2 attempts, 0.10 each
    assert_in_delta Ledger.spent(ledger), 0.50, 0.0001
  end

  test "emits one [:speckit, :remediation] span per attempt" do
    script("persistent-high")
    pid = start_agent!()

    test_pid = self()
    handler = "remediation-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:speckit, :remediation, :start], [:speckit, :remediation, :stop]],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    run(pid: pid, settings: settings(attempt_limit: 2))

    assert_received {:tele, [:speckit, :remediation, :start],
                     %{
                       feature_id: "017",
                       phase: :analyze,
                       attempt: 1,
                       limit: 2,
                       threshold: :high,
                       findings_count: 1,
                       max_severity: :high
                     }}

    assert_received {:tele, [:speckit, :remediation, :stop],
                     %{attempt: 1, outcome: :ok, cost: 0.10}}

    assert_received {:tele, [:speckit, :remediation, :start], %{attempt: 2, limit: 2}}
    assert_received {:tele, [:speckit, :remediation, :stop], %{attempt: 2, outcome: :ok}}
  end

  test "the analyze phase span carries attempt/limit while the loop is enabled" do
    script("high-then-clean")
    pid = start_agent!()

    test_pid = self()
    handler = "analyze-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :stop],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    run(pid: pid)

    assert_received {:tele, [:speckit, :phase, :stop], %{phase: :analyze, attempt: 1, limit: 2}}
    assert_received {:tele, [:speckit, :phase, :stop], %{phase: :analyze, attempt: 2, limit: 2}}
  end

  test "with the loop off the analyze span meta is byte-identical to pre-017 (SC-007a)" do
    script("high-then-clean")
    pid = start_agent!()

    test_pid = self()
    handler = "analyze-off-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:speckit, :phase, :stop],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    run(pid: pid, settings: settings(enabled?: false))

    assert_received {:tele, [:speckit, :phase, :stop], meta}

    keys = meta |> Map.delete(:telemetry_span_context) |> Map.keys() |> Enum.sort()
    assert keys == [:cost, :feature_id, :model, :outcome, :phase, :step]
  end
end
