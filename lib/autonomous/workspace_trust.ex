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
  Close out a session's collector: read and stop it, record the observation on
  the result, and log a warning when the CLI reported an untrusted workspace.
  039: warn-only for every run — there is no strict profile to fail under, so
  nothing is signalled to the gates. Every session-driving site calls this
  immediately after `PhaseSession.reduce/2`.
  """
  @spec settle(Autonomous.PhaseResult.t(), pid() | nil) :: Autonomous.PhaseResult.t()
  def settle(result, collector) do
    obs = collector |> Autonomous.WorkspaceTrust.Collector.collect() |> observe()
    if obs, do: warn(obs)
    %{result | untrusted_workspace: obs}
  end

  defp warn(obs) do
    Logger.warning(
      "untrusted workspace #{obs.workspace || "(no working directory)"}: " <>
        "CLI ignored #{Enum.join(obs.kinds, ", ")} from the committed pack; continuing"
    )
  end
end
