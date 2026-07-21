defmodule SpeckitOrchestrator.RunContext do
  @moduledoc """
  The six run-shaping settings captured at `run/1` time and reapplied on
  `resume/2` (FR-006/007/008). Pure value object — no IO beyond reading
  `Config` in `capture/1`. Excludes secrets/credentials by construction
  (FR-011): only bool/number/string/list-of-string fields exist.

  See `specs/007-resume-self-sufficient/contracts/run_context.md`.
  """

  alias SpeckitOrchestrator.Config

  defstruct pr_workflow: nil,
            max_concurrency: nil,
            budget_usd: nil,
            plan_stack: nil,
            pr_base: nil,
            pr_remote: nil

  @type t :: %__MODULE__{
          pr_workflow: boolean() | nil,
          max_concurrency: pos_integer() | nil,
          budget_usd: number() | nil,
          plan_stack: [String.t()] | nil,
          pr_base: String.t() | nil,
          pr_remote: String.t() | nil
        }

  @keys [:pr_workflow, :max_concurrency, :budget_usd, :plan_stack, :pr_base, :pr_remote]

  @doc "Resolves each field from `opts`, falling back to live `Config` — the capture boundary."
  @spec capture(keyword()) :: t()
  def capture(opts) do
    %__MODULE__{
      pr_workflow: Keyword.get(opts, :pr_workflow, Config.pr_workflow?()),
      max_concurrency: Keyword.get(opts, :max_concurrency, Config.max_concurrency()),
      budget_usd: Keyword.get(opts, :budget_usd, Config.budget_usd()),
      plan_stack: Keyword.get(opts, :plan_stack, Config.plan_stack()),
      pr_base: Keyword.get(opts, :pr_base, Config.pr_base()),
      pr_remote: Keyword.get(opts, :pr_remote, Config.pr_remote())
    }
  end

  @doc "JSON-ready, string-keyed map of exactly the six settings, for the checkpoint."
  @spec to_map(t()) :: %{String.t() => term()}
  def to_map(%__MODULE__{} = ctx) do
    %{
      "pr_workflow" => ctx.pr_workflow,
      "max_concurrency" => ctx.max_concurrency,
      "budget_usd" => ctx.budget_usd,
      "plan_stack" => ctx.plan_stack,
      "pr_base" => ctx.pr_base,
      "pr_remote" => ctx.pr_remote
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
      pr_remote: Map.get(map, "pr_remote")
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
