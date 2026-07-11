defmodule SpeckitOrchestrator.Backlog do
  @moduledoc """
  Parse a directory of `NNN-slug.md` breakdown files into an ordered list of
  `SpeckitOrchestrator.Feature` structs and validate the dependency DAG.

  ## Expected file format

  Files are named `NNN-slug.md` where `NNN` is a zero-padded numeric id (files
  not matching this pattern — e.g. `README.md` — are ignored). Prerequisites are
  declared in a `## Prerequisites` section listing prereq ids, or `None`:

      # 003 — Budgets

      ## Prerequisites

      - 002 Categories

  Any 3+-digit tokens in that section are read as prereq ids; `None` (or an
  empty section, or no section at all) means no prerequisites. The full contract
  is documented in `docs/breakdown-format.md`.

  Loading **fails loudly** (raises) on a prereq referencing an unknown feature
  or on a dependency cycle — invalid backlogs must never reach the runner.
  """

  alias SpeckitOrchestrator.Feature

  defmodule ParseError do
    @moduledoc "Raised when a breakdown file cannot be parsed into a feature."
    defexception [:message]
  end

  defmodule MissingPrereqError do
    @moduledoc "Raised when a feature declares a prereq id that does not exist."
    defexception [:message]
  end

  defmodule CycleError do
    @moduledoc "Raised when the dependency graph contains a cycle."
    defexception [:message]
  end

  @file_pattern ~r/^(?<id>\d{3,})-(?<slug>.+)\.md$/

  @doc """
  Load and validate the backlog from `dir`. Returns features sorted by id.

  Raises `MissingPrereqError` on a dangling prereq and `CycleError` on a cycle.
  """
  @spec load!(Path.t()) :: [Feature.t()]
  def load!(dir) do
    features =
      dir
      |> list_breakdown_files()
      |> Enum.map(&parse_file!/1)
      |> Enum.sort_by(& &1.id)

    validate_prereqs!(features)
    detect_cycles!(features)
    features
  end

  @doc "Map of `feature_id => [ids that depend on it]` (reverse edges)."
  @spec dependents([Feature.t()]) :: %{String.t() => [String.t()]}
  def dependents(features) do
    Enum.reduce(features, %{}, fn f, acc ->
      Enum.reduce(f.prereqs, acc, fn prereq, acc2 ->
        Map.update(acc2, prereq, [f.id], &[f.id | &1])
      end)
    end)
  end

  # ---- Parsing ------------------------------------------------------------

  @spec list_breakdown_files(Path.t()) :: [Path.t()]
  defp list_breakdown_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@file_pattern, &1))
        |> Enum.map(&Path.join(dir, &1))

      {:error, reason} ->
        raise ParseError, message: "cannot read breakdown dir #{inspect(dir)}: #{inspect(reason)}"
    end
  end

  @spec parse_file!(Path.t()) :: Feature.t()
  defp parse_file!(path) do
    captures = Regex.named_captures(@file_pattern, Path.basename(path))

    %Feature{
      id: captures["id"],
      slug: captures["slug"],
      path: path,
      prereqs: path |> File.read!() |> extract_prereqs(),
      status: :pending
    }
  end

  @doc """
  Extract prereq ids from breakdown `content`. Public for golden-file testing of
  the section parser in isolation.
  """
  @spec extract_prereqs(String.t()) :: [String.t()]
  def extract_prereqs(content) do
    content
    |> prerequisites_section()
    |> then(fn section -> Regex.scan(~r/\b\d{3,}\b/, section) end)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  # Return the text of the `## Prerequisites` section (up to the next `##`
  # heading), or "" when there is no such section.
  @spec prerequisites_section(String.t()) :: String.t()
  defp prerequisites_section(content) do
    lines = String.split(content, ["\r\n", "\n"])

    case Enum.find_index(lines, &prereq_heading?/1) do
      nil ->
        ""

      start ->
        lines
        |> Enum.drop(start + 1)
        |> Enum.take_while(fn line -> not heading?(line) end)
        |> Enum.join("\n")
    end
  end

  defp prereq_heading?(line) do
    String.match?(line, ~r/^\s{0,3}#+\s+prerequisites\b/i)
  end

  defp heading?(line), do: String.match?(line, ~r/^\s{0,3}#+\s+\S/)

  # ---- Validation ---------------------------------------------------------

  @spec validate_prereqs!([Feature.t()]) :: :ok
  defp validate_prereqs!(features) do
    ids = MapSet.new(features, & &1.id)

    for f <- features, prereq <- f.prereqs, not MapSet.member?(ids, prereq) do
      raise MissingPrereqError,
        message: "feature #{f.id} (#{f.slug}) requires unknown prereq #{inspect(prereq)}"
    end

    :ok
  end

  # Kahn-style detection: if a topological ordering can't consume every node,
  # the remaining nodes form (or feed) a cycle.
  @spec detect_cycles!([Feature.t()]) :: :ok
  defp detect_cycles!(features) do
    deps = Map.new(features, &{&1.id, &1.prereqs})
    resolved = topo_resolve(Map.keys(deps) |> MapSet.new(), deps, MapSet.new())

    unresolved = MapSet.difference(MapSet.new(Map.keys(deps)), resolved)

    unless MapSet.size(unresolved) == 0 do
      raise CycleError,
        message: "dependency cycle among features #{inspect(Enum.sort(unresolved))}"
    end

    :ok
  end

  # Repeatedly mark features whose every prereq is already resolved, until no
  # progress is made. Anything left is in a cycle.
  @spec topo_resolve(MapSet.t(), %{String.t() => [String.t()]}, MapSet.t()) :: MapSet.t()
  defp topo_resolve(remaining, deps, resolved) do
    newly =
      Enum.filter(remaining, fn id ->
        not MapSet.member?(resolved, id) and
          Enum.all?(deps[id], &MapSet.member?(resolved, &1))
      end)

    case newly do
      [] -> resolved
      _ -> topo_resolve(remaining, deps, MapSet.union(resolved, MapSet.new(newly)))
    end
  end
end
