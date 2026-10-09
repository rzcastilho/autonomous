defmodule Autonomous.SdkProxy do
  @moduledoc """
  Thin `:jido_claude, :sdk_module` wrapper that attaches a per-session CLI
  stderr callback (feature 036).

  The pinned `Jido.Claude.Adapter` whitelists the option keys it forwards to the
  SDK and drops `:stderr`, so `metadata["claude"][:stderr]` never arrives. The
  session instead carries its `WorkspaceTrust.Collector` pid in the request env
  under `#{inspect("AUTONOMOUS_STDERR_COLLECTOR")}` (`PhaseRequest`); this module
  pulls it out — so the marker never reaches the CLI's environment — installs
  the callback, and delegates to the real SDK.

  The delegate is `ClaudeAgentSDK` unless `config :autonomous, :sdk_proxy_inner`
  names another module (tests substitute fake SDKs there).
  """

  require Logger

  alias Autonomous.WorkspaceTrust
  alias Autonomous.WorkspaceTrust.Collector

  @env_key "AUTONOMOUS_STDERR_COLLECTOR"

  @doc "Env key `PhaseRequest` uses to hand the collector pid to this module."
  @spec env_key() :: String.t()
  def env_key, do: @env_key

  @doc "Encode a collector pid for the request env."
  @spec encode(pid()) :: String.t()
  def encode(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @doc false
  def query(prompt, options), do: inner().query(prompt, prepare(options))

  @doc false
  def resume(session_id, prompt, options),
    do: inner().resume(session_id, prompt, prepare(options))

  @doc """
  Strip the collector marker from `options.env` and install the stderr callback.
  Options without a marker (or non-struct options) pass through logging-only.
  """
  def prepare(%{env: env} = options) when is_map(env) do
    {marker, env} = Map.pop(env, @env_key)
    %{options | env: env, stderr: callback(decode(marker))}
  end

  def prepare(options), do: options

  @doc """
  The stderr callback: logs each line exactly as the SDK default did and
  forwards untrusted-workspace lines to `collector` (`nil` = log only).
  """
  @spec callback(pid() | nil) :: (String.t() -> :ok)
  def callback(collector) do
    fn line ->
      Logger.warning("CLI stderr: " <> line)
      if WorkspaceTrust.parse_line(line) != :other, do: Collector.push(collector, line)
      :ok
    end
  end

  defp decode(nil), do: nil

  defp decode(marker) do
    marker |> String.to_charlist() |> :erlang.list_to_pid()
  rescue
    ArgumentError -> nil
  end

  defp inner, do: Application.get_env(:autonomous, :sdk_proxy_inner, ClaudeAgentSDK)
end
