defmodule SpeckitOrchestrator.Worktree do
  @moduledoc """
  Per-feature git worktree management.

  Each feature runs in its own `git worktree` on branch `feature/NNN-slug`, so
  concurrent features never share a working directory. The orchestrator owns all
  branching here — **never run `specify init` inside a worktree** (§4.3 of the
  plan): worktrees inherit the committed `.specify/` and `.claude/` trees from
  the base repo, which is the correct behavior. Running `specify init --force`
  would clobber `constitution.md`.

  `create/2` asserts that the committed scaffold (`.specify/`,
  `.claude/settings.json`, `.claude/skills/`) traveled into the worktree; a
  missing scaffold aborts and removes the half-made worktree rather than running
  a feature in an unguarded tree.
  """

  alias SpeckitOrchestrator.{Config, Feature}

  @enforce_keys [:path, :branch, :repo, :feature_id]
  defstruct [:path, :branch, :repo, :feature_id]

  @type t :: %__MODULE__{
          path: String.t(),
          branch: String.t(),
          repo: String.t(),
          feature_id: String.t()
        }

  @scaffold_dirs [".specify", ".claude/skills"]
  @scaffold_files [".claude/settings.json"]

  @doc """
  Create a worktree for `feature`.

  Options:
    * `:repo` — base repo path (default `Config.repo/0`).
    * `:worktree_root` — root for worktrees (default `Config.worktree_root/0`).
    * `:base` — git ref to branch from (default `"HEAD"`).
    * `:require_scaffold` — assert the committed `.specify`/`.claude` scaffold is
      present in the worktree (default `true`).
  """
  @spec create(Feature.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def create(%Feature{} = feature, opts \\ []) do
    %__MODULE__{path: path, branch: branch, repo: repo} = wt = locate(feature, opts)
    root = Path.dirname(path)
    base = Keyword.get(opts, :base, "HEAD")

    with :ok <- ensure_root(root),
         :ok <- git_worktree_add(repo, branch, path, base),
         :ok <- maybe_assert_scaffold(wt, Keyword.get(opts, :require_scaffold, true)) do
      {:ok, wt}
    end
  end

  @doc """
  Compute the `%Worktree{}` for a feature **without** touching git. Used by
  `resolve/1` to find a previously-kept worktree.
  """
  @spec locate(Feature.t(), keyword()) :: t()
  def locate(%Feature{id: id, slug: slug}, opts \\ []) do
    repo = Keyword.get(opts, :repo, Config.repo())
    root = Keyword.get(opts, :worktree_root, Config.worktree_root())

    %__MODULE__{
      path: Path.join(root, "#{id}-#{slug}"),
      branch: "feature/#{id}-#{slug}",
      repo: repo,
      feature_id: id
    }
  end

  @doc "Remove the worktree directory (keeps the branch for later PR review)."
  @spec remove(t()) :: :ok | {:error, term()}
  def remove(%__MODULE__{repo: repo, path: path}) do
    case git(repo, ["worktree", "remove", "--force", path]) do
      {:ok, _} ->
        _ = git(repo, ["worktree", "prune"])
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Leave the worktree in place for post-mortem inspection (non-`:done`
  terminal states). A no-op beyond signalling intent; returns the path.
  """
  @spec keep_for_inspection(t()) :: {:ok, String.t()}
  def keep_for_inspection(%__MODULE__{path: path}), do: {:ok, path}

  @doc """
  Stage and commit everything the pipeline generated in the worktree onto the
  feature branch (`.gitignore` still applies, so transcript logs stay out).

  Called on every terminal state before the worktree is removed (`:done`) or
  kept — otherwise a successful run's generated spec/plan/tasks/code is
  discarded when the worktree is torn down. Uses a dedicated orchestrator author
  so pipeline commits are distinguishable from human resolution commits.

  Returns `:ok` on a commit, `:noop` when there was nothing to commit (a clean
  tree — e.g. a run that produced no file changes), or `{:error, term}`.
  """
  @spec commit(t(), String.t()) :: :ok | :noop | {:error, term()}
  def commit(%__MODULE__{path: path}, message) do
    _ = git(path, ["add", "-A"])

    # `diff --cached --quiet` exits 0 (=> {:ok, _}) when nothing is staged.
    case git(path, ["diff", "--cached", "--quiet"]) do
      {:ok, _} ->
        :noop

      {:error, _} ->
        case git(path, [
               "-c",
               "user.name=speckit-orchestrator",
               "-c",
               "user.email=orchestrator@speckit.local",
               "commit",
               "-m",
               message
             ]) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Push the feature branch to `remote`, setting upstream (`push -u`). Used by the
  stacked PR workflow after the terminal commit so a PR can be opened against it.
  Runs against the base repo (works whether or not the worktree still exists).
  """
  @spec push(t(), String.t()) :: :ok | {:error, term()}
  def push(%__MODULE__{repo: repo, branch: branch}, remote) when is_binary(remote) do
    case git(repo, ["push", "-u", remote, branch]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # ---- git plumbing -------------------------------------------------------

  defp ensure_root(root) do
    case File.mkdir_p(root) do
      :ok -> :ok
      {:error, reason} -> {:error, {:worktree_root, reason}}
    end
  end

  # Reuse an existing branch (e.g. after `resolve/1` freed its worktree, keeping
  # the human's committed clarifications on the branch); otherwise create it.
  defp git_worktree_add(repo, branch, path, base) do
    args =
      if branch_exists?(repo, branch),
        do: ["worktree", "add", path, branch],
        else: ["worktree", "add", "-b", branch, path, base]

    case git(repo, args) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:worktree_add, reason}}
    end
  end

  defp branch_exists?(repo, branch) do
    match?({:ok, _}, git(repo, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"]))
  end

  defp maybe_assert_scaffold(_wt, false), do: :ok

  defp maybe_assert_scaffold(%__MODULE__{path: path} = wt, true) do
    missing =
      Enum.reject(@scaffold_dirs, &File.dir?(Path.join(path, &1))) ++
        Enum.reject(@scaffold_files, &File.regular?(Path.join(path, &1)))

    case missing do
      [] ->
        :ok

      _ ->
        # Don't run a feature in an unguarded tree: tear it down and fail loudly.
        _ = remove(wt)
        {:error, {:missing_scaffold, missing}}
    end
  end

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:git_failed, code, String.trim(out)}}
    end
  end
end
