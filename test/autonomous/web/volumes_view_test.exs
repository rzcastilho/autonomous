defmodule Autonomous.Web.VolumesViewTest do
  use ExUnit.Case, async: true

  alias Autonomous.AppliedVolumes.Volume
  alias Autonomous.Web.VolumesView

  defp vol(name),
    do: %Volume{name: name, path: "/v/#{name}", env: [{"A", "1"}], path_dirs: ["/v/b"]}

  test "hidden when nothing applied" do
    assert :hidden = VolumesView.state({:ok, [], nil}, %{})
  end

  test "refused carries the reason" do
    assert {:refused, "not valid JSON"} = VolumesView.state({:error, "not valid JSON"}, %{})
  end

  test "rows default to measuring and take usage by name" do
    assert {:rows, "d.toml", [a, b]} =
             VolumesView.state({:ok, [vol("a"), vol("b")], "d.toml"}, %{"b" => {:ok, 2048}})

    assert a.usage == :measuring
    assert b.usage == {:ok, 2048}
  end

  test "usage text and state" do
    assert VolumesView.usage_text(:measuring) == "measuring"
    assert VolumesView.usage_text({:ok, 2048}) == "2.0 KiB (2 KiB)"
    assert VolumesView.usage_text({:ok, 512}) == "512 B (0 KiB)"
    assert VolumesView.usage_text({:ok, 3 * 1024 * 1024}) == "3.0 MiB (3072 KiB)"
    assert VolumesView.usage_text({:unknown, "timed out"}) == "unknown (timed out)"
    assert VolumesView.usage_state(:measuring) == "measuring"
    assert VolumesView.usage_state({:ok, 1}) == "known"
    assert VolumesView.usage_state({:unknown, "x"}) == "unknown"
  end

  test "env labels keep order" do
    assert VolumesView.env_labels([{"A", "1"}, {"B", "2"}]) == ["A=1", "B=2"]
  end
end
