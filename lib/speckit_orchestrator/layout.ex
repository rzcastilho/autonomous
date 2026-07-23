defmodule SpeckitOrchestrator.Layout do
  @moduledoc """
  The single resolution surface for the four run roots (FR-011): worktree,
  transcript, breakdown, and ad-hoc. Built once per run at the IO boundary from
  `(repo, segment, scope)`; every field is a pure path join given those inputs
  (Constitution I). See `specs/012-run-directory-layout/contracts/layout.md`.

  `worktree_root`/`transcript_root` are machine-global absolute paths under
  `Config.autonomous_root/0`. `breakdown_root`/`ad_hoc_root` are base-repo
  absolute — for load/inspection only (`Backlog.load!/1`, read-only LiveViews).
  Phase execution and the ad-hoc seed write use `in_repo_rel/1` instead, joined
  onto the **worktree** (`cwd` at phase-run time), never the base repo.
  """

  alias SpeckitOrchestrator.Config

  @enforce_keys [:worktree_root, :transcript_root, :in_repo_rel]
  defstruct [:worktree_root, :transcript_root, :breakdown_root, :ad_hoc_root, :in_repo_rel]

  @type scope :: {:breakdown, String.t()} | :ad_hoc

  @type t :: %__MODULE__{
          worktree_root: String.t(),
          transcript_root: String.t(),
          breakdown_root: String.t() | nil,
          ad_hoc_root: String.t() | nil,
          in_repo_rel: String.t()
        }

  @reserved_slug "ad-hoc"

  @doc """
  Resolve the four roots for `repo` under repository-identity `segment` and run
  `scope`. `{:error, {:reserved_slug, "ad-hoc"}}` for a breakdown package
  literally named `"ad-hoc"` (would collide with the ad-hoc transcript
  segment); `{:error, {:home_unavailable, reason}}` when `Config.autonomous_root/0`
  can't be resolved — never falls back to a repo-internal path.
  """
  @spec build(String.t(), String.t(), scope()) :: {:ok, t()} | {:error, term()}
  def build(repo, segment, scope) when is_binary(repo) and is_binary(segment) do
    with :ok <- check_reserved(scope),
         {:ok, autonomous_root} <- resolve_autonomous_root() do
      {:ok, do_build(repo, segment, scope, autonomous_root)}
    end
  end

  @doc """
  The repo-relative in-repo suffix for `layout`'s scope (or a bare `scope`
  value) — `"specs/autonomous/breakdown/<slug>"` or `"specs/autonomous/ad-hoc"`
  — for joining onto the **worktree** (`PhaseRequest.breakdown_ref/2`, the
  ad-hoc seed write), never the base-repo-absolute `breakdown_root`/`ad_hoc_root`.
  """
  @spec in_repo_rel(t() | scope()) :: String.t()
  def in_repo_rel(%__MODULE__{in_repo_rel: rel}), do: rel
  def in_repo_rel({:breakdown, slug}), do: breakdown_rel(slug)
  def in_repo_rel(:ad_hoc), do: ad_hoc_rel()

  @doc """
  Create any missing directory among `layout`'s **machine-global** roots
  (`worktree_root`, `transcript_root` — FR-009); `mkdir -p` only — never
  deletes or overwrites an existing sibling run's directory. Fail loud on a
  create failure (FR-010).

  Deliberately does **not** create `breakdown_root`/`ad_hoc_root`: they are
  base-repo, load/inspection-only roots (see `in_repo_rel/1`). A breakdown
  package is a pre-committed input — auto-creating an empty dir for a
  misconfigured/missing slug would turn a loud `Backlog.load!/1` failure into
  a silent empty backlog. The ad-hoc seed creates its own (worktree-relative)
  parent directory on write.
  """
  @spec ensure(t()) :: :ok | {:error, {:mkdir, String.t(), term()}}
  def ensure(%__MODULE__{} = layout) do
    layout
    |> roots()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.mkdir_p(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:mkdir, path, reason}}}
      end
    end)
  end

  # ---- internals ------------------------------------------------------------

  defp check_reserved({:breakdown, @reserved_slug}),
    do: {:error, {:reserved_slug, @reserved_slug}}

  defp check_reserved(_scope), do: :ok

  defp resolve_autonomous_root do
    {:ok, Config.autonomous_root()}
  rescue
    reason -> {:error, {:home_unavailable, reason}}
  end

  defp do_build(repo, segment, {:breakdown, slug}, autonomous_root) do
    rel = breakdown_rel(slug)

    %__MODULE__{
      worktree_root: Path.join([autonomous_root, "worktrees", segment]),
      transcript_root: Path.join([autonomous_root, "transcripts", segment, slug]),
      breakdown_root: Path.join(repo, rel),
      ad_hoc_root: nil,
      in_repo_rel: rel
    }
  end

  defp do_build(repo, segment, :ad_hoc, autonomous_root) do
    rel = ad_hoc_rel()

    %__MODULE__{
      worktree_root: Path.join([autonomous_root, "worktrees", segment]),
      transcript_root: Path.join([autonomous_root, "transcripts", segment, @reserved_slug]),
      breakdown_root: nil,
      ad_hoc_root: Path.join(repo, rel),
      in_repo_rel: rel
    }
  end

  defp breakdown_rel(slug), do: Path.join([Config.specs_root(), "breakdown", slug])
  defp ad_hoc_rel, do: Path.join(Config.specs_root(), @reserved_slug)

  defp roots(%__MODULE__{} = layout), do: [layout.worktree_root, layout.transcript_root]
end
