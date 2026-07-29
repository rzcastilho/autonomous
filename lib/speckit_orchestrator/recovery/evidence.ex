defmodule SpeckitOrchestrator.Recovery.Evidence do
  @moduledoc """
  Per-feature durable ground truth collector for recovery reconciliation
  (edge I/O — the only place recovery touches git/store/CLI). Every source is
  read independently and defensively: a single absent/corrupt source degrades
  to its unknown value, never a raise (FR-011). Offline-first: no source read
  blocks on the network except the fallback remote query, which tolerates
  unreachability (FR-018). See `specs/014-recovery-reconciliation/contracts/evidence.md`.

  018: the checkpoint, PR-record, and converge-marker signals are sourced
  from the store's per-feature record (`Store.Query.run/1`'s `.features`
  entries) instead of `Checkpoint.read/2`/`Describe.read_pr/2`/a file grep —
  passed in by the caller (`Recovery.plan_run/2`,
  `Recovery.Rebuild.propose/3`) as `feature_record`, `nil` for a feature the
  store never named. Git-sourced signals are unchanged.
  """

  alias SpeckitOrchestrator.{Feature, Pipeline, Store, Worktree}

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

  `feature_record` is this feature's entry from `Store.Query.run/1`'s
  `.features` list (`nil` when the store never named this feature — a fresh
  feature added by a rebuild union, D1).

  `opts`:
    * `:git` — git-read seam (branch existence + boundary-commit log). Default:
      real `Worktree`/`git`; tests inject a fake log.
    * `:remote` — the remote-PR query seam. Default: local-only (returns
      `:unknown`, never touches the network); attempted only when the local PR
      record is absent/corrupt.
  """
  @spec collect(Feature.t(), map() | nil, keyword()) :: t()
  def collect(%Feature{} = feature, feature_record, opts \\ []) do
    git = Keyword.get(opts, :git, &default_git/1)
    remote = Keyword.get(opts, :remote, &default_remote/1)

    %{branch_committed?: branch_committed?, last_boundary_phase: last_boundary_phase} =
      git.(feature)

    pr_record? = pr_recorded?(feature_record)

    %__MODULE__{
      feature_id: feature.id,
      branch_committed?: branch_committed?,
      last_boundary_phase: last_boundary_phase,
      pr_record?: pr_record?,
      pr_remote?: if(pr_record?, do: :unknown, else: safe_remote(remote, feature.id)),
      checkpoint: store_checkpoint(feature_record),
      final_marker?: final_marker?(feature_record)
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

  # ---- store-sourced signals (018) -------------------------------------------

  defp pr_recorded?(%{pr_description: %{} = _pr}), do: true
  defp pr_recorded?(_feature_record), do: false

  defp store_checkpoint(%{checkpoint: %{} = checkpoint}), do: checkpoint
  defp store_checkpoint(_feature_record), do: nil

  @converge_ready_marker ~r/^\#\#[ \t]+CONVERGE:[ \t]+READY[ \t]*$/m

  # The converge attempt's transcript — highest ordinal `phase: :converge`
  # `phase_attempt`, same regex the pre-018 `07-converge.md` file grep used.
  defp final_marker?(%{phase_attempts: attempts}) when is_list(attempts) do
    attempts
    |> Enum.filter(&(&1.phase == :converge))
    |> Enum.max_by(& &1.ordinal, fn -> nil end)
    |> case do
      nil -> false
      %{attempt_id: attempt_id} -> converge_marker?(attempt_id)
    end
  end

  defp final_marker?(_feature_record), do: false

  defp converge_marker?(attempt_id) do
    case Store.transcript(attempt_id) do
      {:ok, %{body: body}} -> Regex.match?(@converge_ready_marker, body)
      _ -> false
    end
  end
end
