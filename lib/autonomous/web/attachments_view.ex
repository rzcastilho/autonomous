defmodule Autonomous.Web.AttachmentsView do
  @moduledoc """
  Pure view rows for a feature's attachments on Run Detail (feature 047).

  Takes a store feature summary (`attachments`, `spec_number`, `feature_id`,
  `slug`) and returns display rows. `original_name` is shown here only and is
  escaped by HEEx at render time.
  """

  alias Autonomous.{Attachment, Feature}

  @type row :: %{
          original_name: String.t(),
          stored_name: String.t(),
          renamed?: boolean(),
          media_type: String.t(),
          size: String.t(),
          location: String.t(),
          sha_short: String.t(),
          sha: String.t()
        }

  @spec rows(map()) :: [row()]
  def rows(%{attachments: attachments} = f) when is_list(attachments) and attachments != [] do
    spec_id = spec_id(f)

    attachments
    |> Attachment.from_records()
    |> Enum.map(fn %Attachment{} = a ->
      %{
        original_name: a.original_name,
        stored_name: a.stored_name,
        renamed?: a.original_name != a.stored_name,
        media_type: a.media_type,
        size: Attachment.format_size(a.size),
        location: "specs/#{spec_id}-#{f.slug}/attachments/#{a.stored_name}",
        sha_short: String.slice(a.sha256, 0, 12),
        sha: a.sha256
      }
    end)
  end

  def rows(_), do: []

  defp spec_id(%{spec_number: n}) when is_integer(n),
    do: Feature.spec_id(%Feature{id: "", number: 0, slug: "", path: "", spec_number: n})

  defp spec_id(%{feature_id: id}), do: id
end
