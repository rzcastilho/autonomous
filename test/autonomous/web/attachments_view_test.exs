defmodule Autonomous.Web.AttachmentsViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.Web.AttachmentsView

  defp att(overrides \\ %{}) do
    Map.merge(
      %{
        original_name: "My Mock.png",
        stored_name: "My-Mock.png",
        type: :png,
        media_type: "image/png",
        size: 1_200_000,
        sha256: String.duplicate("0123456789abcdef", 4)
      },
      overrides
    )
  end

  test "empty or absent list yields no rows" do
    assert AttachmentsView.rows(%{attachments: [], spec_number: 1, slug: "x", feature_id: "001"}) ==
             []

    assert AttachmentsView.rows(%{}) == []
  end

  test "row carries names, type, size, derived location and short hash" do
    [row] =
      AttachmentsView.rows(%{
        attachments: [att()],
        spec_number: 12,
        slug: "checkout",
        feature_id: "001"
      })

    assert row.original_name == "My Mock.png"
    assert row.stored_name == "My-Mock.png"
    assert row.renamed?
    assert row.media_type == "image/png"
    assert row.size == "1.2 MB"
    assert row.location == "specs/012-checkout/attachments/My-Mock.png"
    assert row.sha_short == "0123456789ab"
    assert String.length(row.sha) == 64
  end

  test "unallocated spec number falls back to the feature id; same names are not renamed" do
    [row] =
      AttachmentsView.rows(%{
        attachments: [att(%{original_name: "a.png", stored_name: "a.png"})],
        spec_number: nil,
        slug: "x",
        feature_id: "003"
      })

    refute row.renamed?
    assert row.location == "specs/003-x/attachments/a.png"
  end
end
