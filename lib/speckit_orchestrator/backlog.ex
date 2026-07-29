defmodule SpeckitOrchestrator.Backlog do
  @moduledoc """
  Parse a directory of `NNN-slug.md` breakdown files into an ordered list of
  `SpeckitOrchestrator.Feature` structs.

  ## Expected file format

  Files are named `NNN-slug.md` where `NNN` is a numeric id (files not
  matching this pattern — e.g. `README.md` — are ignored). The number is the
  sole ordering input (FR-009, FR-010): features load sorted by `number`
  ascending, all `group: :backlog`. Gaps are legal; a `## Prerequisites`
  section, if present, is inert prose — not read, not validated, not an error.
  The full contract is documented in `docs/breakdown-format.md`.

  Loading **fails loudly** (raises) when two files' numbers are numerically
  equal — e.g. `002-x.md` and `0002-y.md` — naming every conflicting file
  (FR-012).
  """

  alias SpeckitOrchestrator.Feature

  defmodule ParseError do
    @moduledoc "Raised when a breakdown file cannot be parsed into a feature."
    defexception [:message]
  end

  defmodule DuplicateNumberError do
    @moduledoc "Raised when two or more files share the same numeric feature number."
    defexception [:message]
  end

  @file_pattern ~r/^(?<id>\d{3,})-(?<slug>.+)\.md$/

  @doc """
  Load the backlog from `dir`. Returns features sorted by `number` ascending,
  all `group: :backlog`.

  Raises `DuplicateNumberError` when two files' numbers are numerically equal.
  """
  @spec load!(Path.t()) :: [Feature.t()]
  def load!(dir) do
    features =
      dir
      |> list_breakdown_files()
      |> Enum.map(&parse_file!/1)
      |> Enum.sort_by(& &1.number)

    validate_unique_numbers!(features)
    features
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
      number: String.to_integer(captures["id"]),
      slug: captures["slug"],
      path: path,
      group: :backlog,
      created_at: nil,
      status: :pending
    }
  end

  # ---- Validation ---------------------------------------------------------

  @spec validate_unique_numbers!([Feature.t()]) :: :ok
  defp validate_unique_numbers!(features) do
    features
    |> Enum.group_by(& &1.number)
    |> Enum.filter(fn {_number, group} -> length(group) > 1 end)
    |> Enum.sort_by(fn {number, _group} -> number end)
    |> case do
      [] ->
        :ok

      duplicates ->
        message =
          Enum.map_join(duplicates, "; ", fn {number, group} ->
            files = group |> Enum.map(& &1.path) |> Enum.sort()
            "number #{number} appears in #{Enum.join(files, ", ")}"
          end)

        raise DuplicateNumberError, message: "duplicate feature numbers: #{message}"
    end
  end
end
