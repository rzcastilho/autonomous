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

  describe "Conversation.file_path/1" do
    @describetag :tmp_dir

    test "resolves a live conversation's file from its registry identity", %{tmp_dir: root} do
      identity = %I{
        repo_id: "o:repo",
        run_id: "r000001",
        feature_id: "001",
        phase: :clarify,
        ordinal: 1,
        kind: :phase,
        transcript_root: root
      }

      request = Jido.Harness.RunRequest.new!(%{prompt: "p", model: "opus"})
      {:ok, handle, _} = Autonomous.Conversation.open(identity, request)

      on_exit(fn ->
        if Process.alive?(handle.pid), do: Autonomous.Conversation.close(handle, nil)
      end)

      assert {:ok, path} = Autonomous.Conversation.file_path(handle.conversation_id)
      assert File.exists?(path)
      assert String.starts_with?(path, root)
      assert Autonomous.Conversation.file_path("no-such") == :not_live
    end
  end
end
