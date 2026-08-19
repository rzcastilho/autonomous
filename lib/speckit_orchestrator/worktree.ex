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
  Collapse the per-phase checkpoint commits made since `base_ref` into one
  commit (FR-004). `git reset --soft base_ref` moves the branch pointer back to
  the fork point while keeping the working tree and index untouched, so the
  post-squash tree is byte-identical to pre-squash `HEAD` — only history
  changes. Returns `:noop` when nothing is staged after the reset (a feature
  that produced no changes beyond `base_ref`), `{:error, term}` on a git
  failure.

  Called on `:done`, replacing the per-phase `Worktree.commit/2` calls with one
  clean terminal commit. Never called on a kept terminal
  (`:escalated`/`:halted`/`:failed`) — the per-phase commits remain as the
  post-mortem trail.

  See `specs/009-crash-recovery/contracts/worktree-squash-restore.md`.
  """
  @spec squash(t(), String.t(), String.t()) :: :ok | :noop | {:error, term()}
  def squash(%__MODULE__{path: path}, base_ref, message) do
    with {:ok, _} <- git(path, ["reset", "--soft", base_ref]) do
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
  end

  @doc """
  Discard any uncommitted output before a resumed phase re-runs (FR-003):
  `git reset --hard HEAD` then `git clean -fd`, returning the worktree to the
  last phase-boundary commit. `clean -fd` respects `.gitignore`, so
  `.speckit_logs/` transcripts (the audit trail) survive.

  See `specs/009-crash-recovery/contracts/worktree-squash-restore.md`.
  """
  @spec restore(t()) :: :ok | {:error, term()}
  def restore(%__MODULE__{path: path}) do
    with {:ok, _} <- git(path, ["reset", "--hard", "HEAD"]),
         {:ok, _} <- git(path, ["clean", "-fd"]) do
      :ok
    end
  end

  @doc """
  Push the feature branch to `remote`, setting upstream (`push -u`). Used by the
  stacked PR workflow after the terminal commit so a PR can be opened against it.
  Runs against the base repo (works whether or not the worktree still exists).

  Every run rebuilds `feature/NNN-slug` from its base, so a *previous* run's
  push of the same feature leaves a remote branch that has diverged from the
  one being pushed now — a plain push is rejected non-fast-forward and the
  publish fails for a feature that built perfectly well. The orchestrator is
  the sole author of these branches, so it replaces its own stale branch —
  but only its own:

    1. Read the remote-tracking sha **before** fetching. This is what the
       orchestrator last knew the remote to be.
    2. `fetch --prune`, so a branch deleted on the remote stops being named by
       a local ref that is pure fiction.
    3. Decide from the two:
       * gone after the prune — the branch isn't on the remote at all, so a
         plain `push -u` creates it.
       * unchanged — the remote is where we left it, so
         `--force-with-lease=<branch>:<sha>` replaces our own stale branch.
       * moved — someone else pushed (a review fixup, a rebase). **Refuse**,
         without pushing. The publish fails loudly rather than overwriting
         work the orchestrator did not author.

  Step 1 is what makes the lease mean anything. `--force-with-lease` with no
  explicit sha compares against the remote-tracking ref, which step 2 has just
  updated to whatever the remote now holds — so a bare lease after a fetch
  always passes and protects nothing.

  A failed fetch is not fatal on its own — an unreachable remote surfaces as
  the push error, which names the actual problem.
  """
  @spec push(t(), String.t()) :: :ok | {:error, term()}
  def push(%__MODULE__{repo: repo, branch: branch}, remote) when is_binary(remote) do
    known = remote_head(repo, remote, branch)
    _ = git(repo, ["fetch", "--prune", remote])

    case {known, remote_head(repo, remote, branch)} do
      {_known, nil} ->
        do_push(repo, remote, branch, [])

      {same, same} ->
        do_push(repo, remote, branch, ["--force-with-lease=#{branch}:#{same}"])

      {_known, moved} ->
        {:error, {:remote_branch_moved, branch, moved}}
    end
  end

  defp do_push(repo, remote, branch, flags) do
    case git(repo, ["push", "-u"] ++ flags ++ [remote, branch]) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp remote_head(repo, remote, branch) do
    case git(repo, ["rev-parse", "--verify", "--quiet", "refs/remotes/#{remote}/#{branch}"]) do
      {:ok, sha} -> sha
      {:error, _} -> nil
    end
  end

  @doc """
  Whether `branch` has already landed in `into` — its tip is an ancestor of
  `into`, so stacking anything else on it would be stacking on merged history.

  Used by the stacked PR workflow to skip merged links when choosing a base
  (`main <- 001 (merged)` means the next feature belongs on `main`, not on
  `feature/001-…`). `into` is resolved against `<remote>/<into>` when that
  remote-tracking ref exists, because the local branch is usually behind
  whatever has actually been merged upstream.

  A branch that no longer exists locally counts as merged: it is gone because
  its PR landed and the branch was deleted, and either way it is not something
  to stack on. `false` on any git failure — the conservative answer, since
  wrongly reporting "merged" silently reparents a PR onto the trunk.
  """
  @spec merged?(Path.t(), String.t(), String.t(), keyword()) :: boolean()
  def merged?(repo, branch, into, opts \\ []) do
    if branch_exists?(repo, branch) do
      target = merge_target(repo, into, Keyword.get(opts, :remote))
      match?({:ok, _}, git(repo, ["merge-base", "--is-ancestor", "refs/heads/#{branch}", target]))
    else
      true
    end
  end

  defp merge_target(_repo, into, nil), do: into

  defp merge_target(repo, into, remote) do
    remote_ref = "refs/remotes/#{remote}/#{into}"

    case git(repo, ["rev-parse", "--verify", "--quiet", remote_ref]) do
      {:ok, _} -> remote_ref
      {:error, _} -> into
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

  @doc """
  The commit this worktree's branch forked from `base` — `git merge-base
  <branch> <base>`, run in the base repo (works whether or not the worktree
  still exists).

  This is the anchor for "what did *this feature* change", and it is stable
  across however many sessions, chunks, retries and resumes produced those
  changes — unlike the worktree's HEAD, which moves with every boundary commit.
  `{:error, {:git_failed, ...}}` when git cannot answer (no such base ref,
  unrelated histories); callers pick their own fallback.
  """
  @spec fork_point(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def fork_point(%__MODULE__{repo: repo, branch: branch}, base) when is_binary(base) do
    git(repo, ["merge-base", branch, base])
  end

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:git_failed, code, String.trim(out)}}
    end
  end
end
