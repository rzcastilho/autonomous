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
  friends are read at call time); budget goes through the additive
  `Ledger.set_budget/2` setter, which touches no in-flight work (Constitution
  IV: drain, don't kill). 019: `:pr_workflow`/`:max_concurrency` are retired —
  every run is a stacked sequential run, so there is nothing left to toggle.

  018/FR-027: a successful apply against a live run also records a settings
  amendment through the store — changed keys only, old -> new — so the
  record explains why later work behaved differently from earlier work. A
  no-op with no live `Coordinator` (most unit tests) or no store-backed run.
  """

  alias SpeckitOrchestrator.{Config, Coordinator, Ledger, RepoIdentity, Store}
  alias SpeckitOrchestrator.Store.Writer

  @app :speckit_orchestrator
  @valid_models ~w(opus sonnet)

  @type change :: %{
          optional(:models) => %{(atom() | String.t()) => String.t()},
          optional(:budget_usd) => number(),
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

  defp validate_field(:models, models) when is_map(models) do
    invalid = for {phase, model} <- models, model not in @valid_models, do: {phase, model}
    if invalid == [], do: :ok, else: {:error, "invalid model(s): #{inspect(invalid)}"}
  end

  defp validate_field(:pr_base, v) when is_binary(v), do: :ok
  defp validate_field(:pr_base, _v), do: {:error, "must be a string"}

  defp validate_field(:pr_remote, v) when is_binary(v), do: :ok
  defp validate_field(:pr_remote, _v), do: {:error, "must be a string"}

  defp validate_field(field, _value), do: {:error, "unknown field #{inspect(field)}"}

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

  defp dispatch({:pr_base, v}), do: Application.put_env(@app, :pr_base, v)
  defp dispatch({:pr_remote, v}), do: Application.put_env(@app, :pr_remote, v)

  defp phase_atom(phase) when is_atom(phase), do: phase
  defp phase_atom(phase) when is_binary(phase), do: String.to_existing_atom(phase)
end
