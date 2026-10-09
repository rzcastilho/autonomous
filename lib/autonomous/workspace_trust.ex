defmodule Autonomous.WorkspaceTrust do
  @moduledoc """
  Pure parser for the Claude CLI's "untrusted workspace" stderr wording.

  This is the only module that knows that wording (one boundary per external
  contract); everything downstream sees `observation/0` values. Matched against
  CLI 2.1.286/2.1.294 — see `specs/036-container-workspace-trust/research.md` R2
  and `contracts/untrusted-workspace-gate.md` §1.
  """

  require Logger

  @untrusted_markers [
    "this workspace has not been trusted",
    "a session with no working directory is never trusted"
  ]

  @kinds ["permissions.allow", "permissions.additionalDirectories"]

  @type parsed :: %{workspace: String.t() | nil, kind: String.t() | nil}
  @type observation :: %{workspace: String.t() | nil, kinds: [String.t()]}

  @doc "Classify one stderr line."
  @spec parse_line(String.t()) :: {:untrusted, parsed()} | :other
  def parse_line(line) when is_binary(line) do
    if Enum.any?(@untrusted_markers, &String.contains?(line, &1)) do
      {:untrusted, %{workspace: workspace(line), kind: kind(line)}}
    else
      :other
    end
  end

  @doc """
  Fold stderr lines into one observation: `nil` when none is untrusted, else
  the first non-nil workspace and the deduped kinds in first-seen order.
  """
  @spec observe([String.t()]) :: observation() | nil
  def observe(lines) when is_list(lines) do
    case for(line <- lines, {:untrusted, p} <- [parse_line(line)], do: p) do
      [] ->
        nil

      parsed ->
        %{
          workspace: Enum.find_value(parsed, & &1.workspace),
          kinds: parsed |> Enum.map(& &1.kind) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        }
    end
  end

  defp workspace(line) do
    case Regex.run(~r/projects\["([^"]+)"\]/, line) do
      [_, path] -> path
      _ -> nil
    end
  end

  defp kind(line), do: Enum.find(@kinds, &String.contains?(line, &1))

  @doc """
  Decide what an observation means for a session under `profile`
  (contracts/untrusted-workspace-gate.md §3). Returns the observation to signal
  (`strict`, the default for any non-`"permissive"` value) or `nil`; under
  `"permissive"` it only logs a warning and returns `nil`.
  """
  @spec signal_or_warn([String.t()], String.t() | nil) :: observation() | nil
  def signal_or_warn(lines, profile) do
    case observe(lines) do
      nil ->
        nil

      obs ->
        if Autonomous.Containment.permissive?(profile) do
          Logger.warning(
            "untrusted workspace #{obs.workspace || "(no working directory)"}: " <>
              "CLI ignored #{Enum.join(obs.kinds, ", ")} from the committed pack; " <>
              "continuing under permissive"
          )

          nil
        else
          obs
        end
    end
  end

  @doc """
  Apply an `signal_or_warn/2` result to a classified `{outcome, signals}` pair:
  no observation leaves it untouched (byte-identical to pre-036); an observation
  forces `:error` and carries `signals.untrusted_workspace` for `Pipeline.next/3`.
  """
  @spec apply_to({:ok | :error, map()}, observation() | nil) :: {:ok | :error, map()}
  def apply_to(classified, nil), do: classified

  def apply_to({_outcome, signals}, obs),
    do: {:error, Map.put(signals, :untrusted_workspace, obs)}

  @doc """
  Close out a session's collector: read and stop it, record the observation on
  the result, and return the signal to carry (`nil` unless the run is `strict`
  and the CLI reported an untrusted workspace; permissive logs instead).
  Every session-driving site calls this immediately after `PhaseSession.reduce/2`.
  """
  @spec settle(Autonomous.PhaseResult.t(), pid() | nil, String.t() | nil) ::
          {Autonomous.PhaseResult.t(), observation() | nil}
  def settle(result, collector, profile) do
    lines = Autonomous.WorkspaceTrust.Collector.collect(collector)
    {%{result | untrusted_workspace: observe(lines)}, signal_or_warn(lines, profile)}
  end
end
