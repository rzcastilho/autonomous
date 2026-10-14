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

  Feature 040 adds the conversation tap: a session opened through
  `Autonomous.Conversation` carries its recorder pid under
  `"AUTONOMOUS_CONVERSATION"`; that marker is stripped the same way and every
  raw frame of the returned stream is `send/2`ed to the recorder — before the
  lossy harness mapper, never awaited, never altered (FR-005, FR-026). A dead
  recorder pid is a silent no-op.

  The delegate is `ClaudeAgentSDK` unless `config :autonomous, :sdk_proxy_inner`
  names another module (tests substitute fake SDKs there).
  """

  require Logger

  alias Autonomous.WorkspaceTrust
  alias Autonomous.WorkspaceTrust.Collector

  @env_key "AUTONOMOUS_STDERR_COLLECTOR"
  @conversation_key "AUTONOMOUS_CONVERSATION"

  @doc "Env key `PhaseRequest` uses to hand the collector pid to this module."
  @spec env_key() :: String.t()
  def env_key, do: @env_key

  @doc "Env key `Conversation.open/2` uses to hand the recorder pid to this module."
  @spec conversation_key() :: String.t()
  def conversation_key, do: @conversation_key

  @doc "Encode a collector pid for the request env."
  @spec encode(pid()) :: String.t()
  def encode(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @doc false
  def query(prompt, options),
    do: tap_frames(inner().query(prompt, prepare(options)), recorder(options))

  @doc false
  def resume(session_id, prompt, options),
    do: tap_frames(inner().resume(session_id, prompt, prepare(options)), recorder(options))

  # The recorder pid carried in the request env, or nil.
  defp recorder(%{env: env}) when is_map(env), do: decode(Map.get(env, @conversation_key))
  defp recorder(_), do: nil

  # Observation only: `send/2` never blocks, fails or alters the frame.
  defp tap_frames(stream, nil), do: stream

  defp tap_frames(stream, recorder) do
    if Enumerable.impl_for(stream) do
      Stream.each(stream, fn frame ->
        send(recorder, {:frame, frame})
        :ok
      end)
    else
      stream
    end
  end

  @doc """
  Strip the collector and conversation markers from `options.env` and install
  the stderr callback. Options without a marker (or non-struct options) pass
  through logging-only.
  """
  def prepare(%{env: env} = options) when is_map(env) do
    {marker, env} = Map.pop(env, @env_key)
    {conversation, env} = Map.pop(env, @conversation_key)
    %{options | env: env, stderr: callback(decode(marker), decode(conversation))}
  end

  def prepare(options), do: options

  @doc """
  The stderr callback: logs each line exactly as the SDK default did and
  forwards untrusted-workspace lines to `collector` (`nil` = log only).
  """
  @spec callback(pid() | nil) :: (String.t() -> :ok)
  def callback(collector), do: callback(collector, nil)

  @doc """
  As `callback/1`, and additionally `send/2`s `{:stderr, line}` to the
  conversation `recorder` (feature 043) — bare, never awaited, so capture can
  neither block nor alter the session. `nil` or a dead pid is a no-op.
  """
  @spec callback(pid() | nil, pid() | nil) :: (String.t() -> :ok)
  def callback(collector, recorder) do
    fn line ->
      Logger.warning("CLI stderr: " <> line)
      if WorkspaceTrust.parse_line(line) != :other, do: Collector.push(collector, line)
      if is_pid(recorder), do: send(recorder, {:stderr, line})
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
