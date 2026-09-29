defmodule Autonomous.Containment do
  @moduledoc """
  Pure helpers for the two containment profiles (`"strict"` / `"permissive"`,
  feature 030).

  `normalize/1` is the only atom -> string boundary (`Atom.to_string/1`);
  every other function in the orchestrator that carries the profile takes and
  returns the string form. `String.to_atom/1` is never used on a stored or
  file-sourced value (repo-wide ban, 017 R4).

  No IO, no CLI, no harness, no Jido.
  """

  @strict "strict"
  @permissive "permissive"
  @profiles [@strict, @permissive]

  @type profile :: String.t()

  @doc """
  Accepts only `:strict`/`:permissive` (atoms) or `"strict"`/`"permissive"`
  (strings). Atom input converts via `Atom.to_string/1`; anything else is
  refused rather than guessed.
  """
  @spec normalize(atom() | String.t()) :: {:ok, profile()} | {:error, {:invalid_containment_profile, term()}}
  def normalize(value) when value in [:strict, :permissive], do: {:ok, Atom.to_string(value)}
  def normalize(value) when value in @profiles, do: {:ok, value}
  def normalize(value), do: {:error, {:invalid_containment_profile, value}}

  @doc "`true` only for the string `\"permissive\"`; `nil` (unset/pre-030) is `false`."
  @spec permissive?(profile() | nil) :: boolean()
  def permissive?(@permissive), do: true
  def permissive?(_), do: false

  @doc """
  Env markers passed through `RunRequest.metadata["claude"][:env]` so the
  target-repo hook can resolve session origin (research R3). Set under every
  profile, including `strict` — an orchestrated session must always be
  distinguishable from a human one.
  """
  @spec session_env(profile()) :: %{String.t() => String.t()}
  def session_env(profile) when profile in @profiles do
    %{"AUTONOMOUS_ORCHESTRATED" => "1", "AUTONOMOUS_CONTAINMENT_PROFILE" => profile}
  end

  @doc "PR body note. Empty string unless `profile == \"permissive\"`."
  @spec pr_note(profile() | nil) :: String.t()
  def pr_note(@permissive) do
    "\n\n---\n**Containment: permissive.** This feature was built with relaxed\n" <>
      "containment: the orchestrator's pack applied no deny list, and every phase\n" <>
      "had full write, Bash and network access. Review side effects outside the\n" <>
      "diff (pushes, network calls, writes outside the worktree) accordingly."
  end

  def pr_note(_profile), do: ""

  @doc "iex status line. `nil` unless `profile == \"permissive\"`."
  @spec report_line(profile() | nil) :: String.t() | nil
  def report_line(@permissive), do: "containment: permissive (no pack deny list)"
  def report_line(_profile), do: nil
end
