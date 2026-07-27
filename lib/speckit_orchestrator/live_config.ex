defmodule SpeckitOrchestrator.LiveConfig do
  @moduledoc """
  Forward-only apply of a Config view edit to the **current live run**
  (`specs/008-control-plane/contracts/live_config.md`). Satisfies FR-029..FR-032
  and FR-037: every accepted edit retunes work not yet started — never
  retroactive, never persisted as a cross-run default.

  Validates all submitted fields before applying any of them (Fail Loud,
  Constitution II) — a single invalid field rejects the whole change with no
  setter call. On success, dispatches each field via the mechanism table:
  per-phase models and PR settings go to app env (`Config.model_for/1` and
  friends are read at call time); budget and max concurrency go through the
  additive `Ledger.set_budget/2` / `Coordinator.set_cap/2` setters, which touch
  no in-flight work (Constitution IV: drain, don't kill).
  """

  alias SpeckitOrchestrator.{Config, Coordinator, Ledger, RunContext}

  @app :speckit_orchestrator
  @valid_models ~w(opus sonnet)

  @type change :: %{
          optional(:models) => %{(atom() | String.t()) => String.t()},
          optional(:budget_usd) => number(),
          optional(:max_concurrency) => pos_integer(),
          optional(:pr_workflow) => boolean(),
          optional(:pr_base) => String.t(),
          optional(:pr_remote) => String.t()
        }

  @doc "Validate then apply every field in `changes`. All-or-nothing: any invalid field applies none."
  @spec apply(change()) :: {:ok, change()} | {:error, %{atom() => String.t()}}
  def apply(changes) when is_map(changes) do
    case validate(changes) do
      :ok ->
        Enum.each(changes, &dispatch/1)
        {:ok, changes}

      {:error, _errors} = error ->
        error
    end
  end

  # ---- validation (bounds, Fail Loud) --------------------------------------

  defp validate(changes) do
    errors =
      Enum.reduce(changes, %{}, fn {field, value}, acc ->
        case validate_field(field, value) do
          :ok -> acc
          {:error, message} -> Map.put(acc, field, message)
        end
      end)

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  defp validate_field(:budget_usd, v) when is_number(v) and v >= 0, do: :ok
  defp validate_field(:budget_usd, _v), do: {:error, "budget must be a non-negative number"}

  # A live stacked PR run pins the cap to 1 (`run_stacked/3`) — raising it
  # would race `StackTracker` and stack a PR on the wrong base. Rejected here,
  # at validation, so the all-or-nothing contract holds and the operator sees
  # a field error instead of a silently-dropped edit. `Coordinator.set_cap/2`
  # enforces the same rule independently, for any other caller.
  defp validate_field(:max_concurrency, v) when is_integer(v) and v > 1 do
    if stacked_run?() do
      {:error, "the live run is a stacked PR run — its cap is pinned to 1"}
    else
      :ok
    end
  end

  defp validate_field(:max_concurrency, v) when is_integer(v) and v >= 1, do: :ok

  defp validate_field(:max_concurrency, _v),
    do: {:error, "max concurrency must be a positive integer"}

  defp validate_field(:models, models) when is_map(models) do
    invalid = for {phase, model} <- models, model not in @valid_models, do: {phase, model}
    if invalid == [], do: :ok, else: {:error, "invalid model(s): #{inspect(invalid)}"}
  end

  defp validate_field(:pr_workflow, v) when is_boolean(v), do: :ok
  defp validate_field(:pr_workflow, _v), do: {:error, "must be a boolean"}

  defp validate_field(:pr_base, v) when is_binary(v), do: :ok
  defp validate_field(:pr_base, _v), do: {:error, "must be a string"}

  defp validate_field(:pr_remote, v) when is_binary(v), do: :ok
  defp validate_field(:pr_remote, _v), do: {:error, "must be a string"}

  defp validate_field(field, _value), do: {:error, "unknown field #{inspect(field)}"}

  defp stacked_run? do
    case Process.whereis(Coordinator) do
      nil -> false
      server -> server |> Coordinator.status() |> Map.get(:context) |> RunContext.stacked?()
    end
  end

  # ---- dispatch (the apply table) ------------------------------------------

  defp dispatch({:models, models}) do
    updated =
      Enum.reduce(models, Config.models(), fn {phase, model}, acc ->
        Map.put(acc, phase_atom(phase), model)
      end)

    Application.put_env(@app, :models, updated)
  end

  defp dispatch({:budget_usd, amount}) do
    if server = Process.whereis(Ledger), do: Ledger.set_budget(server, amount * 1.0)
  end

  defp dispatch({:max_concurrency, n}) do
    if server = Process.whereis(Coordinator), do: Coordinator.set_cap(server, n)
    Application.put_env(@app, :max_concurrency, n)
  end

  defp dispatch({:pr_workflow, bool}), do: Application.put_env(@app, :pr_workflow, bool)
  defp dispatch({:pr_base, v}), do: Application.put_env(@app, :pr_base, v)
  defp dispatch({:pr_remote, v}), do: Application.put_env(@app, :pr_remote, v)

  defp phase_atom(phase) when is_atom(phase), do: phase
  defp phase_atom(phase) when is_binary(phase), do: String.to_existing_atom(phase)
end
