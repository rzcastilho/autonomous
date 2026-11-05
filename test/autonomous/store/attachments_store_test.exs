defmodule Autonomous.Store.AttachmentsStoreTest do
  use Autonomous.StoreCase, async: false

  alias Autonomous.{Attachment, Feature, Recovery}

  @repo "o:attachments-store"

  @att %Attachment{
    original_name: "My Mock.png",
    stored_name: "My-Mock.png",
    type: :png,
    media_type: "image/png",
    size: 67,
    sha256: String.duplicate("a", 64)
  }

  defp feature(id, attachments) do
    %{
      feature_id: id,
      slug: "f-#{id}",
      path: "specs/#{id}",
      number: String.to_integer(id),
      group: :ad_hoc,
      created_at: DateTime.utc_now(),
      attachments: attachments
    }
  end

  defp open(features) do
    {:ok, run_id} =
      Writer.open_run(@repo, %{
        features: features,
        settings: %{},
        scope: :ad_hoc,
        layout: %{}
      })

    {@repo, run_id}
  end

  test "open_run persists the manifest and Query exposes it" do
    run_key = open([feature("001", [@att]), feature("002", [])])
    {:ok, detail} = Query.run(run_key)

    [f1, f2] = Enum.sort_by(detail.features, & &1.feature_id)
    assert [%{stored_name: "My-Mock.png", type: :png, size: 67}] = f1.attachments
    assert f2.attachments == []

    # round-trips back to the struct a resume sees
    assert %Feature{attachments: [@att]} = Recovery.to_feature(f1)
  end

  test "a feature map without the key is written as [] (backlog features)" do
    run_key = open([Map.delete(feature("001", []), :attachments)])
    {:ok, detail} = Query.run(run_key)
    assert [%{attachments: []}] = detail.features
  end

  test "add_features persists the manifest too" do
    {repo, run_id} = open([feature("001", [])])
    :ok = Writer.add_features({repo, run_id}, [feature("002", [@att])])
    {:ok, detail} = Query.run({repo, run_id})
    f2 = Enum.find(detail.features, &(&1.feature_id == "002"))
    assert [%{stored_name: "My-Mock.png"}] = f2.attachments
  end

  test "a pre-047 row (attachments: nil) reads as []" do
    {repo, run_id} = open([feature("001", [])])
    key = Autonomous.Store.Ids.feature_key(repo, run_id, "001")
    {:ok, [tuple]} = Mnesia.transaction(fn -> Mnesia.read(:speckit_feature_run, key) end)

    {:ok, _} =
      Mnesia.transaction(fn -> Mnesia.write(put_elem(tuple, tuple_size(tuple) - 1, nil)) end)

    {:ok, detail} = Query.run({repo, run_id})
    assert [%{attachments: []}] = detail.features
    assert Recovery.to_feature(hd(detail.features)).attachments == []
  end
end
