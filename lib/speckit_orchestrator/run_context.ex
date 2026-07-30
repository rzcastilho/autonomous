defmodule SpeckitOrchestrator.RunContext do
  @moduledoc """
  The eight run-shaping settings captured at `run/1` time and reapplied on
  `resume/2`. Pure value object — no IO beyond reading `Config` in
  `capture/1`. Excludes secrets/credentials by construction (FR-011): only
  bool/number/string/list-of-string fields exist.

  Every run is a stacked sequential run (FR-006, FR-007) — there is no run
  mode or concurrency setting to capture.

  See `specs/007-resume-self-sufficient/contracts/run_context.md` and
  `specs/017-analyze-auto-remediation/contracts/checkpoint-analyze-remediation.md`.
  """

  alias SpeckitOrchestrator.Config

  defstruct budget_usd: nil,
            plan_stack: nil,
            pr_base: nil,
            pr_remote: nil,
            auto_remediation: nil,
            auto_remediation_threshold: nil,
            auto_remediation_attempt_limit: nil,
            auto_remediation_model: nil

  @type t :: %__MODULE__{
          budget_usd: number() | nil,
          plan_stack: [String.t()] | nil,
          pr_base: String.t() | nil,
          pr_remote: String.t() | nil,
          auto_remediation: boolean() | nil,
          auto_remediation_threshold: String.t() | nil,
          auto_remediation_attempt_limit: pos_integer() | nil,
          auto_remediation_model: String.t() | nil
        }

  @keys [
    :budget_usd,
    :plan_stack,
    :pr_base,
    :pr_remote,
    :auto_remediation,
    :auto_remediation_threshold,
    :auto_remediation_attempt_limit,
    :auto_remediation_model
  ]

  @doc "Resolves each field from `opts`, falling back to live `Config` — the capture boundary."
  @spec capture(keyword()) :: t()
  def capture(opts) do
    %__MODULE__{
      budget_usd: Keyword.get(opts, :budget_usd, Config.budget_usd()),
      plan_stack: Keyword.get(opts, :plan_stack, Config.plan_stack()),
      pr_base: Keyword.get(opts, :pr_base, Config.pr_base()),
      pr_remote: Keyword.get(opts, :pr_remote, Config.pr_remote()),
      auto_remediation: Keyword.get(opts, :auto_remediation, Config.auto_remediation?()),
      auto_remediation_threshold:
        opts
        |> Keyword.get(:auto_remediation_threshold, Config.auto_remediation_threshold())
        |> stringify_threshold(),
      auto_remediation_attempt_limit:
        Keyword.get(
          opts,
          :auto_remediation_attempt_limit,
          Config.auto_remediation_attempt_limit()
        ),
      auto_remediation_model:
        Keyword.get(opts, :auto_remediation_model, Config.auto_remediation_model())
    }
  end

  # The threshold is stored as a string (JSON-encoded into the manifest and
  # checkpoints) — never an atom, since `String.to_atom/1` on file-sourced
  # content is banned repo-wide (research R4). Only ever atom -> string here,
  # never the reverse.
  defp stringify_threshold(nil), do: nil
  defp stringify_threshold(value) when is_binary(value), do: value
  defp stringify_threshold(value) when is_atom(value), do: Atom.to_string(value)

  @doc "JSON-ready, string-keyed map of exactly the eight settings, for the checkpoint."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = ctx) do
    %{
      "budget_usd" => ctx.budget_usd,
      "plan_stack" => ctx.plan_stack,
      "pr_base" => ctx.pr_base,
      "pr_remote" => ctx.pr_remote,
      "auto_remediation" => ctx.auto_remediation,
      "auto_remediation_threshold" => ctx.auto_remediation_threshold,
      "auto_remediation_attempt_limit" => ctx.auto_remediation_attempt_limit,
      "auto_remediation_model" => ctx.auto_remediation_model
    }
  end

  @doc "Tolerant decode: `nil`/`%{}` → all-nil struct; partial map → only present keys populated. Never raises."
  @spec from_map(map() | nil) :: t()
  def from_map(nil), do: %__MODULE__{}

  def from_map(map) when is_map(map) do
    %__MODULE__{
      budget_usd: Map.get(map, "budget_usd"),
      plan_stack: Map.get(map, "plan_stack"),
      pr_base: Map.get(map, "pr_base"),
      pr_remote: Map.get(map, "pr_remote"),
      auto_remediation: Map.get(map, "auto_remediation"),
      auto_remediation_threshold: Map.get(map, "auto_remediation_threshold"),
      auto_remediation_attempt_limit: Map.get(map, "auto_remediation_attempt_limit"),
      auto_remediation_model: Map.get(map, "auto_remediation_model")
    }
  end

  @doc """
  Precedence explicit `opts` > recorded > (absent — `run/1` falls to live
  Config). Returns `{merged_opts, fell_back_keys}`; never overrides a
  caller-supplied opt, never injects a `nil`, order-independent.
  """
  @spec merge(keyword(), t()) :: {keyword(), [atom()]}
  def merge(opts, %__MODULE__{} = recorded) do
    {merged, fell_back} =
      Enum.reduce(@keys, {opts, []}, fn key, {acc_opts, fell_back} ->
        cond do
          Keyword.has_key?(acc_opts, key) ->
            {acc_opts, fell_back}

          not is_nil(Map.get(recorded, key)) ->
            {Keyword.put(acc_opts, key, Map.get(recorded, key)), fell_back}

          true ->
            {acc_opts, [key | fell_back]}
        end
      end)

    {merged, Enum.reverse(fell_back)}
  end
end
