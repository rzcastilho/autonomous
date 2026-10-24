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

  require Logger

  alias Autonomous.{Config, Feature, Prompts}

  @type env :: %{optional(String.t()) => String.t()}

  @typedoc "Leftover engine resources after a sweep; `-1` = the listing itself could not run."
  @type residue :: %{
          containers: integer(),
          networks: integer(),
          volumes: integer()
        }

  @type step :: :list | :rm | :network_prune | :volume_prune | :verify
  @type cause :: {:exit, step(), integer(), String.t()} | :timeout | {:crash, term()}
  @type cleanup_result :: :skipped | :clean | {:residue, residue(), cause()}

  @probe_timeout_ms 5_000
  @unknown %{containers: -1, networks: -1, volumes: -1}

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

  @doc """
  End-of-phase sweep: remove every container (with its anonymous volumes), prune
  networks and volumes, then verify nothing is left. Images and build cache are
  never touched.

  Options: `:advertised?` (default `advertised?/0`; `false` ⇒ `:skipped` with zero
  CLI calls), `:cli`, `:timeout_ms` (hard bound on the whole sweep, default
  `Config.container_engine_cleanup_timeout_ms/0`). Never raises.
  """
  @spec cleanup(keyword()) :: cleanup_result()
  def cleanup(opts \\ []) do
    if Keyword.get_lazy(opts, :advertised?, &advertised?/0) do
      cli = Keyword.get_lazy(opts, :cli, &Config.container_engine_cli/0)
      timeout = Keyword.get_lazy(opts, :timeout_ms, &Config.container_engine_cleanup_timeout_ms/0)

      task = Task.Supervisor.async_nolink(Autonomous.SessionSup, fn -> sweep(cli, timeout) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:residue, @unknown, {:crash, reason}}
        nil -> {:residue, @unknown, :timeout}
      end
    else
      :skipped
    end
  end

  @doc """
  The `FeatureRunner` seam: `cleanup/1` plus logging and the
  `[:speckit, :engine, :cleanup]` telemetry event. Always `:ok` — a phase's
  outcome never depends on the sweep.
  """
  @spec after_boundary(Feature.t(), atom(), keyword()) :: :ok
  def after_boundary(%Feature{} = feature, phase, opts \\ []) do
    started = System.monotonic_time()
    result = cleanup(opts)
    duration = System.monotonic_time() - started

    case result do
      :skipped ->
        :ok

      :clean ->
        Logger.debug("container engine: cleanup after feature #{feature.id} (#{phase}) clean")
        emit(duration, feature, phase, :clean, %{containers: 0, networks: 0, volumes: 0})

      {:residue, residue, cause} ->
        Logger.error(
          "container engine: cleanup after feature #{feature.id} (#{phase}) left " <>
            "#{count(residue.containers)} containers, #{count(residue.networks)} networks, " <>
            "#{count(residue.volumes)} volumes (#{describe_cause(cause)}) — the next phase " <>
            "boundary retries; images and build cache are kept"
        )

        emit(duration, feature, phase, :residue, residue)
    end

    :ok
  end

  defp emit(duration, feature, phase, result, residue) do
    :telemetry.execute(
      [:speckit, :engine, :cleanup],
      %{duration: duration},
      %{feature_id: feature.id, phase: phase, result: result, residue: residue}
    )
  end

  defp count(-1), do: "unknown"
  defp count(n), do: n

  defp describe_cause({:exit, step, status, excerpt}),
    do: "#{step} exited #{status}: #{String.slice(excerpt, 0, 200)}"

  defp describe_cause(:timeout), do: "timed out"
  defp describe_cause({:crash, reason}), do: "crashed: #{inspect(reason)}"

  # Runs inside the supervised task. Every step runs even if an earlier one failed
  # (a failed `rm` should not stop the prune); the first failure becomes the cause.
  defp sweep(cli, timeout) do
    run = fn step, args ->
      case cli.run(args, timeout) do
        {:ok, out} -> {:ok, out}
        {:error, {:exit, status, output}} -> {:error, {:exit, step, status, output}}
      end
    end

    {ids, list_err} =
      case run.(:list, ["ps", "-aq"]) do
        {:ok, out} -> {lines(out), nil}
        {:error, cause} -> {[], cause}
      end

    errors =
      [
        list_err,
        if(ids == [], do: nil, else: failure(run.(:rm, ["rm", "-f", "-v" | ids]))),
        failure(run.(:network_prune, ["network", "prune", "-f"])),
        failure(run.(:volume_prune, ["volume", "prune", "-af"]))
      ]
      |> Enum.reject(&is_nil/1)

    residue = %{
      containers: listed(run.(:verify, ["ps", "-aq"])),
      networks: listed(run.(:verify, ["network", "ls", "-q", "--filter", "type=custom"])),
      volumes: listed(run.(:verify, ["volume", "ls", "-q"]))
    }

    cond do
      errors != [] ->
        {:residue, residue, hd(errors)}

      Enum.any?(Map.values(residue), &(&1 != 0)) ->
        {:residue, residue, {:exit, :verify, 0, "resources remain after the sweep"}}

      true ->
        :clean
    end
  end

  defp failure({:ok, _}), do: nil
  defp failure({:error, cause}), do: cause

  defp listed({:ok, out}), do: length(lines(out))
  defp listed({:error, _}), do: -1

  defp lines(out),
    do:
      String.split(out, "\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end
