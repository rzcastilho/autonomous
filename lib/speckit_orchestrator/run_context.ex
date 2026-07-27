defmodule SpeckitOrchestrator.RunContext do
  @moduledoc """
  The ten run-shaping settings captured at `run/1` time and reapplied on
  `resume/2` (FR-006/007/008). Pure value object — no IO beyond reading
  `Config` in `capture/1`. Excludes secrets/credentials by construction
  (FR-011): only bool/number/string/list-of-string fields exist.

  See `specs/007-resume-self-sufficient/contracts/run_context.md` and
  `specs/017-analyze-auto-remediation/contracts/checkpoint-analyze-remediation.md`.
  """

  alias SpeckitOrchestrator.Config

  defstruct pr_workflow: nil,
            max_concurrency: nil,
            budget_usd: nil,
            plan_stack: nil,
            pr_base: nil,
            pr_remote: nil,
            auto_remediation: nil,
            auto_remediation_threshold: nil,
            auto_remediation_attempt_limit: nil,
            auto_remediation_model: nil

  @type t :: %__MODULE__{
          pr_workflow: boolean() | nil,
          max_concurrency: pos_integer() | nil,
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
    :pr_workflow,
    :max_concurrency,
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
      pr_workflow: Keyword.get(opts, :pr_workflow, Config.pr_workflow?()),
      max_concurrency: Keyword.get(opts, :max_concurrency, Config.max_concurrency()),
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

  @doc """
  Whether the context describes a **stacked PR run** — the shape `run/1`
  routes through `run_stacked/3`, which pins the wave cap to 1 so each
  feature branches from the previous one's published branch.

  Tolerant by design: a run's context reaches consumers as this struct, as a
  string-keyed map decoded from the manifest, or as the bare `%{}` a test
  Coordinator starts with. Anything that does not positively say
  `pr_workflow: true` is not stacked.
  """
  @spec stacked?(t() | map() | nil) :: boolean()
  def stacked?(%__MODULE__{pr_workflow: pr_workflow}), do: pr_workflow == true
  def stacked?(%{"pr_workflow" => pr_workflow}), do: pr_workflow == true
  def stacked?(%{pr_workflow: pr_workflow}), do: pr_workflow == true
  def stacked?(_context), do: false

  @doc """
  The wave cap a run of this shape actually releases at: `1` when stacked
  (each feature must branch from the previous one's published branch), the
  requested cap otherwise.

  One rule, one home — the console previews it before a run starts and
  `run/1` records it into the run's context once started, so the number an
  operator is shown up front is the number the run then reports.
  """
  @spec effective_max_concurrency(boolean() | nil, pos_integer() | nil) :: pos_integer() | nil
  def effective_max_concurrency(true, _requested), do: 1
  def effective_max_concurrency(_pr_workflow?, requested), do: requested

  @doc "JSON-ready, string-keyed map of exactly the ten settings, for the checkpoint."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = ctx) do
    %{
      "pr_workflow" => ctx.pr_workflow,
      "max_concurrency" => ctx.max_concurrency,
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
      pr_workflow: Map.get(map, "pr_workflow"),
      max_concurrency: Map.get(map, "max_concurrency"),
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
