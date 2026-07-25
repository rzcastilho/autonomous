defmodule SpeckitOrchestrator.Container.Env do
  @moduledoc """
  The parsed, validated view of the boot environment (FR-020,
  `specs/015-container-isolation/data-model.md` §4,
  `specs/015-container-isolation/contracts/environment.md` §1-§5).

  Not persisted — it is the intermediate between raw `System.get_env/0` and
  `Application.put_env/3` inside `config/runtime.exs`, and the source `Boot`
  reads for the auto-start decision. Every required setting absent, or every
  numeric/enum setting present-but-unparseable, raises naming the offending
  variable (and its value, where numeric) — never a silent compiled-in
  fallback (Constitution II).

  `parse!/1` takes an injected `%{String.t() => String.t()}` env map (defaults
  to `System.get_env/0` via `load!/0`) so every failure mode is hermetically
  unit-tested with no container.
  """

  @known_phases ~w(specify clarify plan tasks analyze implement converge describe)a

  @enforce_keys [:repo]
  defstruct repo: nil,
            host_repo: nil,
            host_home: nil,
            autonomous_root: "~/.autonomous",
            specs_root: "specs/autonomous",
            max_concurrency: 2,
            budget_usd: 74.0,
            implement_max_turns: 80,
            phase_max_retries: 1,
            plan_stack: [],
            models: %{},
            pr_workflow?: false,
            pr_base: "main",
            pr_remote: "origin",
            speckit_version: "v0.12.11",
            console_ip: {0, 0, 0, 0},
            console_port: 4000,
            autostart: :none

  @type autostart :: :none | {:breakdown, String.t()} | :ad_hoc

  @type t :: %__MODULE__{
          repo: String.t(),
          host_repo: String.t() | nil,
          host_home: String.t() | nil,
          autonomous_root: String.t(),
          specs_root: String.t(),
          max_concurrency: pos_integer(),
          budget_usd: float(),
          implement_max_turns: pos_integer(),
          phase_max_retries: non_neg_integer(),
          plan_stack: [String.t()],
          models: %{atom() => String.t()},
          pr_workflow?: boolean(),
          pr_base: String.t(),
          pr_remote: String.t(),
          speckit_version: String.t(),
          console_ip: :inet.ip_address(),
          console_port: pos_integer(),
          autostart: autostart()
        }

  @doc "Parse the current OS environment. Raises per `parse!/1`."
  @spec load!() :: t()
  def load!, do: parse!(System.get_env())

  @doc """
  Parse an injected env map into a validated `t()`. Raises `ArgumentError` on
  any required-but-absent or present-but-invalid variable, naming the
  variable (and value, for numeric/enum fields).
  """
  @spec parse!(%{String.t() => String.t()}) :: t()
  def parse!(env) when is_map(env) do
    %__MODULE__{
      repo: fetch_required!(env, "SPECKIT_REPO"),
      host_repo: get(env, "AUTONOMOUS_HOST_REPO"),
      host_home: get(env, "AUTONOMOUS_HOST_HOME"),
      autonomous_root: parse_absolute_path!(env, "AUTONOMOUS_ROOT", "~/.autonomous"),
      specs_root: parse_relative_path!(env, "SPECKIT_SPECS_ROOT", "specs/autonomous"),
      max_concurrency: parse_pos_integer!(env, "SPECKIT_MAX_CONCURRENCY", 2),
      budget_usd: parse_positive_float!(env, "SPECKIT_BUDGET_USD", 74.0),
      implement_max_turns: parse_pos_integer!(env, "SPECKIT_IMPLEMENT_MAX_TURNS", 80),
      phase_max_retries: parse_non_neg_integer!(env, "SPECKIT_PHASE_MAX_RETRIES", 1),
      plan_stack: parse_plan_stack(env),
      models: parse_models!(env),
      pr_workflow?: truthy?(env, "SPECKIT_PR_WORKFLOW", false),
      pr_base: get(env, "SPECKIT_PR_BASE") || "main",
      pr_remote: get(env, "SPECKIT_PR_REMOTE") || "origin",
      speckit_version: get(env, "SPECKIT_VERSION") || "v0.12.11",
      console_ip: parse_ip!(env, "AUTONOMOUS_CONSOLE_IP", {0, 0, 0, 0}),
      console_port: parse_pos_integer!(env, "AUTONOMOUS_CONSOLE_PORT", 4000),
      autostart: parse_autostart!(env)
    }
  end

  # ---- individual field parsers -------------------------------------------

  defp get(env, name), do: Map.get(env, name)

  defp fetch_required!(env, name) do
    case Map.get(env, name) do
      nil -> raise ArgumentError, "#{name} is not set"
      "" -> raise ArgumentError, "#{name} is not set"
      value -> value
    end
  end

  defp parse_absolute_path!(env, name, default) do
    case get(env, name) do
      nil ->
        default

      value ->
        if String.starts_with?(value, "/") or String.starts_with?(value, "~") do
          value
        else
          raise ArgumentError, "#{name} must be an absolute path, got: #{inspect(value)}"
        end
    end
  end

  defp parse_relative_path!(env, name, default) do
    case get(env, name) do
      nil ->
        default

      value ->
        if String.starts_with?(value, "/") do
          raise ArgumentError, "#{name} must be a relative path, got: #{inspect(value)}"
        else
          value
        end
    end
  end

  defp parse_pos_integer!(env, name, default) do
    case get(env, name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> n
          _ -> raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
        end
    end
  end

  defp parse_non_neg_integer!(env, name, default) do
    case get(env, name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {n, ""} when n >= 0 ->
            n

          _ ->
            raise ArgumentError,
                  "#{name} must be a non-negative integer, got: #{inspect(value)}"
        end
    end
  end

  defp parse_positive_float!(env, name, default) do
    case get(env, name) do
      nil ->
        default

      value ->
        case Float.parse(value) do
          {n, ""} when n > 0 -> n
          _ -> raise ArgumentError, "#{name} must be a positive number, got: #{inspect(value)}"
        end
    end
  end

  defp parse_plan_stack(env) do
    case get(env, "SPECKIT_PLAN_STACK") do
      nil -> []
      "" -> []
      stack -> [stack]
    end
  end

  defp truthy?(env, name, default) do
    case get(env, name) do
      nil -> default
      value -> String.downcase(value) in ~w(1 true yes on)
    end
  end

  defp parse_ip!(env, name, default) do
    case get(env, name) do
      nil ->
        default

      value ->
        case :inet.parse_address(String.to_charlist(value)) do
          {:ok, ip} -> ip
          {:error, _} -> raise ArgumentError, "#{name} is not a valid IPv4 address: #{inspect(value)}"
        end
    end
  end

  @autostart_slug ~r/^\d{3}-[a-z0-9]+(-[a-z0-9]+)*$/

  defp parse_autostart!(env) do
    case get(env, "AUTONOMOUS_AUTOSTART") do
      nil -> :none
      "" -> :none
      "ad-hoc" -> :ad_hoc
      value -> if Regex.match?(@autostart_slug, value), do: {:breakdown, value}, else: raise_autostart!(value)
    end
  end

  defp raise_autostart!(value) do
    raise ArgumentError,
          "AUTONOMOUS_AUTOSTART is neither empty, \"ad-hoc\", nor a breakdown slug " <>
            "(NNN-slug): #{inspect(value)}"
  end

  # ---- SPECKIT_MODEL_<PHASE> ----------------------------------------------

  defp parse_models!(env) do
    env
    |> Enum.filter(fn {k, _v} -> String.starts_with?(k, "SPECKIT_MODEL_") end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      suffix = String.replace_prefix(key, "SPECKIT_MODEL_", "")
      phase = suffix |> String.downcase() |> String.to_atom()

      unless phase in @known_phases do
        raise ArgumentError,
              "#{key} names an unknown phase #{inspect(suffix)}; known phases: " <>
                inspect(@known_phases)
      end

      unless value in SpeckitOrchestrator.Config.valid_models() do
        raise ArgumentError,
              "#{key} is not a known model alias #{inspect(value)}; accepted: " <>
                inspect(SpeckitOrchestrator.Config.valid_models())
      end

      Map.put(acc, phase, value)
    end)
  end
end
