defmodule SpeckitOrchestrator.ImageInfoTest do
  use ExUnit.Case, async: true

  alias SpeckitOrchestrator.ImageInfo

  @fixtures_dir Path.join([__DIR__, "..", "fixtures", "image_json"])

  defp fixture(name), do: Path.join(@fixtures_dir, name)

  test "a valid manifest is parsed" do
    assert {:ok, info} = ImageInfo.read(fixture("valid.json"))
    assert info.source_revision == "b17f0ea1234567890abcdef1234567890abcdef"
    assert info.orchestrator_version == "0.1.0"
    assert info.image_ref == "ghcr.io/rzcastilho/autonomous:v0.1.0"
    assert info.elixir == "1.20.2"
    assert info.otp == "28"
    assert %DateTime{} = info.built_at
    assert info.tools["git"] == "2.39.5"
    assert info.base_digests["builder"] =~ "sha256:"
  end

  test "a malformed (truncated) manifest yields :not_containerized" do
    assert {:error, :not_containerized} = ImageInfo.read(fixture("malformed.json"))
  end

  test "an absent file yields :not_containerized" do
    assert {:error, :not_containerized} = ImageInfo.read(fixture("does_not_exist.json"))
  end

  test "a present-but-empty tools map is invalid" do
    path = Path.join(System.tmp_dir!(), "image_info_empty_tools_test.json")

    File.write!(path, ~s({
      "source_revision": "abc",
      "orchestrator_version": "0.1.0",
      "image_ref": "ghcr.io/rzcastilho/autonomous:v0.1.0",
      "built_at": "2026-07-24T18:40:00Z",
      "elixir": "1.20.2",
      "otp": "28",
      "base_digests": {"builder": "sha256:x", "runtime": "sha256:y"},
      "tools": {}
    }))

    on_exit(fn -> File.rm(path) end)

    assert {:error, :not_containerized} = ImageInfo.read(path)
  end
end
