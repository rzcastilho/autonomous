defmodule Autonomous.ContainerEngine do
  @moduledoc """
  Container engine sidecar (feature 046): an opt-in, container-only capability that
  gives agent sessions a real container engine — the `docker` CLI, `docker compose`,
  `docker buildx` — through the standard `DOCKER_HOST`, served by a rootless engine
  in a sidecar (`compose.engine.yaml`, `scripts/autonomous --docker`).

  `advertised?/1` and `requested?/1` are this module's only environment reads:

    * `requested?/1` — the overlay asked for an engine
      (`AUTONOMOUS_CONTAINER_ENGINE_REQUESTED=1`); drives the Configuration row.
    * `advertised?/1` — the entrypoint probed it successfully and exported
      `AUTONOMOUS_CONTAINER_ENGINE=1` inside an `AUTONOMOUS_CONTAINER=1` image;
      drives the prompt note and the end-of-phase cleanup.

  Everything else takes its inputs explicitly, so a request built with
  `container_engine: false` is byte-identical to pre-046 and the default suite
  (no env) never touches `docker`. The `docker` boundary is
  `Autonomous.ContainerEngine.Cli`, injected through `Config.container_engine_cli/0`.
  """

  alias Autonomous.{Config, Prompts}

  @type env :: %{optional(String.t()) => String.t()}

  @probe_timeout_ms 5_000

  @doc "True iff both container and engine markers are `\"1\"` in `env` (set only after a positive probe)."
  @spec advertised?(env()) :: boolean()
  def advertised?(env \\ System.get_env()) do
    Map.get(env, "AUTONOMOUS_CONTAINER") == "1" and
      Map.get(env, "AUTONOMOUS_CONTAINER_ENGINE") == "1"
  end

  @doc "True iff the instance was started with the engine sidecar (`--docker`), probed or not."
  @spec requested?(env()) :: boolean()
  def requested?(env \\ System.get_env()) do
    Map.get(env, "AUTONOMOUS_CONTAINER") == "1" and
      Map.get(env, "AUTONOMOUS_CONTAINER_ENGINE_REQUESTED") == "1"
  end

  @doc "Prompt block telling the agent an engine is available (`\"\"` when not advertised)."
  @spec prompt_note(boolean()) :: String.t()
  def prompt_note(true), do: "\n\n" <> Prompts.load("container_engine")
  def prompt_note(false), do: ""

  @doc """
  Ask the engine for its server version, bounded.

  Options: `:cli` (module, default `Config.container_engine_cli/0`) and
  `:timeout_ms` (default #{@probe_timeout_ms}). Returns `{:ok, version}` or
  `{:error, cause}` with a one-line human cause; never raises.
  """
  @spec probe(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def probe(opts \\ []) do
    cli = Keyword.get_lazy(opts, :cli, &Config.container_engine_cli/0)
    timeout = Keyword.get(opts, :timeout_ms, @probe_timeout_ms)

    task =
      Task.Supervisor.async_nolink(Autonomous.SessionSup, fn ->
        cli.run(["version", "--format", "{{.Server.Version}}"], timeout)
      end)

    case Task.yield(task, timeout + 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, out}} -> version(out)
      {:ok, {:error, {:exit, 124, _}}} -> {:error, timeout_cause(timeout)}
      {:ok, {:error, {:exit, _status, output}}} -> {:error, first_line(output)}
      {:exit, _reason} -> {:error, "the engine probe crashed"}
      nil -> {:error, timeout_cause(timeout)}
    end
  end

  defp version(out) do
    case String.trim(out) do
      "" -> {:error, "the engine answered without a version"}
      v -> {:ok, v}
    end
  end

  defp timeout_cause(ms), do: "the engine did not answer within #{div(ms, 1000)}s"

  defp first_line(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil -> "the engine did not answer"
      line -> String.trim(line)
    end
  end
end
