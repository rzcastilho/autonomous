defmodule Autonomous.PhaseStepTest do
  # async: false — swaps the global :jido_claude sdk_module + a scenario flag.
  use ExUnit.Case, async: false

  alias Jido.{AgentServer, Signal}
  alias Autonomous.{Config, Feature, FeatureAgent, PhaseStep}

  defmodule FakeSDK do
    alias ClaudeAgentSDK.Message

    def query(prompt, _options) do
      capture_prompt(prompt)

      case Application.get_env(:autonomous, :phase_step_test_scenario, :happy) do
        :transient_once ->
          if first_call?(), do: transient_messages(), else: success_messages()

        :transient_always ->
          transient_messages()

        :stranded_once ->
          if first_call?(), do: stranded_messages(), else: success_messages()

        :stranded_always ->
          stranded_messages()

        # 032: success, but a Bash command was auto-backgrounded and never read back.
        :background_once ->
          if first_call?(), do: background_messages(), else: success_messages()

        :background_always ->
          background_messages()

        # Strands only on a retry whose prompt carries no corrective note — used to
        # prove the note is what reaches the model, not just that a retry happened.
        :background_until_noted ->
          if String.contains?(prompt, "Retry note"),
            do: success_messages(),
            else: background_messages()

        _ ->
          success_messages()
      end
    end

    defp success_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: "done", is_error: false, total_cost_usd: 0.10},
          raw: %{}
        }
      ]
    end

    defp transient_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :result,
          subtype: :error,
          data: %{
            session_id: "s",
            result: "API Error: Server error mid-response.",
            is_error: true,
            total_cost_usd: nil
          },
          raw: %{}
        }
      ]
    end

    # A session that reports success while a tool call it made never returned.
    defp stranded_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :assistant,
          data: %{
            message: %{
              "content" => [
                %{"type" => "tool_use", "id" => "c1", "name" => "Read", "input" => %{}}
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :user,
          data: %{
            message: %{
              "content" => [
                %{"type" => "tool_result", "tool_use_id" => "c1", "content" => "ok"}
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :assistant,
          data: %{
            message: %{
              "content" => [
                %{"type" => "tool_use", "id" => "c2", "name" => "Task", "input" => %{}}
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{
            session_id: "s",
            result: "waiting on agents",
            is_error: false,
            total_cost_usd: 0.10
          },
          raw: %{}
        }
      ]
    end

    defp background_messages do
      [
        %Message{type: :system, subtype: :init, data: %{session_id: "s"}, raw: %{}},
        %Message{
          type: :assistant,
          data: %{
            message: %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "b1",
                  "name" => "Bash",
                  "input" => %{"command" => "npm run test:e2e"}
                }
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :user,
          data: %{
            message: %{
              "content" => [
                %{
                  "type" => "tool_result",
                  "tool_use_id" => "b1",
                  "content" =>
                    "Command did not complete within its 600s timeout and was moved to the background (ID: bgx1). " <>
                      "Output is being written to: /tmp/bgx1.output"
                }
              ]
            }
          },
          raw: %{}
        },
        %Message{
          type: :result,
          subtype: :success,
          data: %{session_id: "s", result: "waiting", is_error: false, total_cost_usd: 0.10},
          raw: %{}
        }
      ]
    end

    defp capture_prompt(prompt) do
      case Application.get_env(:autonomous, :phase_step_test_prompts) do
        nil -> :ok
        agent -> Agent.update(agent, &[prompt | &1])
      end
    end

    defp first_call? do
      case Application.get_env(:autonomous, :phase_step_test_counter) do
        nil -> false
        agent -> Agent.get_and_update(agent, fn n -> {n == 0, n + 1} end)
      end
    end
  end

  setup do
    prev_sdk = Application.get_env(:jido_claude, :sdk_module)
    Application.put_env(:jido_claude, :sdk_module, FakeSDK)
    Application.put_env(:autonomous, :phase_step_test_scenario, :happy)

    on_exit(fn ->
      if prev_sdk,
        do: Application.put_env(:jido_claude, :sdk_module, prev_sdk),
        else: Application.delete_env(:jido_claude, :sdk_module)

      Application.delete_env(:autonomous, :phase_step_test_scenario)
      Application.delete_env(:autonomous, :phase_step_test_counter)
      Application.delete_env(:autonomous, :phase_step_test_prompts)
    end)

    :ok
  end

  defp feature,
    do: %Feature{id: "042", number: 42, slug: "phase-step", path: "docs/breakdown/042.md"}

  defp start_agent! do
    {:ok, pid} =
      AgentServer.start_link(
        agent: FeatureAgent,
        id: "phase-step-#{System.unique_integer([:positive])}",
        register_global: false
      )

    {:ok, _agent} =
      AgentServer.call(
        pid,
        Signal.new!("feature.init", %{feature: feature(), phase: :specify}, source: "/test"),
        5_000
      )

    pid
  end

  defp attach_phase_telemetry do
    test_pid = self()
    handler = "phase-step-tele-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [[:speckit, :phase, :start], [:speckit, :phase, :stop]],
      fn event, _meas, meta, _ -> send(test_pid, {:tele, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "default opts: span meta matches the original run_phase_with_retry shape" do
    pid = start_agent!()
    attach_phase_telemetry()

    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000)

    assert agent.state.last_outcome == :ok

    model = Config.model_for(:specify)

    assert_received {:tele, [:speckit, :phase, :start],
                     %{feature_id: "042", phase: :specify, model: ^model, step: 1}}

    assert_received {:tele, [:speckit, :phase, :stop],
                     %{
                       feature_id: "042",
                       phase: :specify,
                       model: ^model,
                       step: 1,
                       outcome: :ok,
                       cost: 0.10
                     }}
  end

  test ":span_meta keys merge into the telemetry span meta without displacing the base keys" do
    pid = start_agent!()
    attach_phase_telemetry()

    PhaseStep.run(pid, feature(), :specify,
      step: 1,
      timeout: 5_000,
      span_meta: %{attempt: 1, limit: 2}
    )

    assert_received {:tele, [:speckit, :phase, :stop],
                     %{phase: :specify, step: 1, attempt: 1, limit: 2}}
  end

  test "retries a transient failure up to :retries times, then succeeds" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    Application.put_env(:autonomous, :phase_step_test_counter, counter)
    Application.put_env(:autonomous, :phase_step_test_scenario, :transient_once)

    pid = start_agent!()

    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000, retries: 1)

    assert agent.state.last_outcome == :ok
    Agent.stop(counter)
  end

  test "gives up after exhausting :retries on a persistent transient failure" do
    Application.put_env(:autonomous, :phase_step_test_scenario, :transient_always)

    pid = start_agent!()

    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000, retries: 1)

    assert agent.state.last_outcome == :error
  end

  test "default :retries falls back to Config.phase_max_retries/0" do
    Application.put_env(:autonomous, :phase_step_test_scenario, :transient_always)
    prev = Application.get_env(:autonomous, :phase_max_retries)
    Application.put_env(:autonomous, :phase_max_retries, 0)

    pid = start_agent!()
    agent = PhaseStep.run(pid, feature(), :specify, step: 1, timeout: 5_000)

    assert agent.state.last_outcome == :error

    if prev,
      do: Application.put_env(:autonomous, :phase_max_retries, prev),
      else: Application.delete_env(:autonomous, :phase_max_retries)
  end

  describe "retry ladder beyond the transient case" do
    # A worktree whose plan.md is an untouched copy of the plan template, plus a
    # variant with no plan.md at all — the two ways the plan gate fails.
    defp gate_worktree(plan_body) do
      template = File.read!(Path.expand("../fixtures/templates/plan-template.md", __DIR__))
      tmp = Path.join(System.tmp_dir!(), "phase_step_gate_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "specs/042-phase-step"))
      File.mkdir_p!(Path.join(tmp, ".specify/templates"))
      System.cmd("git", ["init"], cd: tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      File.write!(Path.join(tmp, ".specify/templates/plan-template.md"), template)
      if plan_body, do: File.write!(Path.join(tmp, "specs/042-phase-step/plan.md"), plan_body)

      %{path: tmp}
    end

    defp start_agent_with_worktree!(worktree) do
      {:ok, pid} =
        AgentServer.start_link(
          agent: FeatureAgent,
          id: "phase-step-wt-#{System.unique_integer([:positive])}",
          register_global: false
        )

      {:ok, _agent} =
        AgentServer.call(
          pid,
          Signal.new!("feature.init", %{feature: feature(), phase: :plan, worktree: worktree},
            source: "/test"
          ),
          5_000
        )

      pid
    end

    test "retries a session that ended with work outstanding, then succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      Application.put_env(:autonomous, :phase_step_test_counter, counter)
      Application.put_env(:autonomous, :phase_step_test_scenario, :stranded_once)

      agent =
        PhaseStep.run(start_agent!(), feature(), :clarify, step: 1, timeout: 5_000, retries: 1)

      assert agent.state.last_outcome == :ok
      Agent.stop(counter)
    end

    test "gives up on a session that always ends with work outstanding" do
      Application.put_env(:autonomous, :phase_step_test_scenario, :stranded_always)

      agent =
        PhaseStep.run(start_agent!(), feature(), :clarify, step: 1, timeout: 5_000, retries: 1)

      assert agent.state.last_outcome == :error
      assert agent.state.last_signals == %{outstanding_work?: true}
    end

    test "retries a session that ended on a backgrounded command, then succeeds (032)" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      Application.put_env(:autonomous, :phase_step_test_counter, counter)
      Application.put_env(:autonomous, :phase_step_test_scenario, :background_once)

      agent =
        PhaseStep.run(start_agent!(), feature(), :clarify, step: 1, timeout: 5_000, retries: 1)

      assert agent.state.last_outcome == :ok
      assert length(agent.state.history) == 2
      Agent.stop(counter)
    end

    test "gives up after one retry with the stranded command as a signal (032)" do
      Application.put_env(:autonomous, :phase_step_test_scenario, :background_always)

      agent =
        PhaseStep.run(start_agent!(), feature(), :clarify, step: 1, timeout: 5_000, retries: 1)

      assert agent.state.last_outcome == :error

      assert agent.state.last_signals == %{
               outstanding_work?: true,
               backgrounded: ["npm run test:e2e"]
             }

      assert length(agent.state.history) == 2

      assert Autonomous.Pipeline.next(:clarify, :error, agent.state.last_signals) ==
               {:failed, {:backgrounded_command, :clarify, ["npm run test:e2e"]}}
    end

    test "both gates firing (backgrounded + outstanding) is one retry, not two (032)" do
      Application.put_env(:autonomous, :phase_step_test_scenario, :background_always)

      agent =
        PhaseStep.run(start_agent!(), feature(), :clarify, step: 1, timeout: 5_000, retries: 3)

      # retries: 3 would allow four sessions; the loop stops once the budget given is
      # spent — assert exactly retries + 1 sessions, never an extra one per gate.
      assert length(agent.state.history) == 4
    end

    test "the retry's prompt carries the corrective note; the first attempt does not (032, FR-002a)" do
      {:ok, prompts} = Agent.start_link(fn -> [] end)
      Application.put_env(:autonomous, :phase_step_test_prompts, prompts)
      Application.put_env(:autonomous, :phase_step_test_scenario, :background_until_noted)

      agent =
        PhaseStep.run(start_agent!(), feature(), :implement, step: 1, timeout: 5_000, retries: 1)

      assert agent.state.last_outcome == :ok
      [first, second] = prompts |> Agent.get(& &1) |> Enum.reverse()
      refute first =~ "Retry note"
      assert second =~ "Retry note"
      assert second =~ "- npm run test:e2e"
      Agent.stop(prompts)
    end

    test "a retry for another reason carries no corrective note (032, FR-002a)" do
      {:ok, prompts} = Agent.start_link(fn -> [] end)
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      Application.put_env(:autonomous, :phase_step_test_prompts, prompts)
      Application.put_env(:autonomous, :phase_step_test_counter, counter)
      Application.put_env(:autonomous, :phase_step_test_scenario, :stranded_once)

      PhaseStep.run(start_agent!(), feature(), :clarify, step: 1, timeout: 5_000, retries: 1)

      assert [_, _] = all = prompts |> Agent.get(& &1) |> Enum.reverse()
      refute Enum.any?(all, &(&1 =~ "Retry note"))
      Agent.stop(prompts)
      Agent.stop(counter)
    end

    test "retries an artifact left as an unfilled template" do
      template = File.read!(Path.expand("../fixtures/templates/plan-template.md", __DIR__))
      pid = start_agent_with_worktree!(gate_worktree(template))

      agent = PhaseStep.run(pid, feature(), :plan, step: 1, timeout: 5_000, retries: 1)

      # Still unfilled after the retry (the fake SDK writes nothing), but the
      # ladder did re-run rather than accepting the first attempt.
      assert agent.state.last_signals[:unfilled_artifact?]
      assert length(agent.state.history) == 2
    end

    test "does not retry a plainly missing artifact — that refusal is deterministic" do
      pid = start_agent_with_worktree!(gate_worktree(nil))

      agent = PhaseStep.run(pid, feature(), :plan, step: 1, timeout: 5_000, retries: 1)

      # artifact_absent_at_start? (022, FR-014) fires independently of this
      # gate's own missing_artifact verdict — plan.md was absent when the
      # phase started, same as it is missing after.
      assert agent.state.last_signals == %{
               missing_artifact: "plan.md",
               artifact_absent_at_start?: true
             }

      assert length(agent.state.history) == 1
    end
  end

  describe "ensure_recorded/3 — the swallowed-failure guard" do
    alias Autonomous.PhaseResult

    defp agent_with(history, extra \\ %{}) do
      %{state: Map.merge(%{history: history, last_outcome: :ok, last_result: nil}, extra)}
    end

    test "an agent whose history grew is returned untouched" do
      before = agent_with([])
      after_agent = agent_with([%{phase: :plan, outcome: :ok}], %{last_outcome: :ok})

      assert PhaseStep.ensure_recorded(before, after_agent, :plan) == after_agent
    end

    test "an unchanged history is patched to a loud, non-transient error instead of stale :ok" do
      # `AgentServer.call` returns `{:ok, agent}` even when the action never
      # ran to completion (probed: a timed-out action leaves the previous
      # phase's `:ok` in place). Trusting it would advance past a phase that
      # never happened.
      stale =
        agent_with([%{phase: :specify, outcome: :ok}], %{last_outcome: :ok, phase: :specify})

      patched = PhaseStep.ensure_recorded(stale, stale, :plan)

      assert patched.state.last_outcome == :error
      assert patched.state.phase == :plan

      assert %PhaseResult{status: :error, error: {:no_phase_result, :plan}} =
               patched.state.last_result

      refute PhaseResult.transient?(patched.state.last_result)
      assert [%{phase: :plan, outcome: :error} | _] = patched.state.history
    end
  end

  describe "branch drift (027, US2)" do
    test "a drifted session is not retried, not even as a transient one" do
      tmp = Path.join(System.tmp_dir!(), "phase_step_drift_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      System.cmd("git", ["init", "-b", "feature/042-phase-step"], cd: tmp)
      File.write!(Path.join(tmp, "README.md"), "seed\n")
      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "add", "-A"], cd: tmp)

      System.cmd("git", ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", "seed"],
        cd: tmp
      )

      on_exit(fn -> File.rm_rf(tmp) end)

      # The stubbed harness session's own effect, exactly as at the
      # `RunFeaturePhase` boundary.
      System.cmd("git", ["checkout", "-b", "other"], cd: tmp)

      worktree = %Autonomous.Worktree{
        path: tmp,
        branch: "feature/042-phase-step",
        repo: tmp,
        feature_id: "042"
      }

      pid = start_agent_with_worktree!(worktree)
      agent = PhaseStep.run(pid, feature(), :plan, step: 1, timeout: 5_000, retries: 1)

      assert agent.state.last_outcome == :error

      assert %{branch_drift: %{expected: "feature/042-phase-step", observed: "other"}} =
               agent.state.last_signals

      # Exactly one session — the retry ladder never re-dispatched.
      assert length(agent.state.history) == 1
    end
  end
end
