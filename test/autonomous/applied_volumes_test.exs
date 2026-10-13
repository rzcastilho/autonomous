defmodule Autonomous.AppliedVolumesTest do
  use ExUnit.Case, async: true

  alias Autonomous.AppliedVolumes
  alias Autonomous.AppliedVolumes.Volume

  test "nil and empty mean no declaration" do
    assert {:ok, [], nil} = AppliedVolumes.parse(nil)
    assert {:ok, [], nil} = AppliedVolumes.parse("")
  end

  test "valid v1 JSON yields ordered volumes with env pairs" do
    json =
      Jason.encode!(%{
        version: 1,
        declaration: "/home/u/.config/autonomous/targets/x/volumes.toml",
        volumes: [
          %{
            name: "cargo",
            path: "/var/lib/autonomous/volumes/cargo",
            env: [["CARGO_TARGET_DIR", "/var/lib/autonomous/volumes/cargo/t"]],
            path_dirs: ["/var/lib/autonomous/volumes/cargo/bin"]
          },
          %{name: "node", path: "/var/lib/autonomous/volumes/node", env: [], path_dirs: []}
        ]
      })

    assert {:ok, [first, second], decl} = AppliedVolumes.parse(json)
    assert decl == "/home/u/.config/autonomous/targets/x/volumes.toml"

    assert %Volume{
             name: "cargo",
             env: [{"CARGO_TARGET_DIR", "/var/lib/autonomous/volumes/cargo/t"}],
             path_dirs: ["/var/lib/autonomous/volumes/cargo/bin"]
           } = first

    assert %Volume{name: "node", env: [], path_dirs: []} = second
  end

  test "unknown version, bad JSON and bad shape are errors" do
    assert {:error, "unsupported version 2"} =
             AppliedVolumes.parse(~s({"version":2,"volumes":[]}))

    assert {:error, "not valid JSON"} = AppliedVolumes.parse("{nope")
    assert {:error, "unexpected shape"} = AppliedVolumes.parse(~s([1,2]))
    assert {:error, _} = AppliedVolumes.parse(~s({"version":1,"volumes":[{"name":1}]}))

    assert {:error, _} =
             AppliedVolumes.parse(
               ~s({"version":1,"volumes":[{"name":"a","path":"/p","env":[["K"]]}]})
             )
  end
end
