defmodule SpeckitOrchestrator.ImageInfo do
  @moduledoc """
  The image's self-identification (FR-007), read from
  `/etc/autonomous/image.json` — written into the runtime stage at build time
  (`data-model.md` §1, `contracts/image-publishing.md` §4).

  A missing or unparseable manifest is **not** fatal on its own — the release
  may run outside a container during development — so `read/1` returns
  `{:error, :not_containerized}` rather than inventing values (Constitution
  II). `tools` MUST be non-empty in a containerized run; an empty map is
  treated the same as an unreadable file.
  """

  @enforce_keys [
    :source_revision,
    :orchestrator_version,
    :image_ref,
    :built_at,
    :tools,
    :elixir,
    :otp,
    :base_digests
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_revision: String.t(),
          orchestrator_version: String.t(),
          image_ref: String.t(),
          built_at: DateTime.t(),
          tools: %{String.t() => String.t()},
          elixir: String.t(),
          otp: String.t(),
          base_digests: %{String.t() => String.t()}
        }

  @default_path "/etc/autonomous/image.json"

  @doc """
  Read and parse the image manifest at `path` (default
  `/etc/autonomous/image.json`). `{:error, :not_containerized}` on a missing
  file, malformed JSON, a missing required field, or an empty `tools` map.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, :not_containerized}
  def read(path \\ @default_path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, info} <- build(decoded) do
      {:ok, info}
    else
      _ -> {:error, :not_containerized}
    end
  end

  defp build(%{
         "source_revision" => source_revision,
         "orchestrator_version" => orchestrator_version,
         "image_ref" => image_ref,
         "built_at" => built_at_raw,
         "tools" => tools,
         "elixir" => elixir,
         "otp" => otp,
         "base_digests" => base_digests
       })
       when is_binary(source_revision) and is_binary(orchestrator_version) and
              is_binary(image_ref) and is_map(tools) and map_size(tools) > 0 and
              is_binary(elixir) and is_binary(otp) and is_map(base_digests) do
    case DateTime.from_iso8601(built_at_raw) do
      {:ok, built_at, _offset} ->
        {:ok,
         %__MODULE__{
           source_revision: source_revision,
           orchestrator_version: orchestrator_version,
           image_ref: image_ref,
           built_at: built_at,
           tools: tools,
           elixir: elixir,
           otp: otp,
           base_digests: base_digests
         }}

      {:error, _} ->
        :error
    end
  end

  defp build(_), do: :error
end
