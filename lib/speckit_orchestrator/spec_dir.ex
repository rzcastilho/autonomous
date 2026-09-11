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

  Resolution order, most authoritative first — every candidate is constrained
  to this feature's own **spec id** (`Feature.spec_id/1` semantics: the
  allocated `spec_number` once one exists, else the wave-local `id`):

    1. `specs/<spec_id>-<slug>` — `PhaseRequest` pins `SPECIFY_FEATURE_DIRECTORY`
       to exactly this, matching the `feature/<spec_id>-<slug>` branch name.
    2. `.specify/feature.json`'s `feature_directory` — what the Spec Kit CLI
       itself recorded, accepted only when its basename's numeric prefix
       equals `spec_id`. Unconstrained, this is a live leak: the file is
       committed, so a stacked worktree carries the *previous* feature's
       `feature_directory`, and a plain relative path with no `..` used to be
       accepted regardless of whose feature it named.
    3. `specs/<spec_id>-*` — the numeric prefix is the stable part of the
       name, accepted only on **exactly one** match. Two or more is FR-010
       ambiguity and contributes nothing — never settled by ordering.

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

  defp candidates(worktree_path, %{} = feature) do
    spec_id = spec_id(feature)
    slug = Map.get(feature, :slug)

    [
      slug && Path.join([worktree_path, "specs", "#{spec_id}-#{slug}"]),
      recorded(worktree_path, spec_id)
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(prefix_matches(worktree_path, spec_id))
    |> Enum.uniq()
  end

  # `Feature.spec_id/1` semantics, restated for a plain map: the allocated
  # `spec_number` once one exists, else the wave-local `id`. Kept local
  # (rather than delegating to `Feature`) because every caller here — plan
  # fixtures included — passes a plain map, not always a `%Feature{}`.
  defp spec_id(%{spec_number: n}) when is_integer(n), do: String.pad_leading("#{n}", 3, "0")
  defp spec_id(%{id: id}), do: id

  # The spec dir the Spec Kit CLI recorded for this worktree. Only a plain
  # relative path is honoured — an absolute one, or one climbing out with `..`,
  # resolves outside this worktree and is exactly the cross-feature leak this
  # module exists to stop. Beyond that, the basename's own numeric prefix must
  # equal this feature's `spec_id` — otherwise a stacked worktree's committed
  # `.specify/feature.json` carries the *previous* feature's directory into
  # this one's candidate list.
  defp recorded(worktree_path, spec_id) do
    with {:ok, raw} <- File.read(Path.join(worktree_path, ".specify/feature.json")),
         {:ok, %{"feature_directory" => dir}} when is_binary(dir) <- JSON.decode(raw),
         :relative <- Path.type(dir),
         false <- ".." in Path.split(dir),
         true <- numeric_prefix(Path.basename(dir)) == spec_id do
      Path.join(worktree_path, dir)
    else
      _ -> nil
    end
  end

  defp numeric_prefix(basename) do
    case Regex.run(~r/^(\d+)-/, basename) do
      [_, prefix] -> prefix
      nil -> nil
    end
  end

  # Exactly one match only (FR-010) — two or more is ambiguity, contributing
  # nothing rather than being settled by wildcard/sort ordering.
  defp prefix_matches(worktree_path, spec_id) do
    case worktree_path |> Path.join("specs/#{spec_id}-*") |> Path.wildcard() do
      [single] -> [single]
      _ -> []
    end
  end
end
