defmodule SpeckitOrchestrator.Remediation do
  @moduledoc """
  Pure decision surface for the analyze auto-remediation loop (feature 017) —
  the loop's analogue of `Pipeline.next/3` and `Chunking.next/2`. No IO, no
  harness, no process state; every signal is extracted upstream by
  `AnalyzeRunner` and passed in as an argument (Principle I).

  See `specs/017-analyze-auto-remediation/contracts/remediation.md`.
  """

  alias SpeckitOrchestrator.{AnalyzeResult, Pipeline}
  alias SpeckitOrchestrator.Remediation.Settings

  @type state :: %{
          settings: Settings.t(),
          attempts_used: non_neg_integer(),
          analyze_runs: pos_integer(),
          last_result: AnalyzeResult.t() | nil,
          last_outcome: :ok | :error
        }

  @type signals :: %{
          optional(:outcome) => :ok | :error,
          optional(:result) => AnalyzeResult.t() | nil,
          optional(:step) => :analyze | :remediation,
          optional(:breaker?) => boolean()
        }

  @doc """
  Decide the transition out of the current analyze/remediation step. Rows are
  evaluated top-to-bottom; the first match wins (contracts/remediation.md §2):

    1. loop disabled → `{:gate, state}`
    2. the analyze step itself errored → `{:gate, state}` (a phase failure,
       never a loop entry)
    3. a remediation step errored → `{:failed, :remediation_failed, state}`
       (stop now, do not consume remaining attempts)
    4. the breaker tripped → `{:halted, :breaker, state}`
    5. no findings at or above the threshold → `{:gate, state}`
    6. the attempt limit is spent → `{:gate, {:exhausted, n}, state}`
    7. otherwise → `{:remediate, findings, state'}` with `attempts_used`
       incremented

  `state.last_result`/`last_outcome` are refreshed from `signals` (when
  present) before the table is evaluated, so the gate is always decided
  against the most recent analyze run (FR-005).
  """
  @spec next(state(), signals()) ::
          {:gate, state()}
          | {:gate, {:exhausted, pos_integer()}, state()}
          | {:remediate, [AnalyzeResult.finding()], state()}
          | {:halted, :breaker, state()}
          | {:failed, :remediation_failed, state()}
  def next(state, signals) do
    state
    |> refresh(signals)
    |> decide(signals)
  end

  defp refresh(state, signals) do
    %{
      state
      | last_result: Map.get(signals, :result, state.last_result),
        last_outcome: Map.get(signals, :outcome, state.last_outcome)
    }
  end

  defp decide(%{settings: %Settings{enabled?: false}} = state, _signals), do: {:gate, state}

  defp decide(state, %{outcome: :error, step: :analyze}), do: {:gate, state}

  defp decide(state, %{outcome: :error, step: :remediation}),
    do: {:failed, :remediation_failed, state}

  defp decide(state, %{breaker?: true}), do: {:halted, :breaker, state}

  defp decide(%{settings: %Settings{threshold: threshold}} = state, _signals) do
    findings = AnalyzeResult.findings_at_or_above(state.last_result, threshold)

    cond do
      findings == [] ->
        {:gate, state}

      state.attempts_used >= state.settings.attempt_limit ->
        {:gate, {:exhausted, state.attempts_used}, state}

      true ->
        {:remediate, findings, %{state | attempts_used: state.attempts_used + 1}}
    end
  end

  @doc """
  The corrective instruction's templated portion — deterministic, findings
  passed verbatim, below-threshold findings excluded. The prompt pack itself
  (`priv/prompts/analyze_remediation.md`) is read and prepended by the caller,
  not by this pure function (contracts/remediation.md §3).

  Options: `:attempt`, `:limit`, `:threshold` (all required).
  """
  @spec instruction([AnalyzeResult.finding()], keyword()) :: String.t()
  def instruction(findings, opts) do
    attempt = Keyword.fetch!(opts, :attempt)
    limit = Keyword.fetch!(opts, :limit)
    threshold = Keyword.fetch!(opts, :threshold)

    """
    Attempt #{attempt} of #{limit}. Severity threshold: #{threshold}.
    Findings to resolve (verbatim, as reported by analyze):

    #{Jason.encode!(findings, pretty: true)}
    """
  end

  @doc """
  Decorate an analyze-gate `transition` to name exhausted auto-remediation
  (contracts/remediation.md §4, research R11). Byte-identical when the loop
  never ran (`attempts_used == 0`, which also covers the disabled case) or the
  transition isn't one the gate produces on a persisting finding.
  """
  @spec terminal_reason(Pipeline.transition(), state()) :: Pipeline.transition()
  def terminal_reason({:halted, :critical_finding}, %{attempts_used: n}) when n > 0,
    do: {:halted, {:critical_finding, :auto_remediation_exhausted}}

  def terminal_reason({:escalated, :high_findings}, %{attempts_used: n}) when n > 0,
    do: {:escalated, {:high_findings, :auto_remediation_exhausted}}

  def terminal_reason(transition, _state), do: transition

  defmodule Settings do
    @moduledoc """
    The three operator-chosen knobs (enabled?/threshold/attempt_limit) plus
    the configuration-level model override, fixed for the run's lifetime
    (contracts/remediation.md §1).
    """

    alias SpeckitOrchestrator.{Config, Severity}

    defstruct enabled?: true, threshold: :high, attempt_limit: 2, model: nil

    @type t :: %__MODULE__{
            enabled?: boolean(),
            threshold: Severity.severity(),
            attempt_limit: 1..5,
            model: String.t()
          }

    @doc """
    The single validator (FR-011, FR-010e, research R13). Checked in order:
    `enabled?` (non-boolean raises — a programmer error, the console only
    ever passes a boolean), `threshold` (must `Severity.parse/1`),
    `attempt_limit` (must be an integer `1..5` — `0`, `6`, `"2"`, `2.0`, `nil`
    all reject; zero is not an off-switch, FR-004a), `model` (`nil` resolves
    to the analyze model; a non-nil value must be a known CLI alias,
    FR-009a). Never clamps, never substitutes a default for a bad value,
    never partially applies.
    """
    @spec validate(map() | keyword()) ::
            {:ok, t()}
            | {:error, {:invalid_threshold, term()}}
            | {:error, {:invalid_attempt_limit, term()}}
            | {:error, {:unknown_model, term()}}
    def validate(input) do
      enabled? = fetch(input, :enabled?, true)

      unless is_boolean(enabled?) do
        raise ArgumentError, "enabled? must be a boolean, got: #{inspect(enabled?)}"
      end

      with {:ok, threshold} <- validate_threshold(fetch(input, :threshold, :high)),
           {:ok, attempt_limit} <- validate_attempt_limit(fetch(input, :attempt_limit, 2)),
           {:ok, model} <- validate_model(fetch(input, :model, nil)) do
        {:ok,
         %__MODULE__{
           enabled?: enabled?,
           threshold: threshold,
           attempt_limit: attempt_limit,
           model: model
         }}
      end
    end

    @doc """
    Tolerant decode from a run's captured `RunContext` (struct, string-keyed
    manifest map, or bare `%{}`) — the same shape-tolerance
    `RunContext.stacked?/1` already has. An absent field falls back to that
    field's default; this is the **only** fallback — a present but invalid
    field still errors.
    """
    @spec from_context(SpeckitOrchestrator.RunContext.t() | map() | nil) ::
            {:ok, t()} | {:error, term()}
    def from_context(nil), do: validate(%{})

    def from_context(%SpeckitOrchestrator.RunContext{} = ctx) do
      validate(%{
        enabled?: default(ctx.auto_remediation, true),
        threshold: default(ctx.auto_remediation_threshold, :high),
        attempt_limit: default(ctx.auto_remediation_attempt_limit, 2),
        model: ctx.auto_remediation_model
      })
    end

    def from_context(%{} = map) do
      validate(%{
        enabled?: default(field(map, "auto_remediation", :auto_remediation), true),
        threshold:
          default(field(map, "auto_remediation_threshold", :auto_remediation_threshold), :high),
        attempt_limit:
          default(
            field(map, "auto_remediation_attempt_limit", :auto_remediation_attempt_limit),
            2
          ),
        model: field(map, "auto_remediation_model", :auto_remediation_model)
      })
    end

    defp fetch(input, key, default) when is_map(input), do: Map.get(input, key, default)
    defp fetch(input, key, default) when is_list(input), do: Keyword.get(input, key, default)

    defp field(map, string_key, atom_key) do
      cond do
        Map.has_key?(map, string_key) -> Map.get(map, string_key)
        Map.has_key?(map, atom_key) -> Map.get(map, atom_key)
        true -> nil
      end
    end

    defp default(nil, fallback), do: fallback
    defp default(value, _fallback), do: value

    defp validate_threshold(value) do
      case Severity.parse(value) do
        {:ok, severity} -> {:ok, severity}
        :error -> {:error, {:invalid_threshold, value}}
      end
    end

    defp validate_attempt_limit(value) when is_integer(value) and value in 1..5, do: {:ok, value}
    defp validate_attempt_limit(value), do: {:error, {:invalid_attempt_limit, value}}

    defp validate_model(model), do: Config.remediation_model(:analyze, model)
  end
end
