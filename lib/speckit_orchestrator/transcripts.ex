defmodule SpeckitOrchestrator.Transcripts do
  @moduledoc """
  Per-phase transcript files for post-mortems, written under
  `<worktree>/.speckit_logs/NN-<phase>.md`. A no-op when there is no worktree
  (dry runs / tests without a tree).
  """

  alias SpeckitOrchestrator.{PhaseResult, Worktree}

  @dir ".speckit_logs"

  @doc "Write the transcript for `phase` (step `n`) into the worktree."
  @spec write(Worktree.t() | String.t() | nil, non_neg_integer(), atom(), PhaseResult.t()) ::
          {:ok, String.t()} | :ok
  def write(nil, _n, _phase, _result), do: :ok
  def write(%Worktree{path: path}, n, phase, result), do: write(path, n, phase, result)

  def write(path, n, phase, %PhaseResult{} = result) when is_binary(path) do
    dir = Path.join(path, @dir)
    File.mkdir_p!(dir)
    file = Path.join(dir, "#{pad(n)}-#{phase}.md")
    File.write!(file, render(phase, result))
    {:ok, file}
  end

  def write(_path, _n, _phase, _result), do: :ok

  defp render(phase, %PhaseResult{} = r) do
    """
    # #{phase}

    - status: #{r.status}
    - session_id: #{r.session_id}
    - cost_usd: #{inspect(r.cost_usd)}
    - tool_events: #{length(r.tool_events)}
    - turns: #{inspect(r.num_turns)}

    ## final text

    #{r.final_text}
    """
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
