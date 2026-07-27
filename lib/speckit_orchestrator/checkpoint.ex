defmodule SpeckitOrchestrator.Checkpoint do
  @moduledoc """
  Durable per-feature resume pointer.

  Records the phase a feature reached when it terminated at a non-`:done`
  status (`:escalated` / `:halted` / `:failed`), the terminal status, reason,
  session id, the feature's identity (`slug`/`path`, so `resume/2` can
  rebuild the work-unit from the id alone — FR-001), and the run-shaping
  context (`RunContext`) captured at run start, so a resume re-executes under
  the original run shape (FR-006) — one JSON file at
  `<feature_id>/checkpoint.json` under the run's `%Layout{}.transcript_root`
  (scope-keyed — FR-011); `layout: nil` (tests, non-012 callers) falls back to
  the pre-012 flat `Config.transcript_root/0`. Write is best-effort (a failure
  never breaks the run — FR-008); a `:done` terminal deletes any existing
  checkpoint instead of writing one (FR-005). Read distinguishes an absent
  checkpoint from a corrupt one (FR-006) and never fabricates fields. Also
  written after **every** successful phase (not only on a terminal divert)
  with `status: :in_progress` and `last_phase:` the phase that just completed,
  so a crash mid-run always has a fresh restore point (FR-002). Gains one more
  optional key, `implement_chunk` — the durable chunk position (ordinal/
  number/title/total/sessions_used/ceiling/scope) written at each task-phase
  boundary and on the implement step's terminal outcome (FR-020), same
  `maybe_put_*`-omit-when-absent pattern as `:context`, so a pre-015
  checkpoint (no key) still reads and resolves via the `:fallback` rule. Gains
  one more optional key, `analyze_remediation` — the auto-remediation loop's
  per-run provenance (`attempts_used`/`limit`/`threshold`/`enabled`), same
  omit-when-absent shape, absent when no attempt ran and never read back as a
  spent budget (FR-012b/FR-015: every new feature run starts at zero). See
  `specs/002-resume-checkpoint/contracts/checkpoint.md`,
  `specs/007-resume-self-sufficient/contracts/checkpoint.md`,
  `specs/009-crash-recovery/contracts/checkpoint-progress.md`,
  `specs/012-run-directory-layout/contracts/layout.md`, and
  `specs/015-implement-phase-chunking/contracts/checkpoint-implement-chunk.md`,
  and `specs/017-analyze-auto-remediation/contracts/checkpoint-analyze-remediation.md`.
  """

  alias SpeckitOrchestrator.{Config, Layout, RunContext}

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
      |> maybe_put_implement_chunk(Map.get(input, :implement_chunk))
      |> maybe_put_analyze_remediation(Map.get(input, :analyze_remediation))

    path = checkpoint_path(feature_id, Map.get(input, :layout))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(record, pretty: true))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Three-way read: record, absent, or corrupt (FR-006)."
  @spec read(String.t(), Layout.t() | nil) ::
          {:ok, map()} | {:error, :no_checkpoint} | {:error, :corrupt}
  def read(feature_id, layout \\ nil) do
    case File.read(checkpoint_path(feature_id, layout)) do
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
  @spec delete(String.t(), Layout.t() | nil) :: :ok
  def delete(feature_id, layout \\ nil) do
    File.rm(checkpoint_path(feature_id, layout))
    :ok
  rescue
    _ -> :ok
  end

  defp checkpoint_path(feature_id, nil) do
    Path.join([Config.transcript_root(), feature_id, "checkpoint.json"])
  end

  defp checkpoint_path(feature_id, %Layout{transcript_root: root}) do
    Path.join([root, feature_id, "checkpoint.json"])
  end

  defp maybe_put_context(record, nil), do: record

  defp maybe_put_context(record, %RunContext{} = run_context),
    do: Map.put(record, :context, RunContext.to_map(run_context))

  defp maybe_put_implement_chunk(record, nil), do: record

  defp maybe_put_implement_chunk(record, %{} = implement_chunk),
    do: Map.put(record, :implement_chunk, implement_chunk)

  defp maybe_put_analyze_remediation(record, nil), do: record

  defp maybe_put_analyze_remediation(record, %{} = analyze_remediation),
    do: Map.put(record, :analyze_remediation, analyze_remediation)
end
