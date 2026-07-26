defmodule SpeckitOrchestrator.ChunkingTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.{ChunkState, Chunking, TaskPhaseRef, TaskPlan}
  alias SpeckitOrchestrator.TaskPlan.{Task, TaskPhase}

  # ---- fixtures --------------------------------------------------------------

  defp make_task(id, complete?),
    do: %Task{id: id, text: "task #{id}", complete?: complete?, line: 1}

  defp make_task_phase(ordinal, task_count, complete? \\ false) do
    tasks = for n <- 1..task_count, do: make_task("T#{ordinal}0#{n}", complete?)

    %TaskPhase{
      ordinal: ordinal,
      number: to_string(ordinal),
      title: "Phase #{ordinal}",
      tasks: tasks
    }
  end

  defp make_plan(task_phases, structured? \\ true),
    do: %TaskPlan{task_phases: task_phases, structured?: structured?, source: nil}

  defp complete_task_phase(plan, ordinal) do
    task_phases =
      Enum.map(plan.task_phases, fn
        %{ordinal: ^ordinal} = tp -> %{tp | tasks: Enum.map(tp.tasks, &%{&1 | complete?: true})}
        tp -> tp
      end)

    %{plan | task_phases: task_phases}
  end

  defp five_phase_plan, do: make_plan(for(n <- 1..5, do: make_task_phase(n, 1)))

  # ---- test driver ------------------------------------------------------------
  #
  # Repeatedly calls Chunking.next/2, using `react_fun.(scope, state)` to decide
  # the signals to fold for each dispatched scope, until a terminal decision
  # ({:done,_} / {:halted,_,_} / {:failed,_,_}) is reached. Returns
  # {terminal_decision, dispatched_scopes_in_order}.

  defp run(state, react_fun, signals \\ %{}, scopes \\ []) do
    case Chunking.next(state, signals) do
      {:dispatch, scope, state1} ->
        run(state1, react_fun, react_fun.(scope, state1), [scope | scopes])

      {:skip, _tp, state1} ->
        run(state1, react_fun, %{}, scopes)

      terminal ->
        {terminal, Enum.reverse(scopes)}
    end
  end

  defp succeed_fun(scope, state) do
    case scope do
      {:task_phase, tp} -> %{outcome: :ok, plan: complete_task_phase(state.plan, tp.ordinal)}
      {:sweep, tasks} -> %{outcome: :ok, plan: complete_ids(state.plan, Enum.map(tasks, & &1.id))}
      :whole_list -> %{outcome: :ok, plan: state.plan}
    end
  end

  defp complete_ids(plan, ids) do
    task_phases =
      Enum.map(plan.task_phases, fn tp ->
        %{
          tp
          | tasks: Enum.map(tp.tasks, &if(&1.id in ids, do: %{&1 | complete?: true}, else: &1))
        }
      end)

    %{plan | task_phases: task_phases}
  end

  # ---- start/2: frozen ceiling -----------------------------------------------

  describe "start/2" do
    test "freezes ceiling = per_task_phase * task_phase_count + headroom" do
      state = Chunking.start(five_phase_plan())
      assert state.ceiling == 2 * 5 + 4
      assert state.cursor == 1
      assert state.sessions_used == 0
    end

    test "uses max(task_phase_count, 1) for an unstructured (zero-task-phase) plan" do
      state = Chunking.start(make_plan([], false))
      assert state.ceiling == 2 * 1 + 4
    end

    test "accepts :from_ordinal and :sessions_used for resume" do
      state = Chunking.start(five_phase_plan(), from_ordinal: 3, sessions_used: 7)
      assert state.cursor == 3
      assert state.sessions_used == 7
    end
  end

  # ---- rows 1/2 — session errors ----------------------------------------------

  describe "row 1 — transient error retries the same scope" do
    test "redispatches the same task-phase, no no_progress change" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})

      assert {:dispatch, {:task_phase, ^tp1}, state2} =
               Chunking.next(state1, %{outcome: :error, transient?: true})

      assert state2.attempt == 2
      assert state2.sessions_used == 2
      assert state2.no_progress == 0
    end
  end

  describe "row 2 — a non-transient error fails the feature" do
    test "carries the error reason" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, _scope, state1} = Chunking.next(state, %{})

      assert Chunking.next(state1, %{outcome: :error, transient?: false, error: "boom"}) ==
               {:failed, {:session_error, "boom"}, state1}
    end
  end

  # ---- rows 3-5 — exhaustion ----------------------------------------------------

  describe "rows 3/5 — exhaustion continuation" do
    test "progress resets no_progress and continues" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})
      state1 = %{state1 | no_progress: 1}

      assert {:dispatch, {:task_phase, ^tp1}, state2} =
               Chunking.next(state1, %{outcome: :exhausted, progress?: true})

      assert state2.no_progress == 0
      assert state2.attempt == 2
    end

    test "no progress increments no_progress but a single attempt never fails" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})

      assert {:dispatch, {:task_phase, ^tp1}, state2} =
               Chunking.next(state1, %{outcome: :exhausted, progress?: false})

      assert state2.no_progress == 1
    end

    test "reaching the no-progress limit fails as stuck_task_phase" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})

      {:dispatch, {:task_phase, ^tp1}, state2} =
        Chunking.next(state1, %{outcome: :exhausted, progress?: false})

      assert {:failed, {:stuck_task_phase, ref, 2}, _state3} =
               Chunking.next(state2, %{outcome: :exhausted, progress?: false})

      assert ref == %TaskPhaseRef{ordinal: 1, number: "1", title: "Phase 1"}
    end

    test "alternating progress/no-progress never reaches the no-progress bound" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})

      final =
        Enum.reduce(1..10, state1, fn i, acc ->
          progress? = rem(i, 2) == 0

          {:dispatch, {:task_phase, ^tp1}, next_state} =
            Chunking.next(acc, %{outcome: :exhausted, progress?: progress?})

          next_state
        end)

      assert final.no_progress in [0, 1]
    end
  end

  # ---- row 6 — session ceiling -------------------------------------------------

  describe "row 6 — session ceiling" do
    test "a steadily progressing task-phase is not killed before the ceiling" do
      state = %ChunkState{Chunking.start(five_phase_plan()) | ceiling: 20}
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})

      final =
        Enum.reduce(1..10, state1, fn _i, acc ->
          {:dispatch, {:task_phase, ^tp1}, next_state} =
            Chunking.next(acc, %{outcome: :exhausted, progress?: true})

          next_state
        end)

      # initial dispatch (1) + 10 continuations = 11, comfortably under 20
      assert final.sessions_used == 11
    end

    test "ceiling reached mid-task-phase fails distinctly from stuck" do
      state = %ChunkState{Chunking.start(five_phase_plan()) | ceiling: 3}
      {:dispatch, {:task_phase, _tp1}, state1} = Chunking.next(state, %{})
      assert state1.sessions_used == 1

      {:dispatch, _scope, state2} = Chunking.next(state1, %{outcome: :exhausted, progress?: true})
      assert state2.sessions_used == 2

      {:dispatch, _scope, state3} = Chunking.next(state2, %{outcome: :exhausted, progress?: true})
      assert state3.sessions_used == 3

      # sessions_used is now == ceiling — the fold that would otherwise
      # continue must fail as :session_ceiling instead, distinct from a
      # no-progress {:stuck_task_phase, ...}.
      assert {:failed, {:session_ceiling, 3}, _state4} =
               Chunking.next(state3, %{outcome: :exhausted, progress?: true})
    end

    test "ceiling reached at a boundary (fresh dispatch decision) fails without continuing" do
      state = %ChunkState{Chunking.start(five_phase_plan()) | ceiling: 1}
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})
      assert state1.sessions_used == 1

      plan_after = complete_task_phase(five_phase_plan(), tp1.ordinal)

      assert {:failed, {:session_ceiling, 1}, _state2} =
               Chunking.next(state1, %{outcome: :ok, plan: plan_after})
    end
  end

  # ---- row 4 — stuck task-phase identity for non-task-phase scopes -------------

  describe "row 4 — stuck ref identity for sweep/fallback scopes" do
    test "no-progress during the sweep fails with a sweep TaskPhaseRef" do
      plan = make_plan([make_task_phase(1, 1, false)])
      state = Chunking.start(plan)

      {:dispatch, {:task_phase, _tp1}, s1} = Chunking.next(state, %{})

      {:dispatch, {:sweep, _tasks}, s2} = Chunking.next(s1, %{outcome: :ok, plan: plan})

      {:dispatch, {:sweep, _tasks}, s3} =
        Chunking.next(s2, %{outcome: :exhausted, progress?: false})

      assert {:failed, {:stuck_task_phase, ref, 2}, _s4} =
               Chunking.next(s3, %{outcome: :exhausted, progress?: false})

      assert ref == %TaskPhaseRef{ordinal: 2, number: "sweep", title: "final sweep"}
    end

    test "no-progress during the unstructured fallback fails with a whole_list TaskPhaseRef" do
      plan = make_plan([], false)
      state = Chunking.start(plan)

      {:dispatch, :whole_list, s1} = Chunking.next(state, %{})

      {:dispatch, :whole_list, s2} =
        Chunking.next(s1, %{outcome: :exhausted, progress?: false})

      assert {:failed, {:stuck_task_phase, ref, 2}, _s3} =
               Chunking.next(s2, %{outcome: :exhausted, progress?: false})

      assert ref == %TaskPhaseRef{ordinal: 1, number: nil, title: "tasks.md"}
    end
  end

  # ---- next/1 — default empty signals -------------------------------------------

  describe "next/1" do
    test "defaults signals to an empty map, identical to next/2 with %{}" do
      state = Chunking.start(five_phase_plan())

      assert Chunking.next(state) == Chunking.next(state, %{})
    end
  end

  # ---- row 13 — unchecked task without an id names by line/text ----------------

  describe "row 13 — unchecked task naming" do
    test "a task without an id is named by line and text" do
      task_no_id = %Task{id: nil, text: "some free text here", complete?: false, line: 42}
      tp = %TaskPhase{ordinal: 1, number: "1", title: "Phase 1", tasks: [task_no_id]}
      plan = make_plan([tp])
      state = Chunking.start(plan)

      {:dispatch, {:task_phase, _tp1}, s1} = Chunking.next(state, %{})
      {:dispatch, {:sweep, _tasks}, s2} = Chunking.next(s1, %{outcome: :ok, plan: plan})

      assert {:failed, {:unchecked_tasks, [name]}, _s3} =
               Chunking.next(s2, %{outcome: :ok, plan: plan})

      assert name == "line 42: some free text here"
    end
  end

  # ---- row 7 — breaker -----------------------------------------------------------

  describe "row 7 — breaker" do
    test "halts at a boundary (a scope's session just succeeded)" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})
      plan = complete_task_phase(state1.plan, tp1.ordinal)

      assert Chunking.next(state1, %{outcome: :ok, plan: plan, breaker?: true}) ==
               {:halted, :breaker, %{state1 | plan: plan, cursor: 2, attempt: 1, no_progress: 0}}
    end

    test "does not fire mid-scope (an exhaustion continuation ignores it)" do
      state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})

      assert {:dispatch, {:task_phase, ^tp1}, _state2} =
               Chunking.next(state1, %{outcome: :exhausted, progress?: true, breaker?: true})
    end
  end

  # ---- row 8 — unstructured fallback --------------------------------------------

  describe "row 8 — FR-004 unstructured fallback" do
    test "dispatches :whole_list once, then a second time on exhaustion+progress" do
      plan = make_plan([], false)
      state = Chunking.start(plan)

      assert {:dispatch, :whole_list, state1} = Chunking.next(state, %{})
      assert state1.sessions_used == 1

      assert {:dispatch, :whole_list, state2} =
               Chunking.next(state1, %{outcome: :exhausted, progress?: true})

      assert state2.sessions_used == 2
    end

    test "a successful whole_list session reaches :done" do
      plan = make_plan([], false)
      state = Chunking.start(plan)
      {:dispatch, :whole_list, state1} = Chunking.next(state, %{})

      assert {:done, _state2} = Chunking.next(state1, %{outcome: :ok, plan: plan})
    end
  end

  # ---- rows 9-11 — skip / dispatch / done ---------------------------------------

  describe "rows 9-11 — skip, dispatch, done" do
    test "5 task-phases complete in one attempt each ⇒ exactly 5 dispatches then :done" do
      state = Chunking.start(five_phase_plan())
      {terminal, scopes} = run(state, &succeed_fun/2)

      assert length(scopes) == 5
      assert Enum.map(scopes, fn {:task_phase, tp} -> tp.ordinal end) == [1, 2, 3, 4, 5]
      assert match?({:done, _}, terminal)
    end

    test "task-phases 1-2 pre-complete ⇒ 2 skips, dispatch starts at 3" do
      plan =
        make_plan([
          make_task_phase(1, 1, true),
          make_task_phase(2, 1, true),
          make_task_phase(3, 1, false)
        ])

      state = Chunking.start(plan)

      assert {:skip, tp1, state1} = Chunking.next(state, %{})
      assert tp1.ordinal == 1

      assert {:skip, tp2, state2} = Chunking.next(state1, %{})
      assert tp2.ordinal == 2

      assert {:dispatch, {:task_phase, tp3}, _state3} = Chunking.next(state2, %{})
      assert tp3.ordinal == 3
    end

    test "an out-of-scope completion (phase 5 finished by phase 3's session) is later skipped" do
      plan = make_plan(for(n <- 1..5, do: make_task_phase(n, 1)))
      state = Chunking.start(plan, from_ordinal: 3)

      {:dispatch, {:task_phase, tp3}, state1} = Chunking.next(state, %{})
      assert tp3.ordinal == 3

      # phase 3's session also completes phase 5's task, out of scope
      plan_after = plan |> complete_task_phase(3) |> complete_task_phase(5)

      assert {:dispatch, {:task_phase, tp4}, state2} =
               Chunking.next(state1, %{outcome: :ok, plan: plan_after})

      assert tp4.ordinal == 4

      plan_after2 = complete_task_phase(plan_after, 4)

      assert {:skip, tp5, _state3} = Chunking.next(state2, %{outcome: :ok, plan: plan_after2})
      assert tp5.ordinal == 5
    end
  end

  # ---- SC-002 — failure-reason vocabulary is exhaustive and each maps to a
  # distinct sentence -----------------------------------------------------------

  describe "failure_sentence/1 (SC-002)" do
    @tag :sc002
    test "each of the four reasons maps to a distinct, on-topic sentence" do
      ref = %TaskPhaseRef{ordinal: 3, number: "3", title: "Polish"}

      sentences = %{
        stuck_task_phase: Chunking.failure_sentence({:stuck_task_phase, ref, 2}),
        session_ceiling: Chunking.failure_sentence({:session_ceiling, 10}),
        unchecked_tasks: Chunking.failure_sentence({:unchecked_tasks, ["T007", "T012"]}),
        session_error: Chunking.failure_sentence({:session_error, "boom"})
      }

      assert sentences.stuck_task_phase ==
               ~s(task-phase 3 "Polish" made no progress in 2 consecutive sessions)

      assert sentences.session_ceiling ==
               "feature exhausted its implement session budget (10 sessions)"

      assert sentences.unchecked_tasks == "tasks still unchecked after the sweep: T007, T012"
      assert sentences.session_error == ~s(implement session failed: "boom")

      # exhaustive by construction: four reasons, four distinct sentences.
      assert sentences |> Map.values() |> Enum.uniq() |> length() == 4
    end

    @tag :sc002
    test "every terminal {:failed, reason} the decision table can produce has a sentence" do
      # Drive each of the four failure paths through next/2 itself (not just
      # by hand-building the reason tuple) so this stays honest to what the
      # decision table actually emits.
      stuck_state = Chunking.start(five_phase_plan())
      {:dispatch, {:task_phase, _tp1}, s1} = Chunking.next(stuck_state, %{})
      {:dispatch, _scope, s2} = Chunking.next(s1, %{outcome: :exhausted, progress?: false})

      assert {:failed, stuck_reason, _} =
               Chunking.next(s2, %{outcome: :exhausted, progress?: false})

      ceiling_state = %ChunkState{Chunking.start(five_phase_plan()) | ceiling: 1}
      {:dispatch, _scope, c1} = Chunking.next(ceiling_state, %{})

      assert {:failed, ceiling_reason, _} =
               Chunking.next(c1, %{outcome: :exhausted, progress?: true})

      sweep_plan = make_plan([make_task_phase(1, 1, false)])
      sweep_state = Chunking.start(sweep_plan)
      {:dispatch, {:task_phase, _tp}, sw1} = Chunking.next(sweep_state, %{})
      {:dispatch, {:sweep, _}, sw2} = Chunking.next(sw1, %{outcome: :ok, plan: sweep_plan})

      assert {:failed, unchecked_reason, _} =
               Chunking.next(sw2, %{outcome: :ok, plan: sweep_plan})

      error_state = Chunking.start(five_phase_plan())
      {:dispatch, _scope, e1} = Chunking.next(error_state, %{})

      assert {:failed, error_reason, _} =
               Chunking.next(e1, %{outcome: :error, transient?: false, error: "boom"})

      sentences =
        [stuck_reason, ceiling_reason, unchecked_reason, error_reason]
        |> Enum.map(&Chunking.failure_sentence/1)

      assert Enum.all?(sentences, &is_binary/1)
      assert sentences |> Enum.uniq() |> length() == 4
    end
  end

  # ---- rows 12-13 — sweep --------------------------------------------------------

  describe "rows 12-13 — sweep" do
    test "leftover tasks after every task-phase dispatched trigger one sweep" do
      # The one task-phase's own session returns :ok without checking off its
      # task — the leftover is picked up by the sweep, not by re-dispatching
      # the task-phase.
      plan = make_plan([make_task_phase(1, 1, false)])
      state = Chunking.start(plan)

      {:dispatch, {:task_phase, tp1}, state1} = Chunking.next(state, %{})
      assert tp1.ordinal == 1

      assert {:dispatch, {:sweep, tasks}, state2} =
               Chunking.next(state1, %{outcome: :ok, plan: plan})

      assert Enum.map(tasks, & &1.id) == ["T101"]
      assert state2.swept?

      assert {:done, _state3} =
               Chunking.next(state2, %{outcome: :ok, plan: complete_ids(plan, ["T101"])})
    end

    test "sweep exhaustion continues without ever dispatching a second sweep" do
      plan = make_plan([make_task_phase(1, 2, false)])
      state = Chunking.start(plan)

      {:dispatch, {:task_phase, _tp1}, state1} = Chunking.next(state, %{})

      assert {:dispatch, {:sweep, tasks}, state2} =
               Chunking.next(state1, %{outcome: :ok, plan: plan})

      assert length(tasks) == 2
      assert state2.swept?

      # sweep exhausts having completed one of the two
      plan_partial = complete_ids(plan, ["T101"])

      assert {:dispatch, {:sweep, remaining}, state3} =
               Chunking.next(state2, %{outcome: :exhausted, progress?: true, plan: plan_partial})

      assert Enum.map(remaining, & &1.id) == ["T102"]
      assert state3.swept?
    end

    test "unchecked tasks surviving the sweep fail the step by name" do
      plan = make_plan([make_task_phase(1, 2, false)])
      state = Chunking.start(plan)

      {:dispatch, {:task_phase, _tp1}, state1} = Chunking.next(state, %{})
      {:dispatch, {:sweep, _tasks}, state2} = Chunking.next(state1, %{outcome: :ok, plan: plan})

      # sweep completes only one of the two, then finishes (:ok)
      plan_partial = complete_ids(plan, ["T101"])

      assert Chunking.next(state2, %{outcome: :ok, plan: plan_partial}) ==
               {:failed, {:unchecked_tasks, ["T102"]}, %{state2 | plan: plan_partial}}
    end
  end
end
