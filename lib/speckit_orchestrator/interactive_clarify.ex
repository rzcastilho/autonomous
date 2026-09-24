defmodule SpeckitOrchestrator.InteractiveClarify do
  @moduledoc """
  Pure decision surface for interactive clarify answering (feature 029) —
  the mode's analogue of `Remediation.next/2`. No IO, no Mnesia, no receive
  loop: `FeatureRunner` owns the wait, the store row and the answered path
  (Principle I). See `specs/029-interactive-clarify/data-model.md` Decision
  table and `research.md` R2/R5.
  """

  alias SpeckitOrchestrator.InteractiveClarify.Settings
  alias SpeckitOrchestrator.Pipeline

  @doc """
  Decide what to do with a `Pipeline.next/3` transition.

    * anything other than `{:escalated, :needs_human}` → `:pass`
    * `{:escalated, :needs_human}`, mode off → `:pass` (today's escalation,
      FR-002 holds structurally)
    * `{:escalated, :needs_human}`, mode on, rounds left → `:await`
    * `{:escalated, :needs_human}`, mode on, rounds exhausted →
      `{:escalated, {:needs_human, :rounds_exhausted}}`
  """
  @spec decide(Pipeline.transition(), Settings.t(), non_neg_integer()) ::
          :pass | :await | {:escalated, {:needs_human, :rounds_exhausted}}
  def decide(transition, settings, rounds_used)

  def decide({:escalated, :needs_human}, %Settings{enabled?: true} = settings, rounds_used) do
    if rounds_used < settings.max_rounds do
      :await
    else
      {:escalated, {:needs_human, :rounds_exhausted}}
    end
  end

  def decide(_transition, _settings, _rounds_used), do: :pass

  @doc """
  Map a wait exit to its escalation reason (data-model.md, research.md R5).
  """
  @spec on_exit(:answer_timeout | :breaker | :drained | :restart) ::
          {:needs_human, :answer_timeout | :breaker | :drained | :restart}
  def on_exit(:answer_timeout), do: {:needs_human, :answer_timeout}
  def on_exit(:breaker), do: {:needs_human, :breaker}
  def on_exit(:drained), do: {:needs_human, :drained}
  def on_exit(:restart), do: {:needs_human, :restart}

  defmodule Settings do
    @moduledoc """
    The three operator-chosen knobs (data-model.md), mirroring
    `Remediation.Settings` — validate/from_context, never clamps.
    """

    alias SpeckitOrchestrator.Config

    defstruct enabled?: false,
              answer_timeout_s: 1_800,
              max_rounds: 3

    @type t :: %__MODULE__{
            enabled?: boolean(),
            answer_timeout_s: pos_integer(),
            max_rounds: pos_integer()
          }

    @doc """
    The single validator. `enabled?` (non-boolean raises `ArgumentError`),
    `answer_timeout_s` (integer `60..86_400`, else `{:invalid_answer_timeout,
    v}`), `max_rounds` (integer `1..5`, else `{:invalid_max_rounds, v}`).
    Never clamps, never substitutes a default for a bad value.
    """
    @spec validate(map() | keyword()) ::
            {:ok, t()}
            | {:error, {:invalid_answer_timeout, term()}}
            | {:error, {:invalid_max_rounds, term()}}
    def validate(input) do
      enabled? = fetch(input, :enabled?, false)

      unless is_boolean(enabled?) do
        raise ArgumentError, "enabled? must be a boolean, got: #{inspect(enabled?)}"
      end

      with {:ok, answer_timeout_s} <-
             validate_answer_timeout(fetch(input, :answer_timeout_s, 1_800)),
           {:ok, max_rounds} <- validate_max_rounds(fetch(input, :max_rounds, 3)) do
        {:ok,
         %__MODULE__{
           enabled?: enabled?,
           answer_timeout_s: answer_timeout_s,
           max_rounds: max_rounds
         }}
      end
    end

    @doc """
    Tolerant decode from a run's captured `RunContext` (struct, string/atom-keyed
    manifest map, or `nil`). An absent field falls back to that field's Config
    default; a present but invalid field still errors.
    """
    @spec from_context(SpeckitOrchestrator.RunContext.t() | map() | nil) ::
            {:ok, t()} | {:error, term()}
    def from_context(nil), do: validate(%{})

    def from_context(%SpeckitOrchestrator.RunContext{} = ctx) do
      validate(%{
        enabled?: default(ctx.interactive_clarify, Config.interactive_clarify?()),
        answer_timeout_s:
          default(ctx.clarify_answer_timeout_s, Config.clarify_answer_timeout_s()),
        max_rounds: default(ctx.clarify_max_rounds, Config.clarify_max_rounds())
      })
    end

    def from_context(%{} = map) do
      validate(%{
        enabled?:
          default(field(map, "interactive_clarify", :interactive_clarify), Config.interactive_clarify?()),
        answer_timeout_s:
          default(
            field(map, "clarify_answer_timeout_s", :clarify_answer_timeout_s),
            Config.clarify_answer_timeout_s()
          ),
        max_rounds:
          default(
            field(map, "clarify_max_rounds", :clarify_max_rounds),
            Config.clarify_max_rounds()
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

    defp validate_answer_timeout(value) when is_integer(value) and value in 60..86_400,
      do: {:ok, value}

    defp validate_answer_timeout(value), do: {:error, {:invalid_answer_timeout, value}}

    defp validate_max_rounds(value) when is_integer(value) and value in 1..5, do: {:ok, value}
    defp validate_max_rounds(value), do: {:error, {:invalid_max_rounds, value}}
  end

  defmodule AnswerSet do
    @moduledoc """
    Normalized answers for one round (data-model.md, research.md R7/R9).
    """

    alias SpeckitOrchestrator.NeedsHuman.Question

    defstruct answers: %{}

    @type answer :: {:typed, String.t()} | {:default, String.t()}
    @type t :: %__MODULE__{answers: %{String.t() => answer()}}

    @doc """
    Build an `AnswerSet` from the round's stored parse and the raw submitted
    params.

    Numbered: a blank answer with a recommended default takes the default,
    recorded as `{:default, text}`; a blank answer with no default returns
    `{:error, {:missing_answer, qid}}`.

    Freeform: a blank submission returns `{:error, :empty_answer}`.
    """
    @spec build({:numbered, [Question.t()]} | {:freeform, String.t()}, map()) ::
            {:ok, t()} | {:error, {:missing_answer, String.t()} | :empty_answer}
    def build({:numbered, questions}, raw) do
      Enum.reduce_while(questions, {:ok, %{}}, fn %Question{} = q, {:ok, acc} ->
        raw_value = raw |> Map.get(q.id) |> to_string_or_nil()

        cond do
          raw_value != nil and String.trim(raw_value) != "" ->
            {:cont, {:ok, Map.put(acc, q.id, {:typed, String.trim(raw_value)})}}

          q.recommended != nil ->
            {:cont, {:ok, Map.put(acc, q.id, {:default, q.recommended})}}

          true ->
            {:halt, {:error, {:missing_answer, q.id}}}
        end
      end)
      |> case do
        {:ok, answers} -> {:ok, %__MODULE__{answers: answers}}
        {:error, _} = error -> error
      end
    end

    def build({:freeform, _block}, raw) do
      raw_value = raw |> Map.get("*") |> to_string_or_nil()

      if raw_value != nil and String.trim(raw_value) != "" do
        {:ok, %__MODULE__{answers: %{"*" => {:typed, String.trim(raw_value)}}}}
      else
        {:error, :empty_answer}
      end
    end

    defp to_string_or_nil(nil), do: nil
    defp to_string_or_nil(value) when is_binary(value), do: value
    defp to_string_or_nil(value), do: to_string(value)

    @doc """
    Render the "Operator answers" prompt block folded into the clarify re-run
    (contracts/needs-human-format.md Answer-folding instruction, research.md R7).
    """
    @spec render(t(), pos_integer()) :: String.t()
    def render(%__MODULE__{answers: answers}, round) when map_size(answers) > 0 do
      lines = answers |> Enum.sort_by(fn {qid, _} -> qid end) |> Enum.map(&answer_line/1)

      """
      ---
      Operator answers (authoritative, round #{round}):
      #{Enum.join(lines, "\n")}
      These answers come from the human operator and override any default you would pick.
      Fold every answer into `## Clarifications` as a resolved decision, realign stale
      requirement text to match, and remove each answered item from `## NEEDS HUMAN`.
      Delete the `## NEEDS HUMAN` heading entirely when no unanswered material question
      remains. Do not re-ask an answered question.
      """
    end

    defp answer_line({"*", {:typed, text}}), do: text

    defp answer_line({qid, {:typed, text}}), do: "#{qid}: #{text}"

    defp answer_line({qid, {:default, text}}),
      do: "#{qid} (accepted recommended): #{text}"
  end
end
