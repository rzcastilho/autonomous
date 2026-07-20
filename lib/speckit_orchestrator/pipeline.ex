defmodule SpeckitOrchestrator.Pipeline do
  @moduledoc """
  Pure phase transition table for a single feature.

  Ordered phases:

      specify → clarify → plan → tasks → analyze → implement → converge → done

  `next/3` is the whole decision surface — it advances a feature one phase, or
  diverts it to a terminal outcome via one of these gates:

  * **clarify gate** — the Opus reviewer wrote `## NEEDS HUMAN` into the spec.
    `signals.needs_human? == true` at the `:clarify` phase → `:escalated`.
  * **analyze gate** — the deterministic analyze pass found a Critical finding.
    `signals.critical? == true` at the `:analyze` phase → `:halted`; a High
    finding (`signals.high? == true`) → `:escalated`.
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
  def next(:analyze, :ok, %{critical?: true}), do: {:halted, :critical_finding}
  def next(:analyze, :ok, %{high?: true}), do: {:escalated, :high_findings}
  def next(:converge, :ok, %{not_ready?: true}), do: {:failed, :converge_not_ready}

  def next(phase, :ok, _signals) when phase in @ordered do
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
