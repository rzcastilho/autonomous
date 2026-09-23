defmodule SpeckitOrchestrator.PublishOutcome do
  @moduledoc """
  Pure, human-facing rendering of publish-failure and branch-drift terminal
  reasons (027, contracts/operator-surfaces.md).

  Every string here uses real identifiers — the tag atoms as typed, branch
  names, and the actual `git`/`gh` invocation an operator could paste back —
  per constitution Principle VII (the UI speaks the system's vocabulary).
  `describe/1` is the single place this vocabulary is spelled out; every
  console surface and `Report.format_reason/1` call it before falling back to
  `inspect/1`.
  """

  @doc """
  Renders a known reason to its exact operator-facing string; `nil` for
  anything else, so callers fall back to their own rendering (`inspect/1`).
  Verbatim tool `output` is carried unmodified, on its own line — never
  truncated or reformatted (SC-002).
  """
  @spec describe(term()) :: String.t() | nil
  def describe({:publish_failed, :empty_branch, detail}) do
    %{branch: branch, base: base, branch_sha: branch_sha, base_sha: base_sha} = detail

    "publish_failed :empty_branch — #{branch} has no commits beyond #{base} (#{branch_sha} = #{base_sha})"
  end

  def describe({:publish_failed, :push_failed, detail}) do
    %{branch: branch, remote: remote, output: output} = detail
    "publish_failed :push_failed — git push #{remote} #{branch}:\n#{output}"
  end

  def describe({:publish_failed, :pr_failed, detail}) do
    %{branch: branch, base: base, exit: exit_code, output: output} = detail

    "publish_failed :pr_failed — gh pr create --head #{branch} --base #{base} (exit #{exit_code}):\n#{output}"
  end

  def describe({:branch_drift, phase, %{expected: expected, observed: observed}}) do
    "branch_drift in :#{phase} — expected #{expected}, HEAD on #{render_observed(observed)}"
  end

  def describe(_other), do: nil

  defp render_observed({:detached, sha}), do: "detached@#{sha}"
  defp render_observed(branch) when is_binary(branch), do: branch
end
