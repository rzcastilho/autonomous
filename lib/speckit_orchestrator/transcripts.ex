defmodule SpeckitOrchestrator.Transcripts do
  @moduledoc """
  Per-phase transcript files for post-mortems.

  Written in two places: `<worktree>/.speckit_logs/NN-<phase>.md` for live
  inspection, and a **durable** copy under `<feature_id>/NN-<phase>.md` under
  the run's `%Layout{}.transcript_root` (scope-keyed — FR-004/FR-011) that
  survives worktree teardown on `:done` — otherwise a completed run's
  plan/tasks/implement transcripts vanish with the worktree. A no-op when there
  is no worktree (dry runs / tests without a tree). `layout: nil` (tests,
  non-012 callers) falls back to the pre-012 flat `Config.transcript_root/0`.
  """

  alias SpeckitOrchestrator.{Config, Layout, PhaseResult, Worktree}

  @dir ".speckit_logs"

  @doc "Write the transcript for `phase` (step `n`) into the worktree + durable root."
  @spec write(
          Worktree.t() | String.t() | nil,
          Layout.t() | nil,
          non_neg_integer(),
          atom(),
          PhaseResult.t()
        ) :: {:ok, String.t()} | :ok
  def write(nil, _layout, _n, _phase, _result), do: :ok

  def write(%Worktree{path: path, feature_id: feature_id}, layout, n, phase, %PhaseResult{} = result) do
    _ = maybe_write_durable(feature_id, layout, n, phase, result)
    file = write_to(Path.join(path, @dir), n, phase, result)
    {:ok, file}
  end

  def write(path, _layout, n, phase, %PhaseResult{} = result) when is_binary(path) do
    file = write_to(Path.join(path, @dir), n, phase, result)
    {:ok, file}
  end

  def write(_path, _layout, _n, _phase, _result), do: :ok

  # Durable copy outside the worktree, keyed by feature. Best-effort: a failure
  # here must never break a run, so it is not asserted.
  defp maybe_write_durable(nil, _layout, _n, _phase, _result), do: :ok

  defp maybe_write_durable(feature_id, layout, n, phase, result) do
    write_to(Path.join(durable_root(layout), feature_id), n, phase, result)
  rescue
    _ -> :ok
  end

  defp durable_root(nil), do: Config.transcript_root()
  defp durable_root(%Layout{transcript_root: root}), do: root

  defp write_to(dir, n, phase, result) do
    File.mkdir_p!(dir)
    file = Path.join(dir, "#{pad(n)}-#{phase}.md")
    File.write!(file, render(phase, result))
    file
  end

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
