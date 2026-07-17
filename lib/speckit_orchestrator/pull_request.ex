defmodule SpeckitOrchestrator.PullRequest do
  @moduledoc """
  Opens a GitHub pull request for a completed feature branch via the
  authenticated `gh` CLI.

  Used by the stacked sequential PR workflow: after a feature reaches `:done` and
  its branch is pushed, a PR is opened with `--head <feature branch>` and
  `--base <stack base>` (the previous feature's branch, or `pr_base` for the
  first). `gh` infers the repository from the target repo's `origin` remote, so
  it is run with `cd: repo`.

  Like all `Worktree` git, this is a direct `System.cmd` and therefore bypasses
  the target repo's PreToolUse scope-guard (which only gates agent-issued CLI
  actions inside the Claude run).

  The facade injects `open/2` as a `:publisher` seam so tests do not shell out to
  `gh`; `build_args/1` is pure and unit-tested for the argv.
  """

  @typedoc "PR spec: head branch, base branch, title, body."
  @type spec :: %{
          required(:head) => String.t(),
          required(:base) => String.t(),
          required(:title) => String.t(),
          required(:body) => String.t()
        }

  @doc "Open a PR for `spec` in `repo` (its `origin` names the GitHub repository)."
  @spec open(Path.t(), spec()) :: {:ok, String.t()} | {:error, term()}
  def open(repo, %{} = spec) do
    case System.cmd("gh", build_args(spec), cd: repo, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:gh_failed, code, String.trim(out)}}
    end
  end

  @doc "Pure builder for the `gh pr create` argv (excludes the `gh` program itself)."
  @spec build_args(spec()) :: [String.t()]
  def build_args(%{head: head, base: base, title: title, body: body}) do
    [
      "pr",
      "create",
      "--head",
      head,
      "--base",
      base,
      "--title",
      title,
      "--body",
      body
    ]
  end
end
