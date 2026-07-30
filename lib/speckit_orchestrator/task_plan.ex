defmodule SpeckitOrchestrator.TaskPhaseRef do
  @moduledoc """
  The durable, three-part identity of a task-phase (data-model.md §5):
  ordinal position, declared number, and title. Recorded in the checkpoint
  (FR-020a) and resolved back to a live task-phase by `TaskPlan.locate/2`,
  which falls through number → title → ordinal → first-incomplete rather than
  guessing on an ambiguous or stale match (Constitution II).
  """

  defstruct ordinal: nil, number: nil, title: nil

  @type t :: %__MODULE__{
          ordinal: pos_integer() | nil,
          number: String.t() | nil,
          title: String.t() | nil
        }
end

defmodule SpeckitOrchestrator.TaskPlan do
  @moduledoc """
  Parse a feature's `tasks.md` into an ordered, re-derivable plan of
  task-phases (`## Phase <n>: <title>` sections) and their checkbox tasks.

  Pure core (Constitution I): `parse/2` is markdown-in/struct-out with no CLI,
  harness, or Jido dependency. `load/2` is the single documented edge reader —
  it resolves the feature's own `tasks.md` through `SpecDir` and never raises;
  an absent, unreadable, or unstructured file degrades to the FR-004 fallback
  (`structured?: false, task_phases: []`), never an exception. Callers with a
  feature in hand must use `load/2`; `load/1` keeps the old unscoped glob and
  reads whichever `tasks.md` sorts first, which in a stacked worktree is an
  earlier feature's completed list.

  The plan is **derived, never authoritative** — callers re-parse before every
  dispatch decision (FR-006) rather than trusting a stale in-memory copy.

  See `specs/015-implement-phase-chunking/contracts/task_plan.md` for the full
  grammar and behavioural contract.
  """

  alias SpeckitOrchestrator.{SpecDir, TaskPhaseRef}

  defmodule Task do
    @moduledoc "One checkbox line belonging to an open task-phase."

    defstruct id: nil, text: "", complete?: false, line: 0

    @type t :: %__MODULE__{
            id: String.t() | nil,
            text: String.t(),
            complete?: boolean(),
            line: pos_integer()
          }
  end

  defmodule TaskPhase do
    @moduledoc "One numbered, titled `## Phase <n>: <title>` section."

    alias SpeckitOrchestrator.TaskPlan.Task

    defstruct ordinal: 0, number: "", title: "", tasks: []

    @type t :: %__MODULE__{
            ordinal: pos_integer(),
            number: String.t(),
            title: String.t(),
            tasks: [Task.t()]
          }

    @doc "True when every member task is complete — vacuously true when empty."
    @spec complete?(t()) :: boolean()
    def complete?(%__MODULE__{tasks: tasks}), do: Enum.all?(tasks, & &1.complete?)
  end

  defstruct task_phases: [], structured?: false, source: nil

  @type t :: %__MODULE__{
          task_phases: [TaskPhase.t()],
          structured?: boolean(),
          source: String.t() | nil
        }

  @phase_heading ~r/^##\s+Phase\s+(?<number>[^:\n]+?)\s*:\s*(?<title>.+?)\s*$/
  @other_heading ~r/^##\s+/
  @task_line ~r/^\s*-\s+\[(?<mark>[ xX])\]\s+(?<rest>.*)$/
  @task_id ~r/^(?<id>T\d+)\b/
  @fence_line ~r/^\s*```/

  @doc """
  Parse `tasks.md` markdown into a `TaskPlan`. Pure: no IO. `:source` sets the
  diagnostic `source` field only.
  """
  @spec parse(String.t(), keyword()) :: t()
  def parse(markdown, opts \\ []) when is_binary(markdown) do
    source = Keyword.get(opts, :source)

    {finished, current, _fence?} =
      markdown
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({[], nil, false}, &process_line/2)

    task_phases = finalize(finished, current)

    %__MODULE__{task_phases: task_phases, structured?: task_phases != [], source: source}
  end

  @doc """
  Load and parse the `tasks.md` under a worktree path. The single edge reader
  for this module — resolves the file, reads it, and delegates to `parse/2`.
  Never raises: an absent, unreadable, or empty file yields the FR-004
  fallback plan.

  **Pass the feature.** A stacked run's worktree branches from the previous
  feature's branch, so it contains every earlier feature's `specs/` directory
  too — and each of those has a `tasks.md` with every box checked off, because
  that feature finished. Globbing `specs/**/tasks.md` and taking the first
  match therefore loads *feature 001's completed list* for every feature after
  it: `complete?/1` is trivially true, the chunk loop skips every task-phase
  without dispatching a single session, and `:implement` fails the artifact
  gate as `{:missing_artifact, :implement, "implementation changes"}` — a
  wholly misleading reason for "I read the wrong file".

  `SpecDir.file/3` does the resolving (see its docs for the candidate order).
  If it finds nothing, a scoped call takes the **unstructured fallback** rather
  than any other feature's file. That is the safe direction: an unstructured
  plan makes the chunk loop dispatch the whole list (FR-004), so implement runs.
  Silently inheriting a completed list makes it run nothing.

  `load/1` keeps the old unscoped glob for callers with no feature in hand.
  """
  @spec load(String.t()) :: t()
  def load(worktree_path), do: read_and_parse(unscoped_path(worktree_path))

  @spec load(String.t(), map() | nil) :: t()
  def load(worktree_path, nil), do: load(worktree_path)

  def load(worktree_path, %{id: id} = feature) when is_binary(id) do
    read_and_parse(SpecDir.file(worktree_path, feature, "tasks.md"))
  end

  defp unscoped_path(worktree_path) do
    worktree_path
    |> Path.join("specs/**/tasks.md")
    |> Path.wildcard()
    |> List.first()
  rescue
    _ -> nil
  end

  @spec read_and_parse(String.t() | nil) :: t()
  defp read_and_parse(nil), do: fallback()

  defp read_and_parse(path) do
    case File.read(path) do
      {:ok, content} -> parse(content, source: path)
      {:error, _reason} -> fallback()
    end
  end

  @spec fallback() :: t()
  defp fallback, do: %__MODULE__{structured?: false, task_phases: [], source: nil}

  @doc "Total task count across every task-phase, whole-list (FR-011/012 progress signal)."
  @spec total_tasks(t()) :: non_neg_integer()
  def total_tasks(%__MODULE__{} = plan), do: plan |> all_tasks() |> length()

  @doc "Count of `[X]`/`[x]` tasks across the whole list."
  @spec completed_tasks(t()) :: non_neg_integer()
  def completed_tasks(%__MODULE__{} = plan), do: plan |> all_tasks() |> Enum.count(& &1.complete?)

  @doc "Every unchecked task, in file order across task-phases — the sweep scope (FR-007)."
  @spec incomplete(t()) :: [Task.t()]
  def incomplete(%__MODULE__{} = plan), do: plan |> all_tasks() |> Enum.reject(& &1.complete?)

  @doc "`incomplete/1 == []` — the FR-007a success test."
  @spec complete?(t()) :: boolean()
  def complete?(%__MODULE__{} = plan), do: incomplete(plan) == []

  @doc "Number of task-phases in the plan."
  @spec task_phase_count(t()) :: non_neg_integer()
  def task_phase_count(%__MODULE__{task_phases: task_phases}), do: length(task_phases)

  @doc "The task-phase at the given 1-based ordinal, if any."
  @spec at(t(), pos_integer()) :: {:ok, TaskPhase.t()} | :error
  def at(%__MODULE__{task_phases: task_phases}, ordinal) do
    case Enum.find(task_phases, &(&1.ordinal == ordinal)) do
      nil -> :error
      task_phase -> {:ok, task_phase}
    end
  end

  @doc "The first task-phase with at least one incomplete task — the FR-025 fallback target."
  @spec first_incomplete(t()) :: {:ok, TaskPhase.t()} | :error
  def first_incomplete(%__MODULE__{task_phases: task_phases}) do
    case Enum.find(task_phases, &(not TaskPhase.complete?(&1))) do
      nil -> :error
      task_phase -> {:ok, task_phase}
    end
  end

  @doc """
  Resolve a durable `TaskPhaseRef` (or `nil`) to a task-phase, in the fixed
  order number → title → ordinal → first-incomplete-fallback (data-model.md
  §5). A non-unique match at any step falls through to the next rather than
  guessing (Constitution II).
  """
  @spec locate(t(), TaskPhaseRef.t() | nil) ::
          {:ok, TaskPhase.t(), :number | :title | :ordinal | :fallback}
          | {:error, :unstructured}
  def locate(%__MODULE__{task_phases: []}, _ref), do: {:error, :unstructured}

  def locate(%__MODULE__{} = plan, nil), do: {:ok, fallback_task_phase(plan), :fallback}

  def locate(%__MODULE__{task_phases: task_phases} = plan, %TaskPhaseRef{} = ref) do
    with :none <- unique_match(task_phases, &(&1.number == ref.number), :number),
         :none <- unique_match(task_phases, &(&1.title == ref.title), :title),
         :none <- ordinal_match(plan, ref.ordinal) do
      {:ok, fallback_task_phase(plan), :fallback}
    end
  end

  @spec unique_match([TaskPhase.t()], (TaskPhase.t() -> boolean()), atom()) ::
          {:ok, TaskPhase.t(), atom()} | :none
  defp unique_match(task_phases, pred, match_kind) do
    case Enum.filter(task_phases, pred) do
      [task_phase] -> {:ok, task_phase, match_kind}
      _ -> :none
    end
  end

  @spec ordinal_match(t(), pos_integer() | nil) :: {:ok, TaskPhase.t(), :ordinal} | :none
  defp ordinal_match(_plan, nil), do: :none

  defp ordinal_match(plan, ordinal) do
    case at(plan, ordinal) do
      {:ok, task_phase} -> {:ok, task_phase, :ordinal}
      :error -> :none
    end
  end

  @spec fallback_task_phase(t()) :: TaskPhase.t()
  defp fallback_task_phase(plan) do
    case first_incomplete(plan) do
      {:ok, task_phase} -> task_phase
      :error -> List.first(plan.task_phases)
    end
  end

  @doc "Build the durable `TaskPhaseRef` identity for a task-phase (FR-020a)."
  @spec ref(TaskPhase.t()) :: TaskPhaseRef.t()
  def ref(%TaskPhase{ordinal: ordinal, number: number, title: title}),
    do: %TaskPhaseRef{ordinal: ordinal, number: number, title: title}

  @spec all_tasks(t()) :: [Task.t()]
  defp all_tasks(%__MODULE__{task_phases: task_phases}),
    do: Enum.flat_map(task_phases, & &1.tasks)

  # ---- parsing --------------------------------------------------------------

  @spec finalize([TaskPhase.t()], TaskPhase.t() | nil) :: [TaskPhase.t()]
  defp finalize(finished, current) do
    finished
    |> close(current)
    |> Enum.reverse()
    |> Enum.map(&%{&1 | tasks: Enum.reverse(&1.tasks)})
  end

  @spec close([TaskPhase.t()], TaskPhase.t() | nil) :: [TaskPhase.t()]
  defp close(finished, nil), do: finished
  defp close(finished, current), do: [current | finished]

  @spec process_line(
          {String.t(), pos_integer()},
          {[TaskPhase.t()], TaskPhase.t() | nil, boolean()}
        ) ::
          {[TaskPhase.t()], TaskPhase.t() | nil, boolean()}
  defp process_line({line, _lineno}, {finished, current, true}) do
    {finished, current, not fence_line?(line)}
  end

  defp process_line({line, lineno}, {finished, current, false}) do
    cond do
      fence_line?(line) ->
        {finished, current, true}

      captures = Regex.named_captures(@phase_heading, line) ->
        closed = close(finished, current)

        task_phase = %TaskPhase{
          ordinal: length(closed) + 1,
          number: String.trim(captures["number"]),
          title: String.trim(captures["title"]),
          tasks: []
        }

        {closed, task_phase, false}

      Regex.match?(@other_heading, line) ->
        {close(finished, current), nil, false}

      true ->
        {finished, append_task(current, line, lineno), false}
    end
  end

  @spec append_task(TaskPhase.t() | nil, String.t(), pos_integer()) :: TaskPhase.t() | nil
  defp append_task(nil, _line, _lineno), do: nil

  defp append_task(current, line, lineno) do
    case Regex.named_captures(@task_line, line) do
      nil -> current
      captures -> %{current | tasks: [build_task(captures, lineno) | current.tasks]}
    end
  end

  @spec fence_line?(String.t()) :: boolean()
  defp fence_line?(line), do: Regex.match?(@fence_line, line)

  @spec build_task(%{String.t() => String.t()}, pos_integer()) :: Task.t()
  defp build_task(%{"mark" => mark, "rest" => rest}, lineno) do
    %Task{
      id: task_id(rest),
      text: String.trim(rest),
      complete?: mark in ["x", "X"],
      line: lineno
    }
  end

  @spec task_id(String.t()) :: String.t() | nil
  defp task_id(rest) do
    case Regex.named_captures(@task_id, rest) do
      %{"id" => id} -> id
      nil -> nil
    end
  end
end
