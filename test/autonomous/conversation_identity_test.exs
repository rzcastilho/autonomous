defmodule Autonomous.ConversationIdentityTest do
  use ExUnit.Case, async: true

  alias Autonomous.ConversationIdentity, as: I

  defp id(overrides) do
    struct!(
      I,
      [run_id: "r000001", feature_id: "001", phase: :clarify, ordinal: 1, transcript_root: "/t"] ++
        overrides
    )
  end

  test "valid identity" do
    assert {:ok, %I{}} = I.validate(id(kind: :phase))
  end

  for {field, value} <- [
        run_id: nil,
        feature_id: "",
        phase: nil,
        ordinal: 0,
        transcript_root: nil,
        kind: :bogus
      ] do
    test "rejects bad #{field}" do
      assert {:error, {:bad_identity, unquote(field)}} =
               I.validate(id([{unquote(field), unquote(value)}]))
    end
  end

  test "non-identity" do
    assert {:error, {:bad_identity, :identity}} = I.validate(%{})
  end

  test "to_map omits the root" do
    m = I.to_map(id(kind: :phase))
    refute Map.has_key?(m, "transcript_root")
    assert m["phase"] == "clarify"
  end
end
