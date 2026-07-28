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

  018/FR-027: a successful apply against a live run also records a settings
  amendment through the store — changed keys only, old -> new — so the
  record explains why later work behaved differently from earlier work. A
  no-op with no live `Coordinator` (most unit tests) or no store-backed run.
  """

  alias SpeckitOrchestrator.{Config, Coordinator, Ledger, RepoIdentity, RunContext, Store}
  alias SpeckitOrchestrator.Store.Writer

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
        record_amendment(changes)
        Enum.each(changes, &dispatch/1)
        {:ok, changes}

      {:error, _errors} = error ->
        error
    end
  end

  # ---- store amendment (018, FR-027) ---------------------------------------

  defp record_amendment(changes) do
    if Process.whereis(Coordinator) do
      case Store.current_run_key(RepoIdentity.partition(Config.repo())) do
        nil ->
          :ok

        run_key ->
          diff =
            Map.new(changes, fn {field, new} -> {field, %{old: old_value(field), new: new}} end)

          Writer.record_settings_amendment(run_key, diff, DateTime.utc_now())
      end
    end

    :ok
  end

  defp old_value(:models), do: Config.models()
  defp old_value(:budget_usd), do: Config.budget_usd()
  defp old_value(:max_concurrency), do: Config.max_concurrency()
  defp old_value(:pr_workflow), do: Config.pr_workflow?()
  defp old_value(:pr_base), do: Config.pr_base()
  defp old_value(:pr_remote), do: Config.pr_remote()

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
