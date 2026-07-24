defmodule SpeckitOrchestrator.Recovery.Evidence do
  @moduledoc """
  Per-feature durable ground truth collector for recovery reconciliation
  (edge I/O — the only place recovery touches git/file/CLI). Every source is
  read independently and defensively: a single absent/corrupt source degrades
  to its unknown value, never a raise (FR-011). Offline-first: no source read
  blocks on the network except the fallback remote query, which tolerates
  unreachability (FR-018). See `specs/014-recovery-reconciliation/contracts/evidence.md`.
  """

  alias SpeckitOrchestrator.{Checkpoint, Config, Describe, Feature, Layout, Pipeline, Worktree}

  @enforce_keys [:feature_id]
  defstruct feature_id: nil,
            branch_committed?: false,
            last_boundary_phase: nil,
            pr_record?: false,
            pr_remote?: :unknown,
            checkpoint: nil,
            final_marker?: false

  @type t :: %__MODULE__{
          feature_id: String.t(),
          branch_committed?: boolean(),
          last_boundary_phase: Pipeline.phase() | nil,
          pr_record?: boolean(),
          pr_remote?: boolean() | :unknown,
          checkpoint: map() | nil,
          final_marker?: boolean()
        }

  @type git_result :: %{branch_committed?: boolean(), last_boundary_phase: Pipeline.phase() | nil}
  @type git_seam :: (Feature.t() -> git_result())
  @type remote_seam :: (String.t() -> boolean() | :unknown)

  @doc """
  Gather the durable `%Evidence{}` for `feature` per contracts/evidence.md.

  `opts`:
    * `:git` — git-read seam (branch existence + boundary-commit log). Default:
      real `Worktree`/`git`; tests inject a fake log.
    * `:remote` — the remote-PR query seam. Default: local-only (returns
      `:unknown`, never touches the network); attempted only when the local PR
      record is absent/corrupt.
  """
  @spec collect(Feature.t(), Layout.t() | nil, keyword()) :: t()
  def collect(%Feature{} = feature, layout, opts \\ []) do
    git = Keyword.get(opts, :git, &default_git/1)
    remote = Keyword.get(opts, :remote, &default_remote/1)

    %{branch_committed?: branch_committed?, last_boundary_phase: last_boundary_phase} =
      git.(feature)

    pr_record? = match?({:ok, _}, Describe.read_pr(feature.id, layout))

    %__MODULE__{
      feature_id: feature.id,
      branch_committed?: branch_committed?,
      last_boundary_phase: last_boundary_phase,
      pr_record?: pr_record?,
      pr_remote?: if(pr_record?, do: :unknown, else: safe_remote(remote, feature.id)),
      checkpoint: read_checkpoint(feature.id, layout),
      final_marker?: final_marker?(feature.id, layout)
    }
  end

  # ---- default :git seam ---------------------------------------------------
  #
  # Boundary-commit parse (FR-005 authority): match ONLY the per-phase
  # boundary subject `"speckit: <id> checkpoint after <phase>"` (written by
  # `FeatureRunner` at each `{:cont, next}`). The `:done` squash subject
  # (`"speckit: feature <id> pipeline artifacts (...)"`) and other terminal
  # commits use a different shape and MUST NOT be parsed as a boundary.

  @boundary_re ~r/^speckit: (?<id>\S+) checkpoint after (?<phase>\w+)$/

  @doc false
  @spec default_git(Feature.t()) :: git_result()
  def default_git(%Feature{} = feature) do
    %Worktree{repo: repo, branch: branch} = Worktree.locate(feature)

    if branch_exists?(repo, branch) do
      %{
        branch_committed?: true,
        last_boundary_phase: newest_boundary_phase(repo, branch, feature.id)
      }
    else
      %{branch_committed?: false, last_boundary_phase: nil}
    end
  end

  defp branch_exists?(repo, branch) do
    match?({:ok, _}, git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  defp newest_boundary_phase(repo, branch, feature_id) do
    case git(repo, ["log", branch, "--format=%s"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.find_value(&parse_boundary(&1, feature_id))

      {:error, _} ->
        nil
    end
  end

  defp parse_boundary(subject, feature_id) do
    with %{"id" => ^feature_id, "phase" => phase} <- Regex.named_captures(@boundary_re, subject),
         {:ok, parsed} <- Pipeline.parse(phase) do
      parsed
    else
      _ -> nil
    end
  end

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:git_failed, code, String.trim(out)}}
    end
  rescue
    _ -> {:error, :git_unavailable}
  end

  # ---- default :remote seam ------------------------------------------------
  #
  # Hermetic default: never touches the network, always :unknown. A real `gh`
  # probe is injected in production only when the local pr.json is absent.

  @doc false
  @spec default_remote(String.t()) :: :unknown
  def default_remote(_feature_id), do: :unknown

  # Attempted at most once, only when pr_record? is false; any failure — raise,
  # throw, exit, or an unrecognized return — maps to :unknown, never crashes
  # collection (FR-018, SC-009).
  defp safe_remote(remote, feature_id) do
    case remote.(feature_id) do
      result when is_boolean(result) -> result
      :unknown -> :unknown
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  # ---- checkpoint -----------------------------------------------------------

  defp read_checkpoint(feature_id, layout) do
    case Checkpoint.read(feature_id, layout) do
      {:ok, record} -> record
      _ -> nil
    end
  end

  # ---- final marker (non-PR done-signal) -------------------------------------

  @converge_ready_marker ~r/^\#\#[ \t]+CONVERGE:[ \t]+READY[ \t]*$/m

  defp final_marker?(feature_id, layout) do
    path = Path.join([durable_root(layout), feature_id, "07-converge.md"])

    case File.read(path) do
      {:ok, contents} -> Regex.match?(@converge_ready_marker, contents)
      {:error, _} -> false
    end
  end

  defp durable_root(nil), do: Config.transcript_root()
  defp durable_root(%Layout{transcript_root: root}), do: root
end
