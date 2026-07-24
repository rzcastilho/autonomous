defmodule SpeckitOrchestrator.RunManifest do
  @moduledoc """
  Single-slot-per-repo durable run record, mirroring `Checkpoint`'s
  conventions: string-keyed JSON, best-effort write, three-way read, never
  fabricates. Partitioned by repository-identity segment at
  `<Config.autonomous_root()>/transcripts/<segment>/run.json` so two target
  repos never share a slot — a stale run for repo A can never resurface while
  viewing repo B (the machine-global `transcripts/run.json` it used to live at
  did exactly that). Owned by the `Coordinator` (via an injected `:manifest`
  seam) — the single writer of run-level state, so writes are race-free without
  new locking. A new `run/1` supersedes the prior manifest **for its own repo**
  by calling `clear/0` (single-slot-per-repo rule, FR-005).

  Segment resolution: `write/1` takes it from the run's `%Layout{}` when present
  (no git call on the Coordinator's per-phase write path — the layout already
  carries it) else resolves `Config.repo()` via `RepoIdentity.resolve/1`;
  `read/0`/`clear/0`/`resumable?/0` resolve `Config.repo()` (one identity read
  on a LiveView mount / resume — infrequent). A repo with no `origin`
  (`{:error, :no_origin}`) has no segment and falls back to the legacy flat
  `transcripts/run.json` — the identity-less bucket, matching pre-012 behavior.
  There is **no** flat-path fallback on a segment-scoped read: an orphaned
  pre-partition `run.json` from an earlier build is simply ignored, not bled
  back into an unrelated repo's view.

  `write/1` also records `segment` and (from a `%Layout{}`) `scope` (`"ad-hoc"`
  or `%{"breakdown" => slug}`) so a resume can rebuild a `%Layout{}`
  (`Layout.build/3`) to reach the scope-partitioned per-feature
  checkpoints/transcripts — see `rebuild_layout/2`/`scope_of/1`.

  See `specs/009-crash-recovery/contracts/run_manifest.md` and
  `specs/012-run-directory-layout/data-model.md` ("RunManifest locality").
  """

  alias SpeckitOrchestrator.{Config, Feature, Layout, RepoIdentity, RunContext}

  @doc "Best-effort write; always returns `:ok` (mirrors `Checkpoint.write/1`)."
  @spec write(map()) :: :ok
  def write(
        %{
          features: features,
          statuses: statuses,
          context: context,
          spend: spend,
          updated_at: updated_at
        } = input
      ) do
    segment = write_segment(input)

    record =
      %{
        "features" => Enum.map(features, &feature_map/1),
        "statuses" =>
          Map.new(statuses, fn {id, status} -> {to_string(id), status_string(status)} end),
        "context" => context_map(context),
        "spend" => spend,
        "updated_at" => updated_at
      }
      |> maybe_put("segment", segment)
      |> maybe_put_scope(Map.get(input, :layout))

    path = manifest_path(segment)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(record, pretty: true))
    :ok
  rescue
    _ -> :ok
  end

  @doc "Three-way read for the current repo's slot: record, absent, or corrupt."
  @spec read() :: {:ok, map()} | {:error, :no_manifest} | {:error, :corrupt}
  def read do
    case File.read(manifest_path(resolved_segment())) do
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

  @doc "Removes the current repo's slot if present; a no-op on a missing file."
  @spec clear() :: :ok
  def clear do
    File.rm(manifest_path(resolved_segment()))
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

  @doc """
  Rebuild the `%Layout{}` a manifest `record` was written under, from its
  recorded `"segment"`/`"scope"` fields (resolves I2). `nil` when the record
  predates this feature (no `"segment"`) or the rebuild fails — callers fall
  back to re-resolving identity fresh, same as pre-012 behavior.
  """
  @spec rebuild_layout(map(), String.t()) :: Layout.t() | nil
  def rebuild_layout(%{"segment" => segment} = record, repo) when is_binary(segment) do
    case Layout.build(repo, segment, scope_of(record)) do
      {:ok, layout} -> layout
      {:error, _reason} -> nil
    end
  end

  def rebuild_layout(_record, _repo), do: nil

  defp scope_of(%{"scope" => %{"breakdown" => slug}}) when is_binary(slug), do: {:breakdown, slug}
  defp scope_of(_record), do: :ad_hoc

  # ---- helpers --------------------------------------------------------------

  # Segment for the write path: prefer the run's %Layout{} (already carries it,
  # so the Coordinator's per-phase write does no git IO), then an explicit
  # `:segment` override (tests), then resolve Config.repo(). `nil` (no origin)
  # → the legacy flat path.
  defp write_segment(input) do
    segment_of_layout(Map.get(input, :layout)) || Map.get(input, :segment) || resolved_segment()
  end

  defp segment_of_layout(%Layout{worktree_root: worktree_root}), do: Path.basename(worktree_root)
  defp segment_of_layout(_), do: nil

  # The one identity read on the read/clear/resumable? path — `Config.repo()`'s
  # `origin`-derived segment, or `nil` for a repo with no usable origin (pre-012
  # / identity-less: falls back to the flat bucket).
  defp resolved_segment do
    case RepoIdentity.resolve(Config.repo()) do
      {:ok, segment} -> segment
      {:error, _reason} -> nil
    end
  end

  defp maybe_put(record, _key, nil), do: record
  defp maybe_put(record, key, value), do: Map.put(record, key, value)

  defp maybe_put_scope(record, %Layout{} = layout),
    do: Map.put(record, "scope", scope_json(layout))

  defp maybe_put_scope(record, _), do: record

  defp scope_json(%Layout{breakdown_root: nil}), do: "ad-hoc"

  defp scope_json(%Layout{in_repo_rel: rel}),
    do: %{"breakdown" => rel |> Path.split() |> List.last()}

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

  # Per-repo slot under the segment dir (`reset-target.sh` wipes it with the
  # rest of the segment's transcripts); `nil` segment → the legacy flat bucket
  # for identity-less repos.
  defp manifest_path(nil),
    do: Path.join([Config.autonomous_root(), "transcripts", "run.json"])

  defp manifest_path(segment) when is_binary(segment),
    do: Path.join([Config.autonomous_root(), "transcripts", segment, "run.json"])
end
