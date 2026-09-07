defmodule SpeckitOrchestrator.SpecNumber do
  @moduledoc """
  Repo-monotonic spec number allocation — a pure decision surface over
  directory *names*. All IO (listing `specs/` on the base ref) is supplied by
  the caller (`Worktree.spec_dirs/2`).

  Conforming shape: `^(\\d+)-(.+)$` — a leading run of digits, a `-`, and a
  non-empty remainder. Compared numerically, so `"002"` and `"0002"` are the
  same number. See `specs/022-spec-number-split/contracts/spec-number-allocation.md`.
  """

  @type entry :: String.t()

  @conforming ~r/^(\d+)-(.+)$/

  @doc """
  Parse a bare directory name into its leading spec number.

  `"015-billing"` -> `{:ok, 15}`. Non-conforming entries (`"autonomous"`,
  `"015"`, `"015-"`, `"abc-x"`, `""`) -> `:error`.
  """
  @spec parse(entry()) :: {:ok, pos_integer()} | :error
  def parse(entry) when is_binary(entry) do
    case Regex.run(@conforming, entry) do
      [_, digits, _rest] -> {:ok, String.to_integer(digits)}
      nil -> :error
    end
  end

  @doc """
  The highest spec number among conforming entries. `nil` when none conform —
  non-conforming entries are skipped, never raised on (FR-003).
  """
  @spec highest([entry()]) :: pos_integer() | nil
  def highest(entries) when is_list(entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case parse(entry) do
        {:ok, n} -> [n]
        :error -> []
      end
    end)
    |> case do
      [] -> nil
      numbers -> Enum.max(numbers)
    end
  end

  @doc """
  Allocate the next spec number: `(highest(entries) || 0) + 1`. Gaps are never
  filled. Refuses, naming the offending entry, when that number already exists
  in `entries` — unreachable for a well-formed listing, so reaching it is a
  hard error, not a retry-with-next-free-number (FR-003a).
  """
  # The error clause is unreachable from a self-consistent `entries` snapshot:
  # n = highest(entries) + 1, and no member of `entries` can equal
  # highest(entries) + 1 without contradicting `highest` being the maximum.
  # Retained defensively (a stale or damaged listing is the only way in) per
  # contracts/spec-number-allocation.md §1.
  @spec allocate([entry()], String.t()) ::
          {:ok, pos_integer()} | {:error, {:spec_dir_exists, entry()}}
  def allocate(entries, slug) when is_list(entries) and is_binary(slug) do
    n = (highest(entries) || 0) + 1

    case Enum.find(entries, &match?({:ok, ^n}, parse(&1))) do
      nil -> {:ok, n}
      entry -> {:error, {:spec_dir_exists, entry}}
    end
  end

  @doc "Zero-padded `<n>-<slug>` spec directory name."
  @spec dir_name(pos_integer(), String.t()) :: String.t()
  def dir_name(n, slug) when is_integer(n) and is_binary(slug), do: "#{pad(n)}-#{slug}"

  @doc "Zero-padded `feature/<n>-<slug>` branch name."
  @spec branch_name(pos_integer(), String.t()) :: String.t()
  def branch_name(n, slug) when is_integer(n) and is_binary(slug), do: "feature/#{pad(n)}-#{slug}"

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 3, "0")
end
