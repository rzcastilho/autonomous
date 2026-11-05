defmodule Autonomous.Attachment do
  @moduledoc """
  One entry of a single-spec run's attachment manifest (feature 047).

  Pure. The manifest holds metadata only; the bytes live in the feature branch.
  `original_name` is operator-supplied free text and is shown on Run Detail
  only — prompts, the PR body and every path use `stored_name`.
  """

  alias Autonomous.Feature

  @fields [:original_name, :stored_name, :type, :media_type, :size, :sha256]
  @enforce_keys @fields
  defstruct @fields

  @type type ::
          :png | :jpeg | :gif | :webp | :pdf | :markdown | :text | :csv | :json

  @type t :: %__MODULE__{
          original_name: String.t(),
          stored_name: String.t(),
          type: type(),
          media_type: String.t(),
          size: pos_integer(),
          sha256: String.t()
        }

  @stem_cap 80

  # Extensions the stored name may keep, i.e. the ones Sniff recognises.
  @known_exts ~w(.png .jpg .jpeg .gif .webp .pdf .md .markdown .txt .csv .json)

  @doc "Media type for a detected type."
  @spec media_type(type()) :: String.t()
  def media_type(:png), do: "image/png"
  def media_type(:jpeg), do: "image/jpeg"
  def media_type(:gif), do: "image/gif"
  def media_type(:webp), do: "image/webp"
  def media_type(:pdf), do: "application/pdf"
  def media_type(:markdown), do: "text/markdown"
  def media_type(:text), do: "text/plain"
  def media_type(:csv), do: "text/csv"
  def media_type(:json), do: "application/json"

  @doc """
  Safe, unique stored names for `[{original_name, type}]`, in input order
  (data-model.md naming rules 1–6). Collisions are case-insensitive and get
  `-2`, `-3`, … before the extension.
  """
  @spec stored_names([{String.t(), type()}]) :: [String.t()]
  def stored_names(entries) do
    {names, _seen} =
      Enum.map_reduce(entries, MapSet.new(), fn {original, type}, seen ->
        {stem, ext} = split(original, type)
        name = unique(stem, ext, seen, 1)
        {name, MapSet.put(seen, String.downcase(name))}
      end)

    names
  end

  @doc "Stored name for one entry, without collision handling."
  @spec stored_name(String.t(), type()) :: String.t()
  def stored_name(original, type), do: hd(stored_names([{original, type}]))

  @doc "Repository-relative location of an attachment in its feature's spec directory."
  @spec location(Feature.t(), t()) :: String.t()
  def location(%Feature{} = feature, %__MODULE__{stored_name: name}) do
    "specs/#{Feature.spec_id(feature)}-#{feature.slug}/attachments/#{name}"
  end

  @doc "Directory (relative to the worktree) holding a feature's attachments."
  @spec directory(Feature.t()) :: String.t()
  def directory(%Feature{} = feature),
    do: "specs/#{Feature.spec_id(feature)}-#{feature.slug}/attachments"

  @doc "Human size: `512 B`, `1.2 KB`, `3.4 MB` (decimal units, one decimal)."
  @spec format_size(non_neg_integer()) :: String.t()
  def format_size(bytes) when bytes < 1_000, do: "#{bytes} B"

  def format_size(bytes) when bytes < 1_000_000,
    do: "#{:erlang.float_to_binary(bytes / 1_000, decimals: 1)} KB"

  def format_size(bytes), do: "#{:erlang.float_to_binary(bytes / 1_000_000, decimals: 1)} MB"

  @doc "Manifest entry as the plain map persisted in `speckit_feature_run.attachments`."
  @spec to_record(t()) :: map()
  def to_record(%__MODULE__{} = a), do: Map.from_struct(a)

  @doc "Restore a persisted manifest (`nil` = written before 047 ⇒ `[]`)."
  @spec from_records([map()] | nil) :: [t()]
  def from_records(nil), do: []

  def from_records(list) when is_list(list) do
    Enum.map(list, fn
      %__MODULE__{} = a -> a
      %{} = m -> struct!(__MODULE__, Map.take(m, @fields))
    end)
  end

  # -- naming ----------------------------------------------------------------

  defp split(original, type) do
    last = List.last(String.split(original, ["/", "\\"])) || ""

    cleaned =
      last
      |> String.replace(~r/[^A-Za-z0-9._-]+/u, "-")
      |> collapse_dots()

    {stem, orig_ext} = strip_known_ext(cleaned)
    stem = String.replace(stem, ~r/\A[.\-]+/, "")

    stem =
      stem
      |> binary_part(0, min(byte_size(stem), @stem_cap))
      |> then(fn s -> if s == "", do: "attachment", else: s end)

    {stem, extension(type, orig_ext)}
  end

  defp collapse_dots(s) do
    if String.contains?(s, ".."), do: s |> String.replace("..", ".") |> collapse_dots(), else: s
  end

  defp strip_known_ext(name) do
    lower = String.downcase(name)

    case Enum.find(@known_exts, &String.ends_with?(lower, &1)) do
      nil -> {name, ""}
      ext -> {binary_part(name, 0, byte_size(name) - byte_size(ext)), ext}
    end
  end

  defp extension(:png, _), do: ".png"
  defp extension(:jpeg, _), do: ".jpg"
  defp extension(:gif, _), do: ".gif"
  defp extension(:webp, _), do: ".webp"
  defp extension(:pdf, _), do: ".pdf"
  defp extension(:markdown, ".markdown"), do: ".markdown"
  defp extension(:markdown, _), do: ".md"
  defp extension(:text, _), do: ".txt"
  defp extension(:csv, _), do: ".csv"
  defp extension(:json, _), do: ".json"

  defp unique(stem, ext, seen, 1) do
    candidate = stem <> ext

    if MapSet.member?(seen, String.downcase(candidate)),
      do: unique(stem, ext, seen, 2),
      else: candidate
  end

  defp unique(stem, ext, seen, n) do
    candidate = "#{stem}-#{n}#{ext}"

    if MapSet.member?(seen, String.downcase(candidate)),
      do: unique(stem, ext, seen, n + 1),
      else: candidate
  end
end
