defmodule SpeckitOrchestrator.Checkpoint do
  @moduledoc """
  Durable per-feature resume pointer.

  Records the phase a feature reached when it terminated at a non-`:done`
  status (`:escalated` / `:halted` / `:failed`), the terminal status, reason,
  session id, the feature's identity (`slug`/`path`, so `resume/2` can
  rebuild the work-unit from the id alone — FR-001), and the run-shaping
  context (`RunContext`) captured at run start, so a resume re-executes under
  the original run shape (FR-006) — one JSON file at
  `<Config.transcript_root>/<feature_id>/checkpoint.json`. Write is
  best-effort (a failure never breaks the run — FR-008); a `:done` terminal
  deletes any existing checkpoint instead of writing one (FR-005). Read
  distinguishes an absent checkpoint from a corrupt one (FR-006) and never
  fabricates fields. See `specs/002-resume-checkpoint/contracts/checkpoint.md`
  and `specs/007-resume-self-sufficient/contracts/checkpoint.md`.
  """

  alias SpeckitOrchestrator.{Config, RunContext}

  @doc "Best-effort write; always returns `:ok` (FR-008)."
  @spec write(map()) :: :ok
  def write(
        %{
          feature_id: feature_id,
          last_phase: last_phase,
          status: status,
          reason: reason,
          session_id: session_id
        } = input
      ) do
    record =
      %{
        feature_id: feature_id,
        last_phase: Atom.to_string(last_phase),
        status: Atom.to_string(status),
        reason: inspect(reason),
        session_id: session_id,
        slug: Map.get(input, :slug),
        path: Map.get(input, :path)
      }
      |> maybe_put_context(Map.get(input, :run_context))

    dir = Path.join(Config.transcript_root(), feature_id)
    File.mkdir_p!(dir)
    File.write!(checkpoint_path(feature_id), Jason.encode!(record))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Three-way read: record, absent, or corrupt (FR-006)."
  @spec read(String.t()) ::
          {:ok, map()} | {:error, :no_checkpoint} | {:error, :corrupt}
  def read(feature_id) do
    case File.read(checkpoint_path(feature_id)) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = record} -> {:ok, record}
          _ -> {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:error, :no_checkpoint}

      {:error, _} ->
        {:error, :corrupt}
    end
  end

  @doc "Removes the checkpoint if present; a no-op on a missing file (FR-007)."
  @spec delete(String.t()) :: :ok
  def delete(feature_id) do
    File.rm(checkpoint_path(feature_id))
    :ok
  rescue
    _ -> :ok
  end

  defp checkpoint_path(feature_id) do
    Path.join([Config.transcript_root(), feature_id, "checkpoint.json"])
  end

  defp maybe_put_context(record, nil), do: record

  defp maybe_put_context(record, %RunContext{} = run_context),
    do: Map.put(record, :context, RunContext.to_map(run_context))
end
