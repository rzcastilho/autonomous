defmodule SpeckitOrchestrator.Pipeline do
  @moduledoc """
  Pure phase transition table for a single feature.

  Ordered phases:

      specify → clarify → plan → tasks → analyze → implement → converge → done

  `next/3` is the whole decision surface — it advances a feature one phase, or
  diverts it to a terminal outcome via one of these gates:

  * **clarify gate** — the Opus reviewer wrote `## NEEDS HUMAN` into the spec.
    `signals.needs_human? == true` at the `:clarify` phase → `:escalated`.
  * **analyze gate** — the deterministic analyze pass found a finding at or
    above the run's severity threshold (`signals.gate_threshold`, default
    `:high`). A Critical finding (`signals.critical? == true`) → `:halted`;
    a High one (`signals.high? == true`) → `:escalated`. The threshold is an
    inclusive floor over `Severity`'s ordering, so raising it to `:critical`
    lets a High finding advance instead of diverting, and lowering it below
    `:high` creates no new terminal state (Low and Medium have none). Critical
    outranks every threshold and therefore always halts.
  * **artifact gate** — a phase returned a successful transcript but wrote none
    of the files it exists to produce. `signals.missing_artifact` at `:plan`,
    `:tasks`, or `:implement` → `:failed`.
  * **converge gate** — converge itself reported the branch is not ready for
    human review. `signals.not_ready? == true` at `:converge` → `:failed`.

  The artifact and converge gates close a **false-green** class found in a live
  run: a phase can refuse, ask an unanswerable question, or no-op because an
  earlier artifact is missing, and still return a perfectly successful
  transcript. Every downstream phase then reports the problem in prose while the
  pipeline marches to `:done` and opens a PR for an unbuilt feature. Only a
  deterministic "did the file actually appear?" check catches this regardless of
  *why* the phase produced nothing.

  Gate signals are extracted upstream (in `RunPhase`) from the phase output and
  passed in; this module stays pure and side-effect free.
  """

  alias SpeckitOrchestrator.Severity

  @ordered [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge]

  @typedoc "A pipeline phase. `:done` is the terminal marker, not in the run order."
  @type phase :: :specify | :clarify | :plan | :tasks | :analyze | :implement | :converge | :done

  @typedoc "Whether the phase itself succeeded or errored."
  @type outcome :: :ok | :error

  @typedoc "Gate signals extracted from the phase result by the caller."
  @type signals :: %{
          optional(:needs_human?) => boolean(),
          optional(:critical?) => boolean(),
          optional(:high?) => boolean(),
          optional(:gate_threshold) => Severity.severity(),
          optional(:not_ready?) => boolean(),
          optional(:missing_artifact) => String.t()
        }

  @typedoc "Result of a transition."
  @type transition ::
          {:cont, phase()}
          | {:done, :done}
          | {:escalated, term()}
          | {:halted, term()}
          | {:failed, term()}

  @doc "The ordered run phases (excludes the `:done` terminal marker)."
  @spec phases() :: [phase()]
  def phases, do: @ordered

  @doc "The first phase of the pipeline."
  @spec first() :: phase()
  def first, do: hd(@ordered)

  @doc "Whether `phase` is a member of the ordered run phases."
  @spec phase?(atom()) :: boolean()
  def phase?(phase), do: phase in @ordered

  @doc """
  Safely parse a phase name string (e.g. from a checkpoint/manifest file) into
  its atom — never `String.to_atom/1` on file-sourced content (atom-table
  safety). `:error` for anything not naming a real ordered phase, including a
  garbled or unrecognized value.
  """
  @spec parse(String.t()) :: {:ok, phase()} | :error
  def parse(phase) when is_binary(phase) do
    atom = String.to_existing_atom(phase)
    if phase?(atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  def parse(_phase), do: :error

  @doc "The 1-indexed step number of `phase` in the run order."
  @spec step_of(phase()) :: pos_integer()
  def step_of(phase), do: Enum.find_index(@ordered, &(&1 == phase)) + 1

  @doc """
  Decide the transition out of `phase` given the phase `outcome` and gate
  `signals`.

  Precedence: an errored phase always fails; otherwise the phase-specific gate
  is checked; otherwise the feature advances (and advancing past `:converge`
  reaches `:done`).
  """
  @spec next(phase(), outcome(), signals()) :: transition()
  def next(phase, outcome, signals \\ %{})

  def next(phase, :error, _signals) when phase in @ordered do
    {:failed, {phase, :error}}
  end

  # Artifact gate — checked before the phase-specific gates: a phase that wrote
  # nothing has no meaningful output to gate on.
  def next(phase, :ok, %{missing_artifact: artifact}) when phase in @ordered do
    {:failed, {:missing_artifact, phase, artifact}}
  end

  def next(:clarify, :ok, %{needs_human?: true}), do: {:escalated, :needs_human}

  # Critical outranks every threshold, so this needs no threshold check.
  def next(:analyze, :ok, %{critical?: true}), do: {:halted, :critical_finding}

  def next(:analyze, :ok, %{high?: true} = signals) do
    if Severity.at_or_above?(:high, gate_threshold(signals)) do
      {:escalated, :high_findings}
    else
      advance_transition(:analyze)
    end
  end

  def next(:converge, :ok, %{not_ready?: true}), do: {:failed, :converge_not_ready}

  def next(phase, :ok, _signals) when phase in @ordered do
    advance_transition(phase)
  end

  # The run's severity threshold, as an inclusive floor. Absent means `:high`,
  # the default — which reproduces the pre-threshold gate exactly.
  defp gate_threshold(signals), do: Map.get(signals, :gate_threshold) || :high

  @spec advance_transition(phase()) :: transition()
  defp advance_transition(phase) do
    case advance(phase) do
      :done -> {:done, :done}
      next_phase -> {:cont, next_phase}
    end
  end

  @spec advance(phase()) :: phase()
  defp advance(phase) do
    case Enum.drop_while(@ordered, &(&1 != phase)) do
      [^phase, next | _] -> next
      [^phase] -> :done
    end
  end
end
