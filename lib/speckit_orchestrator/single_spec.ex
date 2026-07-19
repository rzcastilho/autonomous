defmodule SpeckitOrchestrator.SingleSpec do
  @moduledoc """
  Pure derivation of a `Feature` from a free-text description, for single-spec
  run mode (specs/001-single-spec-run). No breakdown backlog, no operator id or
  slug — the id is auto-assigned, the slug is derived, and prereqs are always
  `[]` (a wave of one).

  Carries no IO: callers gather `taken_ids` (existing breakdown ids + feature
  branch ids) and pass them in, so this module stays fully unit-testable and
  free of any CLI/harness/git dependency (constitution Principle I).
  """

  alias SpeckitOrchestrator.{Config, Feature}

  @doc """
  Build a `Feature` for `description`, given the ids already taken by other
  features. Rejects a `nil`, empty, or whitespace-only description loudly
  rather than building an unidentified feature (constitution Principle II).
  """
  @spec build(String.t() | nil, [String.t()], keyword()) ::
          {:ok, Feature.t()} | {:error, :empty_description}
  def build(description, taken_ids \\ [], opts \\ [])

  def build(nil, _taken_ids, _opts), do: {:error, :empty_description}

  def build(description, taken_ids, opts) when is_binary(description) do
    case String.trim(description) do
      "" ->
        {:error, :empty_description}

      trimmed ->
        id = next_id(taken_ids)
        slug = slug(trimmed)
        breakdown_dir = Keyword.get(opts, :breakdown_dir, Config.breakdown_dir())

        {:ok,
         %Feature{
           id: id,
           slug: slug,
           path: Path.join(breakdown_dir, "#{id}-#{slug}.md"),
           prereqs: [],
           status: :pending
         }}
    end
  end

  @doc """
  Next zero-padded id after the highest of `taken_ids` (each a `\d{3,}`-style
  string; non-numeric entries are ignored); `"001"` when `taken_ids` is empty.
  """
  @spec next_id([String.t()]) :: String.t()
  def next_id(taken_ids) do
    next =
      taken_ids
      |> Enum.map(&parse_id/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    next |> Integer.to_string() |> String.pad_leading(3, "0")
  end

  defp parse_id(id) do
    case Integer.parse(id) do
      {n, _rest} -> n
      :error -> 0
    end
  end

  @token_pattern ~r/[a-z0-9]+/
  @max_tokens 5
  @max_length 40

  @doc """
  Kebab-case slug derived from `description`: downcase, keep alphanumeric
  tokens, take the first #{@max_tokens}, join with `-`, cap at
  #{@max_length} chars. Falls back to `"feature"` when nothing alphanumeric
  survives.
  """
  @spec slug(String.t()) :: String.t()
  def slug(description) do
    tokens =
      description
      |> String.downcase()
      |> then(&Regex.scan(@token_pattern, &1))
      |> Enum.map(&hd/1)
      |> Enum.take(@max_tokens)

    case tokens do
      [] ->
        "feature"

      _ ->
        tokens
        |> Enum.join("-")
        |> String.slice(0, @max_length)
        |> String.trim_trailing("-")
    end
  end

  @doc """
  Breakdown-format seed body for `id`/`description` — parses under
  `SpeckitOrchestrator.Backlog` as a single feature with no prerequisites, and
  is what the `specify` phase reads via `PhaseRequest.breakdown_ref/1`.
  """
  @spec seed_body(String.t(), String.t()) :: String.t()
  def seed_body(id, description) do
    """
    # #{id} — #{title(description)}

    #{String.trim(description)}

    ## Prerequisites

    None
    """
  end

  # Reuses slug/1 (rather than a second parsing pass) so the seed's title and
  # the feature's branch/path slug always agree.
  defp title(description) do
    description
    |> slug()
    |> String.split("-")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
