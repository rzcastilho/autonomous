defmodule SpeckitOrchestrator.RunManifest do
  @moduledoc """
  Single-slot durable run record, mirroring `Checkpoint`'s conventions:
  string-keyed JSON, best-effort write, three-way read, never fabricates. One
  file at `<Config.transcript_root()>/run.json`. Owned by the `Coordinator`
  (via an injected `:manifest` seam) — the single writer of run-level state,
  so writes are race-free without new locking. A new `run/1` supersedes the
  prior manifest by calling `clear/0` (single-slot rule, FR-005).

  See `specs/009-crash-recovery/contracts/run_manifest.md`.
  """

  alias SpeckitOrchestrator.{Config, Feature, RunContext}

  @doc "Best-effort write; always returns `:ok` (mirrors `Checkpoint.write/1`)."
  @spec write(map()) :: :ok
  def write(%{
        features: features,
        statuses: statuses,
        context: context,
        spend: spend,
        updated_at: updated_at
      }) do
    record = %{
      "features" => Enum.map(features, &feature_map/1),
      "statuses" => Map.new(statuses, fn {id, status} -> {to_string(id), status_string(status)} end),
      "context" => context_map(context),
      "spend" => spend,
      "updated_at" => updated_at
    }

    File.mkdir_p!(Config.transcript_root())
    File.write!(manifest_path(), Jason.encode!(record))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Three-way read: record, absent, or corrupt."
  @spec read() :: {:ok, map()} | {:error, :no_manifest} | {:error, :corrupt}
  def read do
    case File.read(manifest_path()) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = record} -> {:ok, record}
          _ -> {:error, :corrupt}
        end

      {:error, :enoent} ->
        {:error, :no_manifest}

      {:error, _} ->
        {:error, :corrupt}
    end
  end

  @doc "Removes the slot if present; a no-op on a missing file."
  @spec clear() :: :ok
  def clear do
    File.rm(manifest_path())
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  True when the manifest holds at least one non-terminal-and-final feature
  status — a `"running"` (interrupted) or `"pending"` (never released)
  feature. Pure classification; starts no work (FR-008, SC-006).
  """
  @spec resumable?() :: boolean()
  def resumable? do
    case read() do
      {:ok, %{"statuses" => statuses}} when is_map(statuses) ->
        Enum.any?(statuses, fn {_id, status} -> status in ["running", "pending"] end)

      _ ->
        false
    end
  end

  @doc """
  From a read record, rebuild the `%Feature{}` list and the seed `statuses`
  map for the `Coordinator`, applying the crash→resume mapping (data-model
  State transitions table): terminal statuses kept as-is; `"running"`/
  `"pending"` → `:pending`.
  """
  @spec reconstruct(map()) :: {[Feature.t()], %{String.t() => Feature.status()}}
  def reconstruct(%{"features" => features, "statuses" => statuses}) do
    feature_structs = Enum.map(features, &to_feature/1)
    reconstructed = Map.new(statuses, fn {id, status} -> {id, reconstruct_status(status)} end)

    {feature_structs, reconstructed}
  end

  # ---- helpers --------------------------------------------------------------

  defp feature_map(%Feature{id: id, slug: slug, path: path, prereqs: prereqs}) do
    %{"id" => id, "slug" => slug, "path" => path, "prereqs" => prereqs}
  end

  defp to_feature(%{"id" => id, "slug" => slug, "path" => path} = map) do
    %Feature{id: id, slug: slug, path: path, prereqs: Map.get(map, "prereqs", [])}
  end

  defp status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_string(status) when is_binary(status), do: status

  defp context_map(%RunContext{} = ctx), do: RunContext.to_map(ctx)
  defp context_map(map) when is_map(map), do: map
  defp context_map(_), do: %{}

  # Explicit mapping over the fixed, known status vocabulary — never
  # `String.to_atom/1` on file-sourced content (atom-table safety).
  defp reconstruct_status("done"), do: :done
  defp reconstruct_status("escalated"), do: :escalated
  defp reconstruct_status("halted"), do: :halted
  defp reconstruct_status("failed"), do: :failed
  defp reconstruct_status("running"), do: :pending
  defp reconstruct_status("pending"), do: :pending
  defp reconstruct_status(_other), do: :pending

  defp manifest_path, do: Path.join(Config.transcript_root(), "run.json")
end
