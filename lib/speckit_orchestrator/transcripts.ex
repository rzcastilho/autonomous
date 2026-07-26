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

  alias SpeckitOrchestrator.{Chunking, Config, Layout, PhaseResult, Worktree}

  @dir ".speckit_logs"

  # The `reason()` tags `Chunking.failure_sentence/1` accepts (SC-002) — used
  # to recognize a chunked implement roll-up's failure without depending on
  # `Chunking`'s type at the pattern-match level.
  @chunk_failure_reasons [:stuck_task_phase, :session_ceiling, :unchecked_tasks, :session_error]

  @doc "Write the transcript for `phase` (step `n`) into the worktree + durable root."
  @spec write(
          Worktree.t() | String.t() | nil,
          Layout.t() | nil,
          non_neg_integer(),
          atom(),
          PhaseResult.t()
        ) :: {:ok, String.t()} | :ok
  def write(nil, _layout, _n, _phase, _result), do: :ok

  def write(
        %Worktree{path: path, feature_id: feature_id},
        layout,
        n,
        phase,
        %PhaseResult{} = result
      ) do
    _ = maybe_write_durable(feature_id, layout, n, phase, result)
    file = write_to(Path.join(path, @dir), n, phase, result)
    {:ok, file}
  end

  def write(path, _layout, n, phase, %PhaseResult{} = result) when is_binary(path) do
    file = write_to(Path.join(path, @dir), n, phase, result)
    {:ok, file}
  end

  def write(_path, _layout, _n, _phase, _result), do: :ok

  @doc """
  Write a chunk (015) transcript: same two-copy behavior as `write/5`, but
  named by an explicit `label` instead of the phase atom — chunk
  attempts and the roll-up all share step `n` (implement never consumes a
  step number of its own, research R6), distinguished only by label:

    * `"implement-p<NN>-a<N>"` — one per task-phase attempt
    * `"implement-sweep-a<N>"` — one per sweep attempt
    * `"implement"` — the roll-up, written once when the step ends (same
      filename `write/5` would produce for `phase: :implement` directly)

  `phase` is passed through to `render/2` for the `# <phase>` header only.
  """
  @spec write_labelled(
          Worktree.t() | String.t() | nil,
          Layout.t() | nil,
          non_neg_integer(),
          String.t(),
          atom(),
          PhaseResult.t()
        ) :: {:ok, String.t()} | :ok
  def write_labelled(nil, _layout, _n, _label, _phase, _result), do: :ok

  def write_labelled(
        %Worktree{path: path, feature_id: feature_id},
        layout,
        n,
        label,
        phase,
        %PhaseResult{} = result
      ) do
    _ = maybe_write_durable_labelled(feature_id, layout, n, label, phase, result)
    file = write_to_labelled(Path.join(path, @dir), n, label, phase, result)
    {:ok, file}
  end

  def write_labelled(path, _layout, n, label, phase, %PhaseResult{} = result)
      when is_binary(path) do
    file = write_to_labelled(Path.join(path, @dir), n, label, phase, result)
    {:ok, file}
  end

  def write_labelled(_path, _layout, _n, _label, _phase, _result), do: :ok

  # Durable copy outside the worktree, keyed by feature. Best-effort: a failure
  # here must never break a run, so it is not asserted.
  defp maybe_write_durable(nil, _layout, _n, _phase, _result), do: :ok

  defp maybe_write_durable(feature_id, layout, n, phase, result) do
    write_to(Path.join(durable_root(layout), feature_id), n, phase, result)
  rescue
    _ -> :ok
  end

  defp maybe_write_durable_labelled(nil, _layout, _n, _label, _phase, _result), do: :ok

  defp maybe_write_durable_labelled(feature_id, layout, n, label, phase, result) do
    write_to_labelled(Path.join(durable_root(layout), feature_id), n, label, phase, result)
  rescue
    _ -> :ok
  end

  defp durable_root(nil), do: Config.transcript_root()
  defp durable_root(%Layout{transcript_root: root}), do: root

  defp write_to(dir, n, phase, result),
    do: write_to_labelled(dir, n, Atom.to_string(phase), phase, result)

  defp write_to_labelled(dir, n, label, phase, result) do
    File.mkdir_p!(dir)
    file = Path.join(dir, "#{pad(n)}-#{label}.md")
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
    - error: #{inspect(r.error)}
    - subtype: #{r.subtype}
    #{reason_line(phase, r.error)}
    ## final text

    #{r.final_text}
    """
  end

  # The SC-002 operator sentence for a chunked implement roll-up's failure
  # (contracts/chunk_session.md §5) — absent for every other phase/outcome, so
  # SC-006 ("cause identifiable from the operator surfaces alone") holds
  # without reading agent-tool logs.
  defp reason_line(:implement, reason) when is_tuple(reason) do
    if elem(reason, 0) in @chunk_failure_reasons do
      "- reason: #{Chunking.failure_sentence(reason)}"
    else
      ""
    end
  end

  defp reason_line(_phase, _error), do: ""

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
