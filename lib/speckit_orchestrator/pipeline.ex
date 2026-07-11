defmodule SpeckitOrchestrator.Pipeline do
  @moduledoc """
  Pure phase transition table for a single feature.

  Ordered phases:

      specify → clarify → plan → tasks → analyze → implement → converge → done

  `next/3` is the whole decision surface — it advances a feature one phase, or
  diverts it to a terminal outcome via one of two gates:

  * **clarify gate** — the Opus reviewer wrote `## NEEDS HUMAN` into the spec.
    `signals.needs_human? == true` at the `:clarify` phase → `:escalated`.
  * **analyze gate** — the deterministic analyze pass found a Critical finding.
    `signals.critical? == true` at the `:analyze` phase → `:halted`.

  Gate signals are extracted upstream (in `RunPhase`) from the phase output and
  passed in; this module stays pure and side-effect free.
  """

  @ordered [:specify, :clarify, :plan, :tasks, :analyze, :implement, :converge]

  @typedoc "A pipeline phase. `:done` is the terminal marker, not in the run order."
  @type phase :: :specify | :clarify | :plan | :tasks | :analyze | :implement | :converge | :done

  @typedoc "Whether the phase itself succeeded or errored."
  @type outcome :: :ok | :error

  @typedoc "Gate signals extracted from the phase result by the caller."
  @type signals :: %{optional(:needs_human?) => boolean(), optional(:critical?) => boolean()}

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

  def next(:clarify, :ok, %{needs_human?: true}), do: {:escalated, :needs_human}
  def next(:analyze, :ok, %{critical?: true}), do: {:halted, :critical_finding}

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
