defmodule Autonomous.AppliedVolumes do
  @moduledoc """
  The user-defined volumes the instance was started with (feature 041,
  contracts/applied-volumes.md). The host wrapper hands the applied set to the
  container as one `AUTONOMOUS_VOLUMES` JSON value (`version: 1`); this module
  decodes it. Pure except `current/0`, the single env read.
  """

  defmodule Volume do
    @moduledoc "One applied volume: mount path, variables, and `PATH` directories."
    @enforce_keys [:name, :path]
    defstruct [:name, :path, env: [], path_dirs: []]

    @type t :: %__MODULE__{
            name: String.t(),
            path: String.t(),
            env: [{String.t(), String.t()}],
            path_dirs: [String.t()]
          }
  end

  @env_var "AUTONOMOUS_VOLUMES"

  @doc "Decodes the `AUTONOMOUS_VOLUMES` value; `nil`/`\"\"` mean no declaration."
  @spec parse(String.t() | nil) ::
          {:ok, [Volume.t()], String.t() | nil} | {:error, String.t()}
  def parse(nil), do: {:ok, [], nil}
  def parse(""), do: {:ok, [], nil}

  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"version" => 1, "volumes" => volumes} = applied} when is_list(volumes) ->
        build(volumes, applied["declaration"])

      {:ok, %{"version" => version}} ->
        {:error, "unsupported version #{format_version(version)}"}

      {:ok, _} ->
        {:error, "unexpected shape"}

      {:error, _} ->
        {:error, "not valid JSON"}
    end
  end

  @doc "Reads and decodes `AUTONOMOUS_VOLUMES` from the environment."
  @spec current() :: {:ok, [Volume.t()], String.t() | nil} | {:error, String.t()}
  def current, do: parse(System.get_env(@env_var))

  defp build(entries, declaration) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case volume(entry) do
        {:ok, volume} -> {:cont, {:ok, [volume | acc]}}
        :error -> {:halt, {:error, "unexpected volume shape"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc), declaration_path(declaration)}
      {:error, _} = error -> error
    end
  end

  defp volume(%{"name" => name, "path" => path} = entry)
       when is_binary(name) and is_binary(path) do
    with {:ok, env} <- env_pairs(Map.get(entry, "env", [])),
         {:ok, dirs} <- string_list(Map.get(entry, "path_dirs", [])) do
      {:ok, %Volume{name: name, path: path, env: env, path_dirs: dirs}}
    end
  end

  defp volume(_), do: :error

  defp env_pairs(pairs) when is_list(pairs) do
    if Enum.all?(pairs, &match?([k, v] when is_binary(k) and is_binary(v), &1)) do
      {:ok, Enum.map(pairs, fn [k, v] -> {k, v} end)}
    else
      :error
    end
  end

  defp env_pairs(_), do: :error

  defp string_list(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error
  end

  defp string_list(_), do: :error

  defp declaration_path(path) when is_binary(path), do: path
  defp declaration_path(_), do: nil

  defp format_version(version) when is_binary(version) or is_number(version),
    do: to_string(version)

  defp format_version(_), do: "(non-scalar)"
end
