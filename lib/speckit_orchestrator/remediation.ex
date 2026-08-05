defmodule SpeckitOrchestrator.Remediation do
  @moduledoc """
  Pure decision surface for the analyze auto-remediation loop (feature 017) —
  the loop's analogue of `Pipeline.next/3` and `Chunking.next/2`. No IO, no
  harness, no process state; every signal is extracted upstream by
  `AnalyzeRunner` and passed in as an argument (Principle I).

  See `specs/017-analyze-auto-remediation/contracts/remediation.md`.
  """

  alias SpeckitOrchestrator.{AnalyzeResult, Pipeline, Severity}
  alias SpeckitOrchestrator.Remediation.Settings

  @type state :: %{
          :settings => Settings.t(),
          :attempts_used => non_neg_integer(),
          :analyze_runs => pos_integer(),
          :last_result => AnalyzeResult.t() | nil,
          :last_outcome => :ok | :error,
          optional(:analyze_started_at) => DateTime.t() | nil
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

  @typedoc """
  The advanced-with-unresolved-findings record (feature 021,
  contracts/advanced-record.md §1) — produced exactly when `exhaustion_advance/2`
  marks a feature. `policy`/`threshold`/`max_severity` are strings, never
  atoms, so the record survives `Store.Export.encode/1` running with no
  database at all.
  """
  @type advance_record :: %{
          policy: String.t(),
          attempts_used: non_neg_integer(),
          attempt_limit: pos_integer(),
          threshold: String.t(),
          max_severity: String.t(),
          findings: [AnalyzeResult.finding()],
          advanced_at: DateTime.t()
        }

  @doc """
  `{:mark, record}` when the run's *proceed* policy advanced a feature past
  residual findings the gate would otherwise have escalated; `:none`
  otherwise (contracts/advanced-record.md §1.1).

  Marks only when ALL hold (FR-009):
    * the loop exhausted its attempts (`signals.exhausted?`),
    * the policy is `:proceed`,
    * the final analyze run reported a finding the gate WOULD otherwise have
      diverted — a Critical (`signals.critical?`, which no threshold lets
      through), or a High (`signals.high?`) with
      `Severity.at_or_above?(:high, threshold)`.

  Constitution 4.0.0 brought Critical under the same policy as High, so a
  Critical advance is marked by the same rule and recorded through the same
  `advanced_with_findings` record — `max_severity` then reads `critical`,
  which is what tells the PR reviewer a constitution violation was advanced
  past rather than a quality finding.

  `state` carries exactly what the caller already has at the analyze
  boundary: `:attempts_used`, `:attempt_limit`, `:findings` (the residual
  candidates, verbatim), and `:advanced_at` (the caller's timestamp — this
  function reads no clock, so it stays pure and the mark and the gate can
  never disagree).
  """
  @spec exhaustion_advance(Pipeline.signals(), map()) :: {:mark, advance_record()} | :none
  def exhaustion_advance(signals, state) do
    if advances?(signals) do
      {:mark, advance_record(signals, state)}
    else
      :none
    end
  end

  defp advances?(signals) do
    Map.get(signals, :exhausted?, false) and
      Map.get(signals, :exhaustion_policy) == :proceed and
      diverting_finding?(signals)
  end

  # Exactly the gate's own two divert conditions, in the same order
  # `Pipeline.next/3` evaluates them — Critical regardless of threshold, then
  # High at or above the threshold. Keeping them mirrored is what guarantees a
  # feature is marked if and only if the policy is what advanced it.
  defp diverting_finding?(signals) do
    Map.get(signals, :critical?, false) or
      (Map.get(signals, :high?, false) and Severity.at_or_above?(:high, gate_threshold(signals)))
  end

  defp gate_threshold(signals), do: Map.get(signals, :gate_threshold) || :high

  defp advance_record(signals, state) do
    findings = Map.get(state, :findings, [])
    max_severity = findings |> Enum.map(&Severity.parse_finding/1) |> Severity.max()

    %{
      policy: Atom.to_string(Map.fetch!(signals, :exhaustion_policy)),
      attempts_used: Map.fetch!(state, :attempts_used),
      attempt_limit: Map.fetch!(state, :attempt_limit),
      threshold: Atom.to_string(gate_threshold(signals)),
      max_severity: to_string(max_severity),
      findings: findings,
      advanced_at: Map.fetch!(state, :advanced_at)
    }
  end

  @doc """
  Markdown section naming the residual findings a feature advanced past
  (feature 021, contracts/advanced-record.md §5). Pure and total: `nil` ⇒
  `""`, so `SpeckitOrchestrator.pr_text/2` can append its output
  unconditionally without branching on whether the feature was marked.
  """
  @spec pr_note(advance_record() | nil) :: String.t()
  def pr_note(nil), do: ""

  def pr_note(%{} = record) do
    findings_md = Enum.map_join(record.findings, "\n", &finding_line/1)

    """


    ---

    ## Advanced with unresolved analyze findings

    This branch was built by `speckit_orchestrator` with
    `auto_remediation_exhaustion_policy: proceed`. Auto-remediation used #{record.attempts_used} of #{record.attempt_limit} attempts and did not clear the findings below; the analyze gate was permitted to advance instead of #{diverted_verb(record)}. **These findings are unresolved in this branch.**

    Severity threshold: `#{record.threshold}`#{critical_warning(record)}

    #{findings_md}
    """
  end

  # What the gate would have done had the policy been `:escalate`: a Critical
  # halts, everything else escalates. Named honestly, because "instead of
  # escalating to a human" would understate a Critical advance.
  defp diverted_verb(%{max_severity: "critical"}), do: "halting on a constitution Critical finding"
  defp diverted_verb(_record), do: "escalating to a human"

  # A Critical is a constitution violation, not a quality nit — the PR
  # reviewer is now the only gate left in front of it, so the note says so
  # rather than leaving it to be inferred from a severity label in a list.
  defp critical_warning(%{max_severity: "critical"}) do
    "\n\n> **A constitution Critical finding was advanced past.** " <>
      "No automated gate remains in front of it — this pull request is the last review."
  end

  defp critical_warning(_record), do: ""

  defp finding_line(finding) do
    severity = Map.get(finding, "severity", "unknown")
    text = Map.get(finding, "title") || Map.get(finding, "detail") || inspect(finding)
    "- **#{severity}** — #{text}"
  end

  defmodule Settings do
    @moduledoc """
    The three operator-chosen knobs (enabled?/threshold/attempt_limit) plus
    the configuration-level model override, fixed for the run's lifetime
    (contracts/remediation.md §1), and the exhaustion policy (feature 021,
    contracts/exhaustion-policy.md §1) — a fifth knob with the same lifetime,
    validation, and capture rules.
    """

    alias SpeckitOrchestrator.{Config, Severity}

    @type policy :: :escalate | :proceed

    defstruct enabled?: true,
              threshold: :high,
              attempt_limit: 2,
              model: nil,
              exhaustion_policy: :escalate

    @type t :: %__MODULE__{
            enabled?: boolean(),
            threshold: Severity.severity(),
            attempt_limit: 1..5,
            model: String.t(),
            exhaustion_policy: policy()
          }

    @doc """
    The single validator (FR-011, FR-010e, research R13). Checked in order:
    `enabled?` (non-boolean raises — a programmer error, the console only
    ever passes a boolean), `threshold` (must `Severity.parse/1`),
    `attempt_limit` (must be an integer `1..5` — `0`, `6`, `"2"`, `2.0`, `nil`
    all reject; zero is not an off-switch, FR-004a), `model` (`nil` resolves
    to the analyze model; a non-nil value must be a known CLI alias,
    FR-009a), `exhaustion_policy` (must be `:escalate`/`:proceed` or the
    matching string, feature 021 FR-010). Never clamps, never substitutes a
    default for a bad value, never partially applies.
    """
    @spec validate(map() | keyword()) ::
            {:ok, t()}
            | {:error, {:invalid_threshold, term()}}
            | {:error, {:invalid_attempt_limit, term()}}
            | {:error, {:unknown_model, term()}}
            | {:error, {:invalid_exhaustion_policy, term()}}
    def validate(input) do
      enabled? = fetch(input, :enabled?, true)

      unless is_boolean(enabled?) do
        raise ArgumentError, "enabled? must be a boolean, got: #{inspect(enabled?)}"
      end

      with {:ok, threshold} <- validate_threshold(fetch(input, :threshold, :high)),
           {:ok, attempt_limit} <- validate_attempt_limit(fetch(input, :attempt_limit, 2)),
           {:ok, model} <- validate_model(fetch(input, :model, nil)),
           {:ok, exhaustion_policy} <-
             validate_exhaustion_policy(fetch(input, :exhaustion_policy, :escalate)) do
        {:ok,
         %__MODULE__{
           enabled?: enabled?,
           threshold: threshold,
           attempt_limit: attempt_limit,
           model: model,
           exhaustion_policy: exhaustion_policy
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
        model: ctx.auto_remediation_model,
        exhaustion_policy: default(ctx.auto_remediation_exhaustion_policy, :escalate)
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
        model: field(map, "auto_remediation_model", :auto_remediation_model),
        exhaustion_policy:
          default(
            field(
              map,
              "auto_remediation_exhaustion_policy",
              :auto_remediation_exhaustion_policy
            ),
            :escalate
          )
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

    defp validate_exhaustion_policy(value) do
      case parse_policy(value) do
        {:ok, policy} -> {:ok, policy}
        :error -> {:error, {:invalid_exhaustion_policy, value}}
      end
    end

    @doc """
    Parse an exhaustion policy value (feature 021, contracts/exhaustion-policy.md
    §2.1). Atoms pass through; strings match case-insensitively; never calls
    `String.to_atom/1` on the input.
    """
    @spec parse_policy(term()) :: {:ok, policy()} | :error
    def parse_policy(value) when value in [:escalate, :proceed], do: {:ok, value}

    def parse_policy(value) when is_binary(value) do
      case String.downcase(value) do
        "escalate" -> {:ok, :escalate}
        "proceed" -> {:ok, :proceed}
        _ -> :error
      end
    end

    def parse_policy(_value), do: :error
  end
end
