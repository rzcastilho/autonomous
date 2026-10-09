defmodule Autonomous.AgentRoot do
  @moduledoc """
  Agent root (feature 037): an opt-in, container-only capability that lets a
  session install missing operating-system packages with `sudo apt-get`/`apt`.
  039: nothing in-tree restricts the `sudo` grammar any more (the hook is
  gone); the image's `APT::Get::Remove "false"` and the prompt's guidance
  ("never remove, purge or upgrade") are what remain.

  `advertised?/1` is the module's only environment read — true when the
  entrypoint verified `sudo -n true` and exported `AUTONOMOUS_AGENT_ROOT=1`
  inside an `AUTONOMOUS_CONTAINER=1` image. Everything else is pure, so a
  request built with `agent_root: false` is byte-identical to pre-037.
  """

  require Logger

  alias Autonomous.{Feature, PhaseResult, Prompts}

  @type install :: %{command: String.t(), packages: [String.t()]}

  @doc "True iff both container and agent-root markers are `\"1\"` in `env`."
  @spec advertised?(%{optional(String.t()) => String.t()}) :: boolean()
  def advertised?(env \\ System.get_env()) do
    Map.get(env, "AUTONOMOUS_CONTAINER") == "1" and Map.get(env, "AUTONOMOUS_AGENT_ROOT") == "1"
  end

  @doc "Launch-env markers carried by every orchestrated session."
  @spec session_env(boolean()) :: %{String.t() => String.t()}
  def session_env(true), do: %{"AUTONOMOUS_CONTAINER" => "1", "AUTONOMOUS_AGENT_ROOT" => "1"}
  def session_env(false), do: %{}

  @doc "Prompt block telling the agent it may install packages (`\"\"` when not advertised)."
  @spec prompt_note(boolean()) :: String.t()
  def prompt_note(true), do: "\n\n" <> Prompts.load("agent_root")
  def prompt_note(false), do: ""

  @doc "The `sudo … apt-get|apt install <pkgs>` segments of the session's Bash calls."
  @spec installs(PhaseResult.t() | nil) :: [install()]
  def installs(%PhaseResult{tool_events: events}) do
    for %{kind: :call, payload: %{"name" => "Bash", "input" => %{"command" => cmd}}} <- events,
        is_binary(cmd),
        install <- command_installs(cmd),
        do: install
  end

  def installs(_), do: []

  @doc "Log one line per install in `result` (FR-018). Nothing is persisted."
  @spec log_installs(Feature.t(), atom(), PhaseResult.t() | nil) :: :ok
  def log_installs(%Feature{} = feature, phase, result) do
    label = Feature.spec_label(feature) || feature.id

    for %{packages: pkgs} <- installs(result) do
      Logger.info(
        "agent root: feature #{label} (#{phase}) installed system packages: " <>
          "#{Enum.join(pkgs, " ")} — add them to `scripts/autonomous build --apt` to persist"
      )
    end

    :ok
  end

  defp command_installs(cmd) do
    cmd
    |> String.split(~r/&&|\|\||[;|&\n]/)
    |> Enum.flat_map(fn seg ->
      case String.split(seg) do
        ["sudo" | rest] -> segment_install(rest, String.trim(seg))
        _ -> []
      end
    end)
  end

  defp segment_install(tokens, command) do
    tokens = Enum.drop_while(tokens, &(&1 == "-n" or Regex.match?(~r/^[A-Z_]+=/, &1)))

    case tokens do
      [pm, "install" | args] when pm in ["apt-get", "apt"] ->
        pkgs = Enum.reject(args, &String.starts_with?(&1, "-"))
        if pkgs == [], do: [], else: [%{command: command, packages: pkgs}]

      _ ->
        []
    end
  end
end
