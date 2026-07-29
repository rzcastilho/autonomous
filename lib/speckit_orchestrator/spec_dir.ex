defmodule SpeckitOrchestrator.SpecDir do
  @moduledoc """
  Resolves **which `specs/` directory belongs to the feature being built**.

  A stacked run's worktree branches from the previous feature's branch, so it
  carries every earlier feature's `specs/<id>-<slug>/` directory as well as its
  own. Any `specs/**/…` glob therefore resolves across features, and because
  `Path.wildcard/1` sorts, "the first match" is reliably the *oldest* feature —
  the one that finished long ago. Every gate that reads a file to decide
  something about the current feature has to resolve the directory first:

    * the task plan (`TaskPlan.load/2`) — reading feature 001's completed
      `tasks.md` made the chunk loop skip every task-phase
    * the plan/tasks artifact gates — a prior feature's `plan.md` satisfies a
      gate meant to prove *this* feature produced one
    * the clarify `## NEEDS HUMAN` scan — a marker left in a prior feature's
      `spec.md` escalates a feature that is perfectly clean

  Resolution order, most authoritative first:

    1. `specs/<id>-<slug>` — `PhaseRequest` pins `SPECIFY_FEATURE_DIRECTORY` to
       exactly this, matching the `feature/<id>-<slug>` branch name.
    2. `.specify/feature.json`'s `feature_directory` — what the Spec Kit CLI
       itself recorded, which covers a run whose slug drifted from the branch.
    3. `specs/<id>-*` — the numeric id prefix is the stable part of the name.

  Callers decide what an unresolvable directory means, because the safe
  direction differs: for an artifact gate it is "missing" (fail loud), for the
  clarify scan it is "no marker" (do not escalate on a file we cannot
  identify). What it must never mean is "use another feature's file".
  """

  @doc """
  The feature's spec directory, or `nil` when none of the candidates exist.

  `feature` needs only `:id` and (optionally) `:slug`, so a plain map works as
  well as a `Feature` struct.
  """
  @spec resolve(Path.t() | nil, map() | nil) :: Path.t() | nil
  def resolve(worktree_path, feature)

  def resolve(nil, _feature), do: nil
  def resolve(_worktree_path, nil), do: nil

  def resolve(worktree_path, %{id: id} = feature)
      when is_binary(worktree_path) and is_binary(id) do
    Enum.find(candidates(worktree_path, feature), &File.dir?/1)
  rescue
    _ -> nil
  end

  def resolve(_worktree_path, _feature), do: nil

  @doc """
  The path to `leaf` inside the feature's spec directory, or `nil` when no
  candidate directory holds it.

  Checked per candidate rather than by resolving the directory first: a slug
  drift can leave `specs/<id>-<slug>/` present but empty while the directory the
  CLI actually wrote to holds the file.
  """
  @spec file(Path.t() | nil, map() | nil, String.t()) :: Path.t() | nil
  def file(worktree_path, feature, leaf)

  def file(nil, _feature, _leaf), do: nil
  def file(_worktree_path, nil, _leaf), do: nil

  def file(worktree_path, %{id: id} = feature, leaf)
      when is_binary(worktree_path) and is_binary(id) do
    worktree_path
    |> candidates(feature)
    |> Enum.map(&Path.join(&1, leaf))
    |> Enum.find(&File.regular?/1)
  rescue
    _ -> nil
  end

  def file(_worktree_path, _feature, _leaf), do: nil

  defp candidates(worktree_path, %{id: id} = feature) do
    slug = Map.get(feature, :slug)

    [
      slug && Path.join([worktree_path, "specs", "#{id}-#{slug}"]),
      recorded(worktree_path)
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(prefix_matches(worktree_path, id))
    |> Enum.uniq()
  end

  # The spec dir the Spec Kit CLI recorded for this worktree. Only a plain
  # relative path is honoured — an absolute one, or one climbing out with `..`,
  # resolves outside this worktree and is exactly the cross-feature leak this
  # module exists to stop.
  defp recorded(worktree_path) do
    with {:ok, raw} <- File.read(Path.join(worktree_path, ".specify/feature.json")),
         {:ok, %{"feature_directory" => dir}} when is_binary(dir) <- JSON.decode(raw),
         :relative <- Path.type(dir),
         false <- ".." in Path.split(dir) do
      Path.join(worktree_path, dir)
    else
      _ -> nil
    end
  end

  defp prefix_matches(worktree_path, id),
    do: worktree_path |> Path.join("specs/#{id}-*") |> Path.wildcard()
end
