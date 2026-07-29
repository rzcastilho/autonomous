defmodule SpeckitOrchestrator.TaskPlanTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.TaskPlan
  alias SpeckitOrchestrator.TaskPlan.TaskPhase
  alias SpeckitOrchestrator.TaskPhaseRef

  @fixtures Path.expand("../fixtures/tasks", __DIR__)
  @repo_root Path.expand("../..", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # ---- T1: heading count -> structured?/1 ----------------------------------

  describe "T1 — structured?/1" do
    test "at least one task-phase heading yields structured?: true" do
      assert TaskPlan.parse(fixture("structured.md")).structured?
    end

    test "zero task-phase headings yields structured?: false" do
      refute TaskPlan.parse(fixture("unstructured.md")).structured?
      refute TaskPlan.parse(fixture("no_checkboxes.md")).structured?
    end
  end

  # ---- T2: file order, 1-based gapless ordinals ----------------------------

  describe "T2 — ordinals are file-order and gapless" do
    test "structured.md's 5 task-phases are ordinals 1..5 in file order" do
      plan = TaskPlan.parse(fixture("structured.md"))
      assert Enum.map(plan.task_phases, & &1.ordinal) == [1, 2, 3, 4, 5]
      assert Enum.map(plan.task_phases, & &1.number) == ~w(1 2 3 4 5)
    end

    test "duplicate declared numbers still get distinct, sequential ordinals" do
      plan = TaskPlan.parse(fixture("duplicate_numbers.md"))

      assert Enum.map(plan.task_phases, &{&1.ordinal, &1.number, &1.title}) == [
               {1, "1", "Setup"},
               {2, "3", "First Occurrence"},
               {3, "3", "Second Occurrence"}
             ]
    end
  end

  # ---- T3: empty task-phase retained, vacuously complete -------------------

  describe "T3 — task-phase with zero tasks" do
    test "is retained (ordinals stay stable) and is vacuously complete?" do
      plan = TaskPlan.parse(fixture("empty_task_phase.md"))
      assert Enum.map(plan.task_phases, & &1.ordinal) == [1, 2, 3]

      empty = Enum.find(plan.task_phases, &(&1.number == "2"))
      assert empty.tasks == []
      assert TaskPhase.complete?(empty)
    end
  end

  # ---- T4: checkboxes outside any task-phase are excluded -------------------

  describe "T4 — checkboxes outside any task-phase" do
    test "unstructured checkboxes count toward nothing (no task-phase exists)" do
      plan = TaskPlan.parse(fixture("unstructured.md"))
      assert TaskPlan.total_tasks(plan) == 0
    end

    test "a stray checkbox under a non-Phase ## heading is excluded" do
      plan = TaskPlan.parse(fixture("structured.md"))
      assert TaskPlan.total_tasks(plan) == 13

      refute Enum.any?(plan.task_phases, fn tp ->
               Enum.any?(tp.tasks, &(&1.text == "Not counted — outside any task-phase"))
             end)
    end
  end

  # ---- T5: fenced blocks are skipped ----------------------------------------

  describe "T5 — fenced code blocks" do
    test "checkbox-looking lines inside a fence are excluded from every count" do
      plan = TaskPlan.parse(fixture("fenced.md"))
      assert TaskPlan.total_tasks(plan) == 3
      refute Enum.any?(TaskPlan.incomplete(plan), &(&1.id in ["T999", "T998"]))
    end
  end

  # ---- T6: complete?/1 <=> incomplete/1 == [] -------------------------------

  describe "T6 — complete?/1" do
    test "false while any task is unchecked" do
      plan = TaskPlan.parse(fixture("structured.md"))
      refute TaskPlan.complete?(plan)
      assert TaskPlan.incomplete(plan) != []
    end

    test "true (vacuously) when there are no tasks at all" do
      plan = TaskPlan.parse(fixture("no_checkboxes.md"))
      assert TaskPlan.complete?(plan)
      assert TaskPlan.incomplete(plan) == []
    end
  end

  # ---- T7: incomplete/1 preserves file order --------------------------------

  describe "T7 — incomplete/1 file order" do
    test "unchecked tasks come back in file order across task-phases" do
      plan = TaskPlan.parse(fixture("structured.md"))
      ids = plan |> TaskPlan.incomplete() |> Enum.map(& &1.id)
      assert ids == ["T004", nil, "T005", "T006", "T007", "T008", "T009", "T010", "T011", "T012"]
    end
  end

  # ---- T8: locate/2 resolution order ----------------------------------------

  describe "T8 — locate/2" do
    setup do
      %{plan: TaskPlan.parse(fixture("structured.md"))}
    end

    test "resolves by number when unique", %{plan: plan} do
      assert {:ok, tp, :number} = TaskPlan.locate(plan, %TaskPhaseRef{number: "3"})
      assert tp.ordinal == 3
    end

    test "falls through to title when number does not resolve uniquely", %{plan: plan} do
      ref = %TaskPhaseRef{number: "does-not-exist", title: "Polish & Cross-Cutting Concerns"}
      assert {:ok, tp, :title} = TaskPlan.locate(plan, ref)
      assert tp.ordinal == 5
    end

    test "falls through to ordinal when neither number nor title resolve", %{plan: plan} do
      ref = %TaskPhaseRef{number: "nope", title: "nope", ordinal: 4}
      assert {:ok, tp, :ordinal} = TaskPlan.locate(plan, ref)
      assert tp.ordinal == 4
    end

    test "falls through to first-incomplete when nothing resolves", %{plan: plan} do
      ref = %TaskPhaseRef{number: "nope", title: "nope", ordinal: 999}
      assert {:ok, tp, :fallback} = TaskPlan.locate(plan, ref)
      assert tp.ordinal == 2
    end

    test "a non-unique match at number falls through rather than guessing" do
      plan = TaskPlan.parse(fixture("duplicate_numbers.md"))
      assert {:ok, tp, :fallback} = TaskPlan.locate(plan, %TaskPhaseRef{number: "3"})
      assert tp.ordinal == 2
    end

    test "no task-phases at all yields {:error, :unstructured}" do
      plan = TaskPlan.parse(fixture("unstructured.md"))
      assert TaskPlan.locate(plan, %TaskPhaseRef{ordinal: 1}) == {:error, :unstructured}
    end
  end

  # ---- T9: locate(plan, nil) on a structured plan ---------------------------

  describe "T9 — locate/2 with nil ref" do
    test "resolves to the first incomplete task-phase, tagged :fallback" do
      plan = TaskPlan.parse(fixture("structured.md"))
      assert {:ok, tp, :fallback} = TaskPlan.locate(plan, nil)
      assert tp.ordinal == 2
    end

    test "resolves to the first task-phase when the whole plan is already complete" do
      plan = TaskPlan.parse(fixture("empty_task_phase.md"))
      {:ok, only_incomplete} = TaskPlan.at(plan, 3)
      refute TaskPhase.complete?(only_incomplete)

      # sanity: a plan with an incomplete task-phase resolves to it, not phase 1
      assert {:ok, tp, :fallback} = TaskPlan.locate(plan, nil)
      assert tp.ordinal == 3
    end
  end

  # ---- T10: load/1 never raises ---------------------------------------------

  describe "T10 — load/1" do
    test "never raises on a nonexistent worktree path" do
      plan = TaskPlan.load("/nonexistent/path/nowhere")
      refute plan.structured?
      assert plan.task_phases == []
    end

    test "loads and parses a real tasks.md from a worktree-shaped path" do
      plan = TaskPlan.load(@repo_root)
      assert plan.structured?
    end
  end

  # ---- load/2: a stacked worktree holds every earlier feature's specs -------

  describe "load/2 — scoping to the feature being built" do
    # A stacked run's worktree branches from the previous feature's branch, so
    # `specs/` holds 001's finished list (every box checked) alongside 002's
    # fresh one. Alphabetical order puts 001 first.
    defp stacked_worktree(opts \\ []) do
      dir = Path.join(System.tmp_dir!(), "tp_wt_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(dir) end)

      File.mkdir_p!(Path.join(dir, "specs/001-core-ledger"))

      File.write!(
        Path.join(dir, "specs/001-core-ledger/tasks.md"),
        "# Tasks: Core\n\n## Phase 1: Setup\n\n- [x] T001 done already\n"
      )

      if own_dir = Keyword.get(opts, :own, "specs/002-categories") do
        File.mkdir_p!(Path.join(dir, own_dir))

        File.write!(
          Path.join(dir, "#{own_dir}/tasks.md"),
          "# Tasks: Categories\n\n## Phase 1: Setup\n\n- [ ] T001 not done yet\n"
        )
      end

      if recorded = Keyword.get(opts, :recorded) do
        File.mkdir_p!(Path.join(dir, ".specify"))

        File.write!(
          Path.join(dir, ".specify/feature.json"),
          JSON.encode!(%{feature_directory: recorded})
        )
      end

      dir
    end

    defp feat(id, slug), do: %{id: id, slug: slug}

    test "load/1 loads the wrong feature's finished list — the defect load/2 exists to fix" do
      plan = TaskPlan.load(stacked_worktree())

      assert plan.source =~ "001-core-ledger"
      # Every box checked, so the chunk loop would skip every task-phase and
      # dispatch nothing at all.
      assert TaskPlan.complete?(plan)
    end

    test "resolves specs/<id>-<slug>/tasks.md, not the first match alphabetically" do
      plan = TaskPlan.load(stacked_worktree(), feat("002", "categories"))

      assert plan.source =~ "002-categories"
      refute TaskPlan.complete?(plan)
      assert TaskPlan.total_tasks(plan) == 1
    end

    test "falls back to the spec dir the Spec Kit CLI recorded when the slug drifted" do
      worktree =
        stacked_worktree(own: "specs/002-categorise", recorded: "specs/002-categorise")

      plan = TaskPlan.load(worktree, feat("002", "categories"))

      assert plan.source =~ "002-categorise"
      refute TaskPlan.complete?(plan)
    end

    test "falls back to the id prefix when neither the slug nor a recorded dir matches" do
      worktree = stacked_worktree(own: "specs/002-something-else")

      plan = TaskPlan.load(worktree, feat("002", "categories"))

      assert plan.source =~ "002-something-else"
      refute TaskPlan.complete?(plan)
    end

    test "ignores a recorded dir that points outside the worktree" do
      worktree = stacked_worktree(own: nil, recorded: "../elsewhere")

      plan = TaskPlan.load(worktree, feat("002", "categories"))

      # No file of its own resolved, so the unstructured fallback — never the
      # escaped path, and never 001's list.
      refute plan.structured?
      assert plan.source == nil
    end

    test "takes the unstructured fallback rather than another feature's list when its own is absent" do
      plan = TaskPlan.load(stacked_worktree(own: nil), feat("002", "categories"))

      # Unstructured makes the chunk loop dispatch the whole list (FR-004), so
      # implement still runs. Inheriting 001's completed list runs nothing.
      refute plan.structured?
      assert plan.source == nil
    end

    test "a nil feature is the unscoped path, unchanged" do
      worktree = stacked_worktree()
      assert TaskPlan.load(worktree, nil) == TaskPlan.load(worktree)
    end
  end

  # ---- ref/1 round-trip ------------------------------------------------------

  test "ref/1 builds the TaskPhaseRef identity for locate/2 to resolve back" do
    plan = TaskPlan.parse(fixture("structured.md"))
    {:ok, tp} = TaskPlan.at(plan, 3)
    ref = TaskPlan.ref(tp)
    assert ref == %TaskPhaseRef{ordinal: 3, number: "3", title: tp.title}
    assert {:ok, ^tp, :number} = TaskPlan.locate(plan, ref)
  end

  # ---- Golden parse: this repo's own tasks.md --------------------------------

  describe "golden parse — specs/014-recovery-reconciliation/tasks.md" do
    setup do
      path = Path.join(@repo_root, "specs/014-recovery-reconciliation/tasks.md")
      %{plan: TaskPlan.parse(File.read!(path), source: path)}
    end

    test "yields exactly the 7 task-phases documented in contracts/task_plan.md §4", %{plan: plan} do
      assert Enum.map(plan.task_phases, &{&1.ordinal, &1.number}) == [
               {1, "1"},
               {2, "2"},
               {3, "3"},
               {4, "4"},
               {5, "5"},
               {6, "6"},
               {7, "7"}
             ]

      titles = Enum.map(plan.task_phases, & &1.title)
      assert Enum.at(titles, 0) == "Setup"
      assert Enum.at(titles, 1) == "Foundational (Blocking Prerequisites)"
      assert Enum.at(titles, 6) == "Polish & Cross-Cutting Concerns"
    end

    test "non-task-phase ## headings (Dependencies, Notes, ...) are not task-phases", %{
      plan: plan
    } do
      refute Enum.any?(plan.task_phases, &String.contains?(&1.title, "Dependencies"))
      refute Enum.any?(plan.task_phases, &(&1.title == "Notes"))
      refute Enum.any?(plan.task_phases, &String.contains?(&1.title, "Implementation Strategy"))
    end

    test "a fenced-block line (Parallel Example) is not parsed as a task", %{plan: plan} do
      refute plan.task_phases
             |> Enum.flat_map(& &1.tasks)
             |> Enum.any?(&String.contains?(&1.text, "first (struct shape)"))
    end
  end
end
