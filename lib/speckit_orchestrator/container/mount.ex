defmodule SpeckitOrchestrator.Container.Mount do
  @moduledoc """
  A parsed `/proc/self/mountinfo` line, used only to answer "is this path a
  mount point?" for the `:run_state_durable` preflight check (FR-023,
  research.md §R10, `data-model.md` §5).

  Pure: `mount_point?/2` takes the file's *contents* (a string), not a path to
  read — the IO boundary (`File.read!("/proc/self/mountinfo")`) lives in
  `Preflight.collect/1`. This is what lets the hermetic suite exercise a
  tmpfs-`$HOME`-with-nested-bind fixture with no container.
  """

  @enforce_keys [:mount_point, :fs_type, :options]
  defstruct [:mount_point, :fs_type, :options]

  @type t :: %__MODULE__{
          mount_point: String.t(),
          fs_type: String.t(),
          options: [String.t()]
        }

  @doc """
  Parse `/proc/self/mountinfo`-shaped text into a list of `t()`. Each line has
  a variable number of optional fields before a lone `-` separator
  (`man 5 proc`); lines that don't match the shape are skipped rather than
  raising, since a malformed line here is a kernel-format surprise, not a
  recoverable configuration error.
  """
  @spec parse(String.t()) :: [t()]
  def parse(mountinfo_contents) when is_binary(mountinfo_contents) do
    mountinfo_contents
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Does `path` appear as its own mount point in `mountinfo_contents`? Exact
  match (trailing-slash-normalized) against field 5 — the nested-mount shape
  (a tmpfs `$HOME` with a bind mounted at `$HOME/.autonomous`) is distinguished
  correctly because the bind gets its own mountinfo entry at that exact path.
  """
  @spec mount_point?(String.t(), String.t()) :: boolean()
  def mount_point?(mountinfo_contents, path) when is_binary(mountinfo_contents) do
    normalized = normalize(path)

    mountinfo_contents
    |> parse()
    |> Enum.any?(fn mount -> normalize(mount.mount_point) == normalized end)
  end

  defp parse_line(line) do
    fields = String.split(line, " ", trim: true)

    case Enum.split_while(fields, &(&1 != "-")) do
      {pre, ["-", fs_type | _rest]} when length(pre) >= 6 ->
        %__MODULE__{
          mount_point: Enum.at(pre, 4),
          fs_type: fs_type,
          options: Enum.at(pre, 5) |> String.split(",", trim: true)
        }

      _ ->
        nil
    end
  end

  defp normalize(path), do: String.trim_trailing(path, "/")
end
